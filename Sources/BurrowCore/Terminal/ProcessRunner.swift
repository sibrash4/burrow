import Foundation

/// Runs Mole (or any executable, for tests) without a terminal. stdin is /dev/null.
public struct ProcessRunner: CommandRunning {
    private enum Source: Sendable {
        case fixed(URL)
        case locate(MoleLocator)
    }

    private let source: Source
    private let baseEnvironment: [String: String]

    public init(locator: MoleLocator = MoleLocator()) {
        source = .locate(locator)
        baseEnvironment = ProcessInfo.processInfo.environment
    }

    /// Runs `executable` instead of `mo`. Intended for tests.
    public init(executable: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        source = .fixed(executable)
        self.baseEnvironment = baseEnvironment
    }

    public func run(_ args: [String], environment: [String: String] = [:]) async throws -> (exitCode: Int32, output: String) {
        let executable: URL
        switch source {
        case .fixed(let url): executable = url
        case .locate(let locator): executable = try locator.locate()
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BurrowError.moleNotFound }

        var overrides = environment
        if overrides["NO_COLOR"] == nil { overrides["NO_COLOR"] = "1" }
        let env = ProcessEnvironment.make(base: baseEnvironment, overrides: overrides)
        let job = RunningProcess(executable: executable, args: args, environment: env)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let (code, data) = try job.runToCompletion()
                        if job.wasCancelled {
                            continuation.resume(throwing: BurrowError.cancelled)
                        } else {
                            continuation.resume(returning: (code, ANSI.strip(String(decoding: data, as: UTF8.self))))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, args: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Blocks the calling thread until the process exits and its output is fully read.
    func runToCompletion() throws -> (Int32, Data) {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        lock.lock()
        if cancelled { lock.unlock(); throw BurrowError.cancelled }
        do { try process.run() } catch {
            lock.unlock()
            throw BurrowError.processFailed(exitCode: -1, output: error.localizedDescription)
        }
        lock.unlock()

        // The write end must be closed in this process or reading never reaches EOF.
        try? output.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (process.terminationStatus, data)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        lock.unlock()
        guard running else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
