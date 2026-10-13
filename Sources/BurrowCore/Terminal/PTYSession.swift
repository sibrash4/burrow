import Foundation

/// A process running on a pseudo-terminal that is also its controlling terminal,
/// so reads from /dev/tty work. Output feeds a virtual screen and a plain-text transcript.
public final class PTYSession: InteractiveSession, @unchecked Sendable {
    public let lines: AsyncStream<String>

    private let masterFD: Int32
    private let pid: pid_t
    private let lock = NSLock()
    private let lineSink: AsyncStream<String>.Continuation
    private var screen: TerminalScreen
    private var stripper = ANSIStripper()
    private var partialUTF8: [UInt8] = []
    private var exitCode: Int32?
    private var finished = false

    private init(masterFD: Int32, pid: pid_t, columns: Int, rows: Int) {
        self.masterFD = masterFD
        self.pid = pid
        screen = TerminalScreen(columns: columns, rows: rows)
        (lines, lineSink) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: - Start

    /// Starts `executable args` with the pty slave as stdin/stdout/stderr and controlling terminal.
    static func start(executable: URL, args: [String], environment: [String: String], columns: Int, rows: Int) throws -> PTYSession {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BurrowError.moleNotFound }
        let columns = max(1, columns), rows = max(1, rows)

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw failure("posix_openpt", errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            let code = errno
            close(master)
            throw failure("grantpt/unlockpt", code)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard ioctl(master, TIOCPTYGNAME, &nameBuffer) == 0 else {
            let code = errno
            close(master)
            throw failure("ptsname", code)
        }
        let slavePath = String(cString: nameBuffer)

        // Holding the slave open while spawning keeps the pty alive and makes the window size stick.
        let hold = open(slavePath, O_RDWR | O_NOCTTY)
        guard hold >= 0 else {
            let code = errno
            close(master)
            throw failure("open slave", code)
        }
        defer { close(hold) }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(hold, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened after setsid, so the slave becomes the controlling terminal.
        for fd in 0...2 { posix_spawn_file_actions_addopen(&actions, Int32(fd), slavePath, O_RDWR, 0) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let env = ProcessEnvironment.make(overrides: ["TERM": "xterm-256color"].merging(environment) { _, new in new })
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(master)
            if status == ENOENT || status == EACCES { throw BurrowError.moleNotFound }
            throw failure("posix_spawn", status)
        }

        let session = PTYSession(masterFD: master, pid: pid, columns: columns, rows: rows)
        let thread = Thread { session.readLoop() }
        thread.name = "burrow.pty.reader"
        thread.start()
        return session
    }

    private static func failure(_ what: String, _ code: Int32) -> BurrowError {
        .processFailed(exitCode: code, output: "\(what): \(String(cString: strerror(code)))")
    }

    // MARK: - InteractiveSession

    public func send(_ keys: String) throws {
        let bytes = Array(keys.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw BurrowError.processFailed(exitCode: exitCode ?? -1, output: "Mole is no longer running.")
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(masterFD, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Self.failure("write", errno)
            }
            offset += written
        }
    }

    public func currentFrame() -> String {
        lock.lock(); defer { lock.unlock() }
        return screen.frame()
    }

    public func transcript() -> String {
        lock.lock(); defer { lock.unlock() }
        return stripper.text
    }

    public func waitForFrame(timeout: TimeInterval, _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (frame, ended) = snapshot()
            if predicate(frame) { return frame }
            if ended { throw BurrowError.processFailed(exitCode: exitStatus() ?? -1, output: transcript()) }
            if Date() >= deadline { throw BurrowError.timeout("waiting for Mole's screen") }
            try await pause()
        }
    }

    public func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (_, ended) = snapshot()
            if ended, let code = exitStatus() { return code }
            if Date() >= deadline { throw BurrowError.timeout("waiting for Mole to exit") }
            try await pause()
        }
    }

    public func terminate() {
        lock.lock()
        let alive = exitCode == nil
        if alive { signalGroup(SIGTERM) }
        lock.unlock()
        guard alive else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            if exitCode == nil { signalGroup(SIGKILL) }
            lock.unlock()
        }
    }

    // MARK: - Internals

    private func snapshot() -> (frame: String, ended: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (screen.frame(), finished)
    }

    private func exitStatus() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return exitCode
    }

    private func pause() async throws {
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { throw BurrowError.cancelled }
    }

    /// Caller holds the lock. The child leads its own process group, so this reaches Mole's helpers too.
    private func signalGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0 { kill(pid, signal) }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var hungUp = false
        while true {
            var poller = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 100)
            if ready > 0 {
                let count = read(masterFD, &buffer, buffer.count)
                if count > 0 {
                    ingest(buffer[0..<count])
                    continue
                }
                if count == 0 || (errno != EINTR && errno != EAGAIN) { hungUp = true }
            }
            let reaped = reapIfExited()
            if reaped && (ready == 0 || hungUp) { break }
            if hungUp && !reaped { usleep(20_000) }
        }
        finish()
    }

    private func ingest(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        partialUTF8.append(contentsOf: bytes)
        let complete = Self.completeUTF8Length(partialUTF8)
        let text = String(decoding: partialUTF8[0..<complete], as: UTF8.self)
        partialUTF8.removeFirst(complete)
        screen.feed(text.unicodeScalars)
        let completed = stripper.feed(text.unicodeScalars)
        lock.unlock()
        for line in completed { lineSink.yield(line) }
    }

    /// Length of the prefix that doesn't end in the middle of a multi-byte character.
    static func completeUTF8Length(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        while index >= 0, bytes.count - index <= 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { index -= 1; continue }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return bytes.count - index < needed ? index : bytes.count
        }
        return bytes.count
    }

    private func reapIfExited() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if exitCode != nil { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return false }
        if result < 0 && errno == EINTR { return false }
        let signal = status & 0x7F
        exitCode = result < 0 ? -1 : (signal == 0 ? (status >> 8) & 0xFF : 128 + signal)
        return true
    }

    private func finish() {
        lock.lock()
        let tail = stripper.flush()
        finished = true
        lock.unlock()
        if let tail { lineSink.yield(tail) }
        lineSink.finish()
        close(masterFD)
    }
}
