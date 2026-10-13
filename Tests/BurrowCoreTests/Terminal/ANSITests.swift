import XCTest
@testable import BurrowCore

final class ANSITests: XCTestCase {
    func testStripsColorAndPrivateModes() {
        XCTAssertEqual(ANSI.strip("\u{1B}[?25lhello \u{1B}[1;32mgreen\u{1B}[0m\u{1B}[?25h"), "hello green")
    }

    func testStripsOSCCharsetAndLoneEscapes() {
        XCTAssertEqual(ANSI.strip("\u{1B}]0;title\u{07}a\u{1B}]8;;http://x\u{1B}\\b\u{1B}(Bc\u{1B}7d\u{1B}8e\u{1B}"), "abcde")
    }

    func testNormalisesCRLF() {
        XCTAssertEqual(ANSI.strip("one\r\ntwo\r\n"), "one\ntwo\n")
    }

    func testBareCarriageReturnOverwrites() {
        XCTAssertEqual(ANSI.strip("progress 10%\rprogress 99%\n"), "progress 99%\n")
        XCTAssertEqual(ANSI.strip("abcdef\rxy\n"), "xycdef\n")
    }

    func testEraseLineSequences() {
        XCTAssertEqual(ANSI.strip("old text\r\u{1B}[2Knew\n"), "new\n")
        XCTAssertEqual(ANSI.strip("keep\u{1B}[3D\u{1B}[Kgone\n"), "keepgone\n")
        XCTAssertEqual(ANSI.strip("abc\u{1B}[2D\u{1B}[K\n"), "abc\n")
        XCTAssertEqual(ANSI.strip("abcdef\r\u{1B}[3Kxy\n"), "xy\n")
    }

    func testBackspace() {
        XCTAssertEqual(ANSI.strip("ab\u{08}c\n"), "ac\n")
    }

    func testDropsBellAndOtherControls() {
        XCTAssertEqual(ANSI.strip("a\u{07}b\u{0F}c"), "abc")
    }

    func testIncompleteSequenceAtEndIsDropped() {
        XCTAssertEqual(ANSI.strip("done\u{1B}[3"), "done")
    }

    func testHomeStartsNewLineWhenOneIsInProgress() {
        XCTAssertEqual(ANSI.strip("prompt? \u{1B}[Hnext\n"), "prompt? \nnext\n")
    }

    func testInstallerFixture() throws {
        let raw = try fixture("installer_dryrun")
        XCTAssertTrue(raw.contains("\u{1B}"), "fixture should contain real escapes")
        let text = ANSI.strip(raw)
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertFalse(text.contains("\r"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines.contains("Select Installers to Remove [1/23] , 0B, 0 selected"))
        let first = try XCTUnwrap(lines.first { $0.contains("1Password.zip") })
        XCTAssertTrue(first.hasSuffix("21.8MB | Downloads "), first)
        XCTAssertFalse(first.contains("\u{1B}"))
        let item = try XCTUnwrap(lines.first { $0.contains("Bartender 6.dmg") })
        XCTAssertTrue(item.hasPrefix("  "), "\\r\\e[2K must not leave stale text: \(item)")
        XCTAssertTrue(item.contains("54.7MB | Downloads"))
        XCTAssertTrue(text.contains("Space Select  |  Enter Confirm"))
    }

    func testUninstallFixture() throws {
        let text = ANSI.strip(try fixture("uninstall_dryrun"))
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertTrue(text.contains("Matched 1 app(s):"))
        XCTAssertTrue(text.contains("1. Flux  5.8MB  |  Last: Today"))
        XCTAssertTrue(text.contains("Proceed with uninstallation? [y/N]"))
    }

    func testStripperReportsCompletedLines() {
        var stripper = ANSIStripper()
        XCTAssertEqual(stripper.feed("par".unicodeScalars), [])
        XCTAssertEqual(stripper.feed("tial\r\nnext\nrest".unicodeScalars), ["partial", "next"])
        XCTAssertEqual(stripper.currentLine, "rest")
        XCTAssertEqual(stripper.flush(), "rest")
    }
}
