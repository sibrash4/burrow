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

/// One child process, started as the leader of its own process group so that cancelling can reach
/// everything it starts. Uses posix_spawn because Foundation's `Process` cannot set the group.
private final class RunningProcess: @unchecked Sendable {
    private let executable: URL
    private let args: [String]
    private let environment: [String: String]
    private let lock = NSLock()
    private var cancelled = false
    /// The group id, which is also the child's pid. Zero until the child has been spawned.
    private var group: pid_t = 0

    init(executable: URL, args: [String], environment: [String: String]) {
        self.executable = executable
        self.args = args
        self.environment = environment
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Blocks the calling thread until the process exits and its output is fully read.
    func runToCompletion() throws -> (Int32, Data) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Self.failure(errno) }
        let readEnd = fds[0], writeEnd = fds[1]
        let input = open("/dev/null", O_RDONLY)
        guard input >= 0 else {
            let code = errno
            close(readEnd)
            close(writeEnd)
            throw Self.failure(code)
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            close(readEnd)
            close(writeEnd)
            close(input)
            throw BurrowError.cancelled
        }
        let (pid, error) = spawn(input: input, output: writeEnd)
        if error == 0 { group = pid }
        lock.unlock()

        // The parent keeps only the read end. Reading reaches EOF once every process in the group has closed its output.
        close(input)
        close(writeEnd)
        guard error == 0 else {
            close(readEnd)
            throw Self.failure(error)
        }

        let data = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true).readDataToEndOfFile()
        return (reap(pid), data)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pgid = group
        lock.unlock()
        // Not spawned yet. runToCompletion checks `cancelled` under the same lock and never starts the child.
        guard pgid > 0 else { return }
        // Signal the whole group: helpers Mole starts hold the output pipe too, and reading only ends when they exit.
        _ = killpg(pgid, SIGTERM)
        // Anything in the group that ignores SIGTERM is killed after 2 s. The group is signalled even if the leader
        // has already exited, because a helper may still hold the pipe open.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = killpg(pgid, SIGKILL) }
    }

    /// Called with the lock held, so `cancel()` sees the group as soon as it exists. Stdin is /dev/null and stdout
    /// and stderr go to `output`. The group is set before exec, so the child is never outside it.
    private func spawn(input: Int32, output: Int32) -> (pid: pid_t, error: Int32) {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        return status == 0 ? (pid, 0) : (-1, status)
    }

    /// Waits for the child and returns its exit code, or the signal it died from (what `Process` reported).
    private func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }

    private static func failure(_ code: Int32) -> BurrowError {
        .processFailed(exitCode: -1, output: String(cString: strerror(code)))
    }
}
