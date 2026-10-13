import Foundation
@testable import BurrowCore

struct UninstallFakeRunner: CommandRunning {
    var code: Int32 = 0
    var output: String
    var seen = UninstallCallLog()

    func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String) {
        seen.add(args)
        return (code, output)
    }
}

final class UninstallCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    func add(_ args: [String]) { lock.lock(); items.append(args); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A scripted terminal. `react` runs on every send and may change the screen or end the process.
final class UninstallFakeSession: InteractiveSession, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: String
    private var text: String
    private var exitCode: Int32?
    private var sentKeys: [String] = []
    private var wasTerminated = false
    private var react: (UninstallFakeSession, String) -> Void = { _, _ in }
    private let lineContinuation: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>

    init(frame: String) {
        self.frame = frame
        self.text = frame
        (lines, lineContinuation) = AsyncStream<String>.makeStream()
    }

    func onSend(_ react: @escaping (UninstallFakeSession, String) -> Void) { self.react = react }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return sentKeys }
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return wasTerminated }

    func show(_ newFrame: String, replace: Bool = true) {
        lock.lock()
        if replace { frame = newFrame } else { frame += newFrame }
        // A real terminal moves to a new line when the answer is entered, so new output starts on a fresh line.
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += newFrame
        lock.unlock()
        for line in newFrame.components(separatedBy: "\n") { lineContinuation.yield(line) }
    }

    func exit(_ code: Int32) {
        lock.lock(); exitCode = code; lock.unlock()
        lineContinuation.finish()
    }

    func send(_ keys: String) throws {
        lock.lock()
        // Same as PTYSession: writing to a finished process throws.
        if let code = exitCode { lock.unlock(); throw BurrowError.processFailed(exitCode: code, output: "Mole is no longer running.") }
        sentKeys.append(keys); lock.unlock()
        react(self, keys)
    }

    func currentFrame() -> String { lock.lock(); defer { lock.unlock() }; return frame }
    func transcript() -> String { lock.lock(); defer { lock.unlock() }; return text }

    func waitForFrame(timeout: TimeInterval, _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = currentFrame()
            if predicate(now) { return now }
            // Same as PTYSession: if Mole is gone and the screen never matched, fail now instead of waiting.
            lock.lock(); let code = exitCode; lock.unlock()
            if let code { throw BurrowError.processFailed(exitCode: code, output: transcript()) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw BurrowError.timeout("frame")
    }

    func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let code = exitCode; lock.unlock()
            if let code { return code }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw BurrowError.timeout("exit")
    }

    func terminate() {
        lock.lock(); wasTerminated = true; if exitCode == nil { exitCode = 143 }; lock.unlock()
        lineContinuation.finish()
    }
}

final class UninstallFakeLauncher: InteractiveLaunching, @unchecked Sendable {
    let session: UninstallFakeSession
    private let log = UninstallCallLog()
    init(session: UninstallFakeSession) { self.session = session }

    var launches: [[String]] { log.all }

    func launch(_ args: [String], environment: [String: String], columns: Int, rows: Int) throws -> InteractiveSession {
        log.add(args)
        return session
    }
}

enum UninstallScreens {
    static func matched(_ rows: [(String, String)]) -> String {
        var out = "◎ Matched \(rows.count) app(s):\n"
        for (index, row) in rows.enumerated() { out += "\(index + 1). \(row.0)  \(row.1)  |  Last: Today\n" }
        return out + "\nProceed with uninstallation? [y/N] "
    }

    static func plan(_ names: [String], brew: Bool = false) -> String {
        var out = "Files to be removed:\n\n"
        for name in names {
            out += "◎ \(name)\(brew ? " [Brew]" : "") , 5.9MB\n"
            out += "  ✓ /Applications/\(name).app , 5.8MB\n"
            out += "  ✓ ~/Library/Preferences/com.example.\(name.lowercased()).plist , 4KB\n"
            out += "  ✓ ~/Library/Caches/com.example.\(name.lowercased()) , 61KB\n"
        }
        let apps = names.count == 1 ? "app" : "apps"
        return out + "\n➤ Remove \(names.count) \(apps), 5.9MB  Enter confirm, ESC cancel: "
    }

    static func summary(_ count: Int, freed: String, names: String) -> String {
        """

        ======================================================================
        Uninstall complete
        Removed \(count) app\(count == 1 ? "" : "s"), freed \(freed): \(names)
        ======================================================================

        """
    }
}
