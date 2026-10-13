import XCTest
@testable import BurrowCore

final class RunTeardownTests: XCTestCase {
    func testKindIsActiveUntilEveryBeginHasEnded() {
        let tracker = RunTeardown()
        tracker.begin(.purge)
        tracker.begin(.purge)
        tracker.end(.purge)
        XCTAssertTrue(tracker.isActive(.purge))
        tracker.end(.purge)
        XCTAssertFalse(tracker.isActive(.purge))
        XCTAssertFalse(tracker.isActive(.clean))
    }

    func testWaitUntilIdleReturnsWhenTheRunEnds() async {
        let tracker = RunTeardown()
        tracker.begin(.clean)
        let ending = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracker.end(.clean)
        }
        let started = Date()
        await tracker.waitUntilIdle(.clean, timeout: 5)
        XCTAssertFalse(tracker.isActive(.clean))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        await ending.value
    }

    func testWaitUntilIdleGivesUpAtTheTimeout() async {
        let tracker = RunTeardown()
        tracker.begin(.uninstall)
        await tracker.waitUntilIdle(.uninstall, timeout: 0.1)
        XCTAssertTrue(tracker.isActive(.uninstall))
        tracker.end(.uninstall)
    }

    func testTakeResultReturnsWhatTheRunSettledOnce() {
        let tracker = RunTeardown()
        tracker.begin(.clean)
        tracker.end(.clean, result: RunResult(freedBytes: 42, exitCode: -1, log: ""))
        XCTAssertEqual(tracker.takeResult(.clean)?.freedBytes, 42)
        XCTAssertNil(tracker.takeResult(.clean))
    }

    func testBeginForgetsTheResultOfTheLastRun() {
        let tracker = RunTeardown()
        tracker.begin(.clean)
        tracker.end(.clean, result: RunResult(freedBytes: 1, exitCode: 0, log: ""))
        tracker.begin(.clean)
        XCTAssertNil(tracker.takeResult(.clean))
        tracker.end(.clean)
    }
}
