import Foundation
import XCTest
@testable import BurrowCore

/// A stand-in for `mo clean --dry-run`. It replays the scrubbed fixtures and, like Mole,
/// leaves out every path the whitelist file protects (an exact line, or a folder line for its children).
final class FakeMole: CommandRunning, @unchecked Sendable {
    let whitelistURL: URL
    let listURL: URL
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _environments: [[String: String]] = []
    private var _whitelistSeen: [Data?] = []

    var honorsWhitelist = true
    var writesList = true
    var exitCode: Int32 = 0

    init(whitelistURL: URL, listURL: URL) {
        self.whitelistURL = whitelistURL
        self.listURL = listURL
    }

    var calls: [[String]] { lock.withLock { _calls } }
    var environments: [[String: String]] { lock.withLock { _environments } }
    /// The whitelist file as it was when each dry run started.
    var whitelistSeen: [Data?] { lock.withLock { _whitelistSeen } }

    func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String) {
        let whitelistData = try? Data(contentsOf: whitelistURL)
        lock.withLock {
            _calls.append(args)
            _environments.append(environment)
            _whitelistSeen.append(whitelistData)
        }
        guard exitCode == 0 else { return (exitCode, "Mole failed") }

        let protected = honorsWhitelist ? Self.patterns(in: whitelistData) : []
        if writesList {
            let source = try CleanFixtures.text("clean_list")
            let kept = source.components(separatedBy: "\n").filter { line in
                guard line.hasPrefix("/"), let range = line.range(of: "  # ", options: .backwards) else { return true }
                return !Self.isProtected(String(line[..<range.lowerBound]), by: protected)
            }
            try kept.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
        }

        var output = try CleanFixtures.text("clean_dryrun")
        if protected.contains("/Users/test/.npm/_cacache/*") {
            output = output.replacingOccurrences(of: "→ npm cache · would clean", with: "→ npm cache · would skip (whitelist)")
        }
        return (0, output)
    }

    static func patterns(in data: Data?) -> Set<String> {
        guard let data else { return [] }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return Set(lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    static func isProtected(_ path: String, by patterns: Set<String>) -> Bool {
        patterns.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// A scripted terminal. Each `waitForExit` poll reveals the next chunk of output, then the process exits.
final class FakeSession: InteractiveSession, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [String]
    private let exitCode: Int32
    private let neverExits: Bool
    private var revealed = 0
    private var _sent: [String] = []
    private var _terminated = false
    private var exited = false

    init(chunks: [String], exitCode: Int32 = 0, neverExits: Bool = false) {
        self.chunks = chunks
        self.exitCode = exitCode
        self.neverExits = neverExits
    }

    var sent: [String] { lock.withLock { _sent } }
    var terminated: Bool { lock.withLock { _terminated } }

    /// Like PTYSession: writing to a process that has already exited throws `processFailed`.
    /// `exitsBeforeSend` makes the fake behave as if Mole exited just before the key was written.
    var exitsBeforeSend = false

    func send(_ keys: String) throws {
        try lock.withLock {
            if exitsBeforeSend || exited { exited = true; throw BurrowError.processFailed(exitCode: exitCode, output: "Mole is no longer running.") }
            _sent.append(keys)
        }
    }
    func currentFrame() -> String { transcript() }
    func transcript() -> String { lock.withLock { chunks.prefix(revealed).joined() } }
    func waitForFrame(timeout: TimeInterval, _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
        throw BurrowError.timeout("frame")
    }

    var lines: AsyncStream<String> {
        let all = chunks.joined().components(separatedBy: "\n")
        return AsyncStream { continuation in
            for line in all where !line.isEmpty { continuation.yield(line) }
            continuation.finish()
        }
    }

    func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        let done: Bool = lock.withLock {
            if exitsBeforeSend && revealed >= chunks.count { exited = true; return true }
            if revealed < chunks.count { revealed += 1; return false }
            if !neverExits { exited = true }
            return !neverExits
        }
        if done { return exitCode }
        try await Task.sleep(nanoseconds: 5_000_000)
        throw BurrowError.timeout("still running")
    }

    func terminate() { lock.withLock { _terminated = true } }
}

final class CleanFakeLauncher: InteractiveLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _launches: [[String]] = []
    private var _environments: [[String: String]] = []
    private let session: FakeSession?
    var onLaunch: (@Sendable () -> Void)?

    /// `session == nil` makes `launch` throw.
    init(session: FakeSession?) { self.session = session }

    var launches: [[String]] { lock.withLock { _launches } }
    var environments: [[String: String]] { lock.withLock { _environments } }

    func launch(_ args: [String], environment: [String: String], columns: Int, rows: Int) throws -> InteractiveSession {
        lock.withLock {
            _launches.append(args)
            _environments.append(environment)
        }
        onLaunch?()
        guard let session else { throw BurrowError.moleNotFound }
        return session
    }
}

enum CleanTranscripts {
    static let skipSudoThenFinish = [
        "\nClean Your Mac\n\n➤ System caches need sudo. Enter continue, Space skip: ",
        " Skipped\n\n⚙ Apple Silicon | Free space: 780.28GB\n",
        "\n➤ Browsers\n  ✓ Chrome cache · 642.2MB\n",
        "\n======================================================================\nCleanup complete\nTracked cleanup: 1.20GB | Items cleaned: 17\nFree space: 781.48GB (+1.20GB)\n======================================================================\n",
    ]
}

func collectEvents(_ stream: AsyncThrowingStream<JobEvent, Error>) async throws -> [JobEvent] {
    var events: [JobEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

extension Array where Element == JobEvent {
    var statuses: [String] { compactMap { if case .status(let s) = $0 { s } else { nil } } }
    var lines: [String] { compactMap { if case .line(let s) = $0 { s } else { nil } } }
    var result: RunResult? { compactMap { if case .finished(let r) = $0 { r } else { nil } }.first }
}
