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
    /// seconds and its partial output is returned with a non-zero exit code.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult
}

/// Holds pipe output written on a background queue and read after the group completes.
final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Real implementation backed by Foundation.Process.
public struct ProcessShell: ShellRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

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

            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }

            process.terminationHandler = { proc in
                timer.cancel()
                group.notify(queue: .global()) {
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
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        }
    }
}

/// Convenience wrappers so callers read as intent, not argv.
public enum ExternalTools {
    public static let git = "/usr/bin/git"
    public static let lsof = "/usr/sbin/lsof"
}
