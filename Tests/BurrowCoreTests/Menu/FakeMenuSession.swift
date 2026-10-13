import Foundation
@testable import BurrowCore

enum MenuFixtures {
    static func text(_ name: String) throws -> String {
        let url = try unwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func unwrap(_ url: URL?) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    /// Terminal bytes to screen text: drop escape sequences, split on carriage returns, trim lines.
    static func stripped(_ raw: String) -> String {
        let noEscapes = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return noEscapes.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
}

struct FakeMenuItem {
    var name: String
    var location: String
    var size: String = "1.0MB"
    var path: String = ""
    var selected = false
}

/// Simulates Mole's checklist: cursor, paging, Space, Enter, q, and the header counters.
final class FakeMenuSession: InteractiveSession, @unchecked Sendable {
    let kind: MenuKind
    let perPage: Int
    private let lock = NSLock()
    private var items: [FakeMenuItem]
    private var cursor = 0
    private var top = 0
    private var transcriptText = ""
    private var exited = false
    private var enterCount = 0
    /// Exit code reported once the fake has exited.
    var exitCodeAfterExit: Int32 = 0

    /// Rows whose Space press does nothing (a row Mole refuses to toggle).
    var stuckRows: Set<Int> = []
    /// Mole draws the rows first and the "Path:" line a moment later. While this is positive, the fake shows the
    /// previous cursor row's path for that long after every key, like the real purge menu does.
    var pathLag: TimeInterval = 0
    private var previousCursor = 0
    private var lastMove = Date.distantPast
    /// Added to the "N selected" counter to simulate a header that disagrees with the rows.
    var headerCountOffset = 0
    /// Text Mole prints after the first Enter (the confirm screen).
    var confirmScreen = ""
    /// Text Mole prints once the run starts, after the confirm prompt is erased (see `runPromptLinger`).
    var runOutput = ""
    /// Mole redraws its confirm line as it starts. This is printed right at the second Enter, before the erase.
    var runPromptEcho = ""
    /// How long the confirm prompt stays on screen after the second Enter before Mole erases it.
    var runPromptLinger: TimeInterval = 0
    private var runStartedAt: Date?
    private var runOutputPrinted = false
    /// Gap between the erase and the run output, so a reader can take its mark in between.
    private static let eraseGap: TimeInterval = 0.3
    private(set) var sent: [String] = []

    init(kind: MenuKind, items: [FakeMenuItem], perPage: Int = 5, cursor: Int = 0, transcript: String = "") {
        self.transcriptText = transcript
        self.kind = kind; self.items = items; self.perPage = perPage; self.cursor = cursor
        self.top = max(0, min(cursor, items.count - perPage))
    }

    var selectedNames: [String] { lock.withLock { items.filter(\.selected).map(\.name) } }
    var quitSent: Bool { lock.withLock { sent.contains("q") } }
    var enterPresses: Int { lock.withLock { enterCount } }

    func send(_ keys: String) throws {
        lock.lock(); defer { lock.unlock() }
        advance()
        // Same as PTYSession: writing to a finished process throws.
        if exited { throw BurrowError.processFailed(exitCode: exitCodeAfterExit, output: "Mole is no longer running.") }
        sent.append(keys)
        switch keys {
        case TerminalKey.down:
            previousCursor = cursor; lastMove = Date()
            if cursor < items.count - 1 { cursor += 1 }
            if cursor >= top + perPage { top = cursor - perPage + 1 }
        case TerminalKey.up:
            previousCursor = cursor; lastMove = Date()
            if cursor > 0 { cursor -= 1 }
            if cursor < top { top = cursor }
        case TerminalKey.space:
            if !stuckRows.contains(cursor) { items[cursor].selected.toggle() }
        case TerminalKey.enter:
            enterCount += 1
            if enterCount == 1 {
                transcriptText += confirmScreen
            } else {
                runStartedAt = Date()
                transcriptText += runPromptEcho
            }
        case TerminalKey.quit:
            exited = true
        default:
            break
        }
    }

    func currentFrame() -> String { lock.withLock { () -> String in advance(); return render() } }
    func transcript() -> String { lock.withLock { () -> String in advance(); return transcriptText } }
    var lines: AsyncStream<String> { AsyncStream { $0.finish() } }
    func terminate() { lock.withLock { exited = true } }

    /// Caller holds the lock. Once the confirm prompt has been erased, prints the run output and exits.
    private func advance() {
        guard let started = runStartedAt, !runOutputPrinted else { return }
        guard Date() >= started.addingTimeInterval(runPromptLinger + Self.eraseGap) else { return }
        runOutputPrinted = true
        transcriptText += runOutput
        exited = true
    }

    func waitForFrame(timeout: TimeInterval, _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (frame, ended) = lock.withLock { () -> (String, Bool) in advance(); return (render(), exited) }
            if predicate(frame) { return frame }
            // Same as PTYSession: if Mole is gone and the screen never matched, fail now instead of waiting.
            if ended { throw BurrowError.processFailed(exitCode: exitCodeAfterExit, output: lock.withLock { transcriptText }) }
            guard Date() < deadline else { throw BurrowError.timeout("frame") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ () -> Bool in advance(); return exited }) { return exitCodeAfterExit }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw BurrowError.timeout("exit")
    }

    private func render() -> String {
        let selected = items.filter(\.selected)
        let count = selected.count + headerCountOffset
        let scroll = items.count > perPage ? " [\(cursor + 1)/\(items.count)]" : ""
        var out: [String]
        switch kind {
        case .installer:
            out = ["Select Installers to Remove\(scroll) , \(selected.count * 1)MB, \(count) selected", ""]
        case .purge:
            out = ["Select Artifacts to Purge\(scroll)", "\(selected.count)MB, \(count) selected"]
        }
        for index in top..<min(top + perPage, items.count) {
            let item = items[index]
            let prefix = (index == cursor ? "➤ " : "") + (item.selected ? "●" : "○")
            switch kind {
            case .installer: out.append("\(prefix) \(item.name)      \(item.size) | \(item.location)")
            case .purge: out.append("\(prefix) ─ \(item.location)      \(item.size) | \(item.name)")
            }
        }
        out.append("")
        if kind == .purge {
            let lagging = pathLag > 0 && Date().timeIntervalSince(lastMove) < pathLag
            out.append("Path: \(items[lagging ? previousCursor : cursor].path)")
        }
        // The confirm prompt is on screen until Mole erases it.
        if let started = runStartedAt, Date() < started.addingTimeInterval(runPromptLinger) {
            out.append(MenuSession.confirmMarker)
        }
        out.append(kind == .installer ? "↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit"
                                      : "↑↓ [] Projects / Find | Space Select | Enter Confirm | A All | I Invert | X Skip Project | Q Quit")
        return out.joined(separator: "\n")
    }
}

final class FakeLauncher: InteractiveLaunching, @unchecked Sendable {
    let session: FakeMenuSession
    private let lock = NSLock()
    private(set) var launched: [[String]] = []
    init(session: FakeMenuSession) { self.session = session }

    func launch(_ args: [String], environment: [String: String], columns: Int, rows: Int) throws -> InteractiveSession {
        lock.withLock { launched.append(args) }
        return session
    }
}
