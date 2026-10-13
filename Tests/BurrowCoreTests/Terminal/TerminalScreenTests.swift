import XCTest
@testable import BurrowCore

final class TerminalScreenTests: XCTestCase {
    private func screen(_ text: String, columns: Int = 40, rows: Int = 10) -> TerminalScreen {
        var screen = TerminalScreen(columns: columns, rows: rows)
        screen.feed(text.unicodeScalars)
        return screen
    }

    func testPlainTextAndNewlines() {
        XCTAssertEqual(screen("one\r\ntwo\r\n").frame(), "one\ntwo")
    }

    func testClearAndHomeDropEarlierText() {
        XCTAssertEqual(screen("old\r\nolder\r\n\u{1B}[2J\u{1B}[HQ? ").frame(), "Q?")
    }

    func testHomeWithoutClearOverwritesInPlace() {
        XCTAssertEqual(screen("hello\r\nworld\u{1B}[Hj").frame(), "jello\nworld")
        XCTAssertEqual(screen("hello\r\nworld\u{1B}[1;1Hj").frame(), "jello\nworld")
    }

    func testCursorAddressedPartialRedraw() {
        let frame = screen("\u{1B}[2Jrow1\r\nrow2\r\nrow3\u{1B}[2;1H\u{1B}[2KROW2").frame()
        XCTAssertEqual(frame, "row1\nROW2\nrow3")
    }

    func testEraseToEndOfLineAndDisplay() {
        XCTAssertEqual(screen("abcdef\u{1B}[3D\u{1B}[K").frame(), "abc")
        XCTAssertEqual(screen("a\r\nb\r\nc\u{1B}[2;1H\u{1B}[J").frame(), "a")
    }

    func testCursorMovesUpAndColumns() {
        XCTAssertEqual(screen("one\r\ntwo\u{1B}[1A\u{1B}[2GX").frame(), "oXe\ntwo")
    }

    func testColorsAndPrivateModesAreIgnored() {
        XCTAssertEqual(screen("\u{1B}[?25l\u{1B}[1;36mhi\u{1B}[0m\u{1B}[?25h").frame(), "hi")
    }

    func testTrailingWhitespaceTrimmedPerLine() {
        XCTAssertEqual(screen("a   \r\n  b  \r\n\r\n").frame(), "a\n  b")
    }

    func testScrollsAtBottom() {
        XCTAssertEqual(screen("1\r\n2\r\n3\r\n4", columns: 10, rows: 3).frame(), "2\n3\n4")
    }

    func testWrapsAtRightEdge() {
        XCTAssertEqual(screen("abcdefg", columns: 5, rows: 3).frame(), "abcde\nfg")
    }

    func testAlternateScreenRestoresMainOnLeave() {
        let alt = screen("main\r\n\u{1B}[?1049hmenu\u{1B}[?1049l")
        XCTAssertEqual(alt.frame(), "main")
        XCTAssertEqual(screen("main\r\n\u{1B}[?1049hmenu").frame(), "menu")
    }

    func testSequencesSplitAcrossFeeds() {
        var s = TerminalScreen(columns: 20, rows: 5)
        s.feed("abc\u{1B}[".unicodeScalars)
        s.feed("2D\u{1B}[K".unicodeScalars)
        XCTAssertEqual(s.frame(), "a")
    }

    /// F22: a full line leaves the cursor at column == columns; ESC[1K and ESC[1J used column + 1 as an end
    /// index and trapped on it.
    func testEraseToStartWithCursorAtRightEdgeDoesNotTrap() {
        var line = TerminalScreen(columns: 5, rows: 3)
        line.feed("12345\u{1B}[1K".unicodeScalars)
        XCTAssertEqual(line.frame(), "")

        var display = TerminalScreen(columns: 5, rows: 3)
        display.feed("abcde\r\nfghij\u{1B}[1J".unicodeScalars)
        XCTAssertEqual(display.frame(), "")
    }

    func testInstallerFixtureFrame() throws {
        let raw = try fixture("installer_dryrun").replacingOccurrences(of: "\n", with: "\r\n")
        let frame = screen(raw, columns: 100, rows: 30).frame()
        let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "Select Installers to Remove [1/23] , 0B, 0 selected")
        XCTAssertTrue(lines.contains { $0.contains("Bartender 7.dmg") && $0.hasSuffix("60.8MB | Downloads") })
        XCTAssertTrue(lines.last?.contains("Q Quit") == true)
        XCTAssertFalse(frame.contains("DRY RUN"), "text above the home position is overwritten only where redrawn")
    }

    func testUninstallFixtureFrame() throws {
        // The fixture was captured from a pipe; a pty's line discipline would turn each \n into \r\n.
        let raw = try fixture("uninstall_dryrun").replacingOccurrences(of: "\n", with: "\r\n")
        let frame = screen(raw, columns: 100, rows: 30).frame()
        XCTAssertTrue(frame.hasPrefix("◎ Matched 1 app(s):\n1. Flux  5.8MB  |  Last: Today\n\nProceed with uninstallation? [y/N]"), frame)
        XCTAssertFalse(frame.contains("DRY RUN"))
    }
}
