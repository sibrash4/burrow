import Foundation

/// What differs between `mo purge` and `mo installer` when running a real selection.
struct MenuRunSpec: Sendable {
    var args: [String]
    var label: String
    /// Reads Mole's final "Enter confirm, ESC cancel" screen. Returns nil when it matches the
    /// request, otherwise a short description of what it showed instead.
    var checkConfirm: @Sendable (_ screen: String) -> String?
    var summarize: @Sendable (_ log: String, _ exitCode: Int32) -> RunResult
}

enum MenuSession {
    static let columns = 240
    static let rows = 60
    static let environment = ["TERM": "xterm-256color"]
    static let escape = "\u{1B}"
    static let confirmMarker = "Enter confirm, ESC cancel"

    static func transcriptWait(_ session: InteractiveSession, timeout: TimeInterval,
                               _ predicate: (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let text = session.transcript()
            if predicate(text) { return text }
            guard Date() < deadline else { throw BurrowError.timeout("waiting for Mole") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func text(of transcript: String, after offset: Int) -> String {
        String(decoding: Array(transcript.utf8).dropFirst(offset), as: UTF8.self)
    }

    /// Cleans raw terminal text into log lines: last carriage-return segment wins, blanks dropped.
    static func logLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = (raw.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }
}

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: InteractiveSession?
    func set(_ s: InteractiveSession) { lock.lock(); session = s; lock.unlock() }
    func terminate() { lock.lock(); let s = session; lock.unlock(); s?.terminate() }
}

enum MenuJobRun {
    static func stream(spec: MenuRunSpec, wanted: [String], launcher: InteractiveLaunching, driver: MoleMenuDriver,
                       idleResult: RunResult) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = SessionBox()
            let task = Task {
                do {
                    guard !wanted.isEmpty else {
                        continuation.yield(.finished(idleResult))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.status("Opening Mole"))
                    let session = try launcher.launch(spec.args, environment: MenuSession.environment,
                                                      columns: MenuSession.columns, rows: MenuSession.rows)
                    box.set(session)

                    continuation.yield(.status("Selecting \(wanted.count) \(wanted.count == 1 ? "item" : "items")"))
                    let mark = session.transcript().utf8.count
                    try await driver.select(exactly: wanted, in: session)

                    let afterMenu = try await MenuSession.transcriptWait(session, timeout: 60) {
                        MenuSession.text(of: $0, after: mark).contains(MenuSession.confirmMarker)
                    }
                    if let actual = spec.checkConfirm(MenuSession.text(of: afterMenu, after: mark)) {
                        try? session.send(MenuSession.escape)
                        throw BurrowError.selectionMismatch(expected: "\(wanted.count) items as selected", actual: actual)
                    }

                    continuation.yield(.status(spec.label))
                    let runMark = session.transcript().utf8.count
                    try session.send(TerminalKey.enter)

                    var emitted = runMark
                    var exitCode: Int32?
                    let deadline = Date().addingTimeInterval(60 * 60)
                    while exitCode == nil {
                        do {
                            exitCode = try await session.waitForExit(timeout: 0.25)
                        } catch BurrowError.timeout {
                            if Date() > deadline { session.terminate(); throw BurrowError.timeout("waiting for Mole to finish") }
                        }
                        emitted = emit(from: session.transcript(), after: emitted, final: exitCode != nil, to: continuation)
                    }
                    let log = MenuSession.text(of: session.transcript(), after: runMark)
                    continuation.yield(.finished(spec.summarize(log, exitCode ?? -1)))
                    continuation.finish()
                } catch {
                    box.terminate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.terminate()
            }
        }
    }

    /// Emits the complete lines after `offset` bytes (everything when `final`) and returns the new offset.
    private static func emit(from transcript: String, after offset: Int, final: Bool,
                             to continuation: AsyncThrowingStream<JobEvent, Error>.Continuation) -> Int {
        let bytes = Array(transcript.utf8)
        guard bytes.count > offset else { return offset }
        var end = bytes.count
        if !final {
            guard let newline = bytes[offset...].lastIndex(of: 10) else { return offset }
            end = newline + 1
        }
        for line in MenuSession.logLines(String(decoding: bytes[offset..<end], as: UTF8.self)) {
            continuation.yield(.line(line))
            if line.hasPrefix("✓") { continuation.yield(.status(line)) }
        }
        return end
    }
}
