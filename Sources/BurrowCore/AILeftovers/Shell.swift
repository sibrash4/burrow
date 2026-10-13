// External commands used by the AI leftovers job (git, lsof).
// Everything goes through `ShellRunning` so tests can substitute fakes.

import Foundation

public struct ShellResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ShellRunning: Sendable {
    /// Runs an executable with arguments. stdin is /dev/null. The process is terminated after `timeout`
    /// seconds and its partial output is returned with a non-zero exit code. Throws `ShellError.hung` if the
    /// process survives SIGKILL or never closes its output, so a caller can never wait forever.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult
}

public enum ShellError: Error, Equatable {
    /// No result came back: the process outlived SIGKILL, or a child kept its output open.
    case hung(String)
}

/// Holds pipe output written on a background queue and read after the group completes.
final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Lets whichever completion path comes first resume a continuation, and only that one.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Real implementation backed by Foundation.Process.
public struct ProcessShell: ShellRunning {
    /// After the timeout: SIGTERM, then SIGKILL `killDelay` seconds later, then give up `giveUpDelay` seconds later.
    static let killDelay: TimeInterval = 2
    static let giveUpDelay: TimeInterval = 4

    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
                let once = ResumeOnce()

                // Read both pipes fully before waiting, so a chatty process cannot block on a full pipe.
                let group = DispatchGroup()
                let outBox = DataBox()
                let errBox = DataBox()
                group.enter()
                DispatchQueue.global().async {
                    outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        guard once.claim() else { return }
                        let result = ShellResult(
                            exitCode: proc.terminationStatus,
                            stdout: String(decoding: outBox.data, as: UTF8.self),
                            stderr: String(decoding: errBox.data, as: UTF8.self)
                        )
                        continuation.resume(returning: result)
                    }
                }

                do {
                    try process.run()
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                    return
                }
                if Task.isCancelled, process.isRunning { process.terminate() }

                // Escalate: a process that ignores SIGTERM, or a child that holds the pipes open, must not hang the caller.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Self.killDelay) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Self.giveUpDelay) {
                    if once.claim() { continuation.resume(throwing: ShellError.hung(executable)) }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Convenience wrappers so callers read as intent, not argv.
public enum ExternalTools {
    public static let git = "/usr/bin/git"
    public static let lsof = "/usr/sbin/lsof"
}
