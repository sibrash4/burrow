import XCTest
@testable import BurrowCore

/// Runs the real `mo installer --dry-run` in a pty, moves the cursor once and quits.
/// Skipped unless BURROW_LIVE_MO=1. Dry run only; nothing is selected or confirmed.
private func cursorRow(_ frame: String) -> Int? {
    frame.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.hasPrefix("➤") }
}

final class LiveMoleTests: XCTestCase {
    func testInstallerMenuShowsInFrame() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BURROW_LIVE_MO"] == "1", "set BURROW_LIVE_MO=1 to run")
        let session = try PTYLauncher().launch(["installer", "--dry-run"], environment: [:], columns: 100, rows: 30)
        defer { session.terminate() }
        let frame = try await session.waitForFrame(timeout: 60) { $0.contains("Enter Confirm") || $0.contains("No installer") }
        guard frame.contains("Select Installers") else { return }

        let before = try XCTUnwrap(cursorRow(frame), frame)
        try session.send(TerminalKey.down)
        let after = try await session.waitForFrame(timeout: 5) { cursorRow($0).map { $0 != before } ?? false }
        XCTAssertEqual(cursorRow(after), before + 1)
        XCTAssertTrue(after.contains("0 selected"))

        try session.send(TerminalKey.quit)
        let code = try await session.waitForExit(timeout: 20)
        XCTAssertEqual(code, 0)
    }
}
