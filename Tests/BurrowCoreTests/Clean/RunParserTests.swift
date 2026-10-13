import XCTest
@testable import BurrowCore

final class CleanRunParserTests: XCTestCase {
    func testCompleteSummary() {
        let summary = CleanRunParser.parse("""
        ➤ Browsers
          ✓ Chrome cache · 642.2MB

        ======================================================================
        Cleanup complete
        Tracked cleanup: 1.20GB | Items cleaned: 17
        Free space: 781.48GB (+1.20GB)
        ======================================================================
        """)
        XCTAssertEqual(summary.heading, "Cleanup complete")
        XCTAssertEqual(summary.freedBytes, 1_200_000_000)
        XCTAssertEqual(summary.itemCount, 17)
        XCTAssertFalse(summary.isPartial)
        XCTAssertTrue(summary.problems.isEmpty)
    }

    func testPartialAndCancelled() {
        let summary = CleanRunParser.parse("""
        Cleanup interrupted
        ◎ Cancelled: Chrome cache was interrupted (exit 130). Remaining cleanup was skipped.
        Tracked cleanup: At least 300.0MB | Items cleaned: 4
        """)
        XCTAssertTrue(summary.isPartial)
        XCTAssertEqual(summary.freedBytes, 300_000_000)
        XCTAssertEqual(summary.problems.first, "Cleanup interrupted")
        XCTAssertEqual(summary.problems.count, 2)
    }

    func testNothingToClean() {
        let summary = CleanRunParser.parse("""
        Cleanup complete
        System was already clean; no additional space freed.
        Free space: 780.28GB
        """)
        XCTAssertEqual(summary.freedBytes, 0)
        XCTAssertNil(summary.itemCount)
    }

    func testWarningsBecomeProblemsButChatterDoesNot() {
        let summary = CleanRunParser.parse("""
        ◎ Use --dry-run to preview, --whitelist to manage protected paths
        ◎ Whitelist: Path traversal not allowed: /Users/test/../x
        ◎ Trash · skipped, grant Full Disk Access
        Cleanup complete
        """)
        XCTAssertEqual(summary.problems, [
            "Whitelist: Path traversal not allowed: /Users/test/../x",
            "Trash · skipped, grant Full Disk Access",
        ])
    }

    func testSpinnerRedrawsKeepOnlyTheLastFrame() {
        let summary = CleanRunParser.parse("Cleaning...\rCleaning done\nTracked cleanup: 5KB | Items cleaned: 2\r\n")
        XCTAssertEqual(summary.freedBytes, 5_000)
        XCTAssertEqual(summary.itemCount, 2)
    }
}

final class CleanPromptTests: XCTestCase {
    func testDetectsTheSudoChoice() {
        XCTAssertEqual(CleanPrompt.detect(inTail: "Clean Your Mac\n\n➤ System caches need sudo. Enter continue, Space skip: "), .systemCaches)
    }

    func testDetectsFirstTimeSetup() {
        XCTAssertEqual(CleanPrompt.detect(inTail: "First-time setup\n➤ Press Enter to continue: "), .firstTimeSetup)
    }

    func testDetectsPasswordRequests() {
        XCTAssertEqual(CleanPrompt.detect(inTail: "➤ Enter your credentials:"), .password)
        XCTAssertEqual(CleanPrompt.detect(inTail: "Password:"), .password)
    }

    func testAnsweredPromptIsNoLongerLastLine() {
        XCTAssertNil(CleanPrompt.detect(inTail: "➤ System caches need sudo. Enter continue, Space skip:  Skipped\n\n⚙ Apple Silicon | Free space: 1GB"))
    }

    func testIgnoresOrdinaryOutputAndRetryWarning() {
        XCTAssertNil(CleanPrompt.detect(inTail: "  ✓ 1Password cache · 24KB"))
        XCTAssertNil(CleanPrompt.detect(inTail: "◎ Press Enter to continue, or Space to skip"))
        XCTAssertNil(CleanPrompt.detect(inTail: ""))
    }
}
