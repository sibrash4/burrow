import Foundation
import os

private let log = Logger(subsystem: "app.burrow.core", category: "ProcessRunner")

/// Runs Mole (or any executable, for tests) without a terminal. stdin is /dev/null.
public struct ProcessRunner: CommandRunning {
    private enum Source: Sendable {
        case fixed(URL)
        case locate(MoleLocator)
    }

    private let source: Source
    private let baseEnvironment: [String: String]
    private let eofGrace: TimeInterval

    /// `eofGrace` is how long a call keeps waiting for the output pipe to close after the child has exited. A
    /// descendant that outlives the child and keeps the pipe open (a daemon, an escapee) would otherwise hold the call
    /// open until it exits. When the grace passes, the call returns what it has read and logs it.
    public init(locator: MoleLocator = MoleLocator(), eofGrace: TimeInterval = 2) {
        source = .locate(locator)
        baseEnvironment = ProcessInfo.processInfo.environment
        self.eofGrace = eofGrace
    }

    /// Runs `executable` instead of `mo`. Intended for tests.
    public init(executable: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, eofGrace: TimeInterval = 2) {
        source = .fixed(executable)
        self.baseEnvironment = baseEnvironment
        self.eofGrace = eofGrace
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
        let job = RunningProcess(executable: executable, args: args, environment: env, eofGrace: eofGrace)

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
    private let eofGrace: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    /// The group id, which is also the child's pid. Zero until the child has been spawned.
    private var group: pid_t = 0

    init(executable: URL, args: [String], environment: [String: String], eofGrace: TimeInterval) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.eofGrace = eofGrace
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Blocks the calling thread until the process exits and its output is read. Output ends at end-of-file, or
    /// `eofGrace` seconds after the child exits if a descendant still holds the pipe open.
    func runToCompletion() throws -> (Int32, Data) {
        // Close-on-exec on both ends and on /dev/null: only the explicit dup2s in spawn() reach the child.
        let (readEnd, writeEnd) = try FileDescriptors.makeCloexecPipe()
        let input = FileDescriptors.open("/dev/null", O_RDONLY)
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

        // The parent keeps only the read end. Reading reaches EOF once every process holding the output has closed it.
        close(input)
        close(writeEnd)
        guard error == 0 else {
            close(readEnd)
            throw Self.failure(error)
        }

        let (data, exitCode) = drain(readEnd, child: pid)
        return (exitCode ?? reap(pid), data)
    }

    /// Reads until the pipe reaches EOF, which happens once every process holding the output has closed it. The child
    /// is reaped as soon as it exits; from then on EOF gets `eofGrace` seconds, so a descendant that kept the pipe
    /// (see `eofGrace` on ProcessRunner) cannot hold the call open.
    /// After cancellation it gives up waiting for EOF after a short grace period, so a helper that left the group
    /// (setsid, daemonised) cannot hold the cancelled call open. Closes `fd` in every case.
    /// Returns the exit code if the child was reaped here, nil if the caller still has to wait for it.
    private func drain(_ fd: Int32, child: pid_t) -> (Data, Int32?) {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var cancelledAt: Date?
        var exitCode: Int32?
        var exitedAt: Date?
        while true {
            // Checked on every pass, so a helper that keeps writing cannot hold a cancelled call open either.
            if wasCancelled {
                let start = cancelledAt ?? Date()
                cancelledAt = start
                if Date().timeIntervalSince(start) > 3 { break }
            }
            if exitCode == nil, let code = reapIfExited(child) {
                exitCode = code
                exitedAt = Date()
            }
            if let exitedAt, Date().timeIntervalSince(exitedAt) > eofGrace {
                log.warning("pid \(child) exited \(self.eofGrace, format: .fixed(precision: 1)) s ago but the output pipe is still open; a descendant holds it. Returning \(data.count) bytes without waiting for end-of-file.")
                break
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count); continue }
            if count == 0 || (errno != EINTR && errno != EAGAIN) { break }
        }
        return (data, exitCode)
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
        // The child must not inherit this thread's blocked signals or ignored dispositions. A blocked SIGTERM would
        // make cancel() wait for the 2 s SIGKILL instead of stopping the group at once.
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

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
        return Self.exitCode(fromStatus: status)
    }

    /// The exit code if the child has exited (and is now reaped), nil while it is still running.
    private func reapIfExited(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return Self.exitCode(fromStatus: status) }
        if result < 0 && errno != EINTR { return -1 } // already reaped elsewhere: stop polling
        return nil
    }

    private static func exitCode(fromStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }

    private static func failure(_ code: Int32) -> BurrowError {
        .processFailed(exitCode: -1, output: String(cString: strerror(code)))
    }
}
