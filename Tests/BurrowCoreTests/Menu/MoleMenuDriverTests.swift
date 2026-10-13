import XCTest
@testable import BurrowCore

final class MoleMenuDriverTests: XCTestCase {
    private let driver = MoleMenuDriver(firstFrameTimeout: 2, frameTimeout: 0.3, settleTime: 0, promptGrace: 0)

    private func installers(_ count: Int = 12, selected: Set<Int> = []) -> [FakeMenuItem] {
        (0..<count).map { FakeMenuItem(name: "app\($0).dmg", location: "Downloads", selected: selected.contains($0)) }
    }

    private func key(_ i: Int) -> String { "app\(i).dmg | Downloads" }

    func testSelectsAcrossPages() async throws {
        let session = FakeMenuSession(kind: .installer, items: installers(12), perPage: 5)
        let report = try await driver.select(exactly: [key(1), key(6), key(11)], in: session)
        XCTAssertEqual(session.selectedNames, ["app1.dmg", "app6.dmg", "app11.dmg"])
        XCTAssertEqual(Set(report.selectedKeys), [key(1), key(6), key(11)])
        XCTAssertEqual(report.totalRows, 12)
        XCTAssertEqual(session.enterPresses, 1)
        XCTAssertEqual(session.sent.last, TerminalKey.enter)
        XCTAssertFalse(session.quitSent)
    }

    func testFitsOnOnePageWithoutScrollIndicator() async throws {
        let session = FakeMenuSession(kind: .installer, items: installers(4), perPage: 10)
        try await driver.select(exactly: [key(0), key(3)], in: session)
        XCTAssertEqual(session.selectedNames, ["app0.dmg", "app3.dmg"])
    }

    func testPreselectedRowsAreClearedOrKept() async throws {
        let session = FakeMenuSession(kind: .purge, items: purgeItems(9, selected: [0, 1, 2, 3, 4, 5, 6, 7, 8]), perPage: 4)
        try await driver.select(exactly: ["~/p2/node_modules", "~/p7/node_modules"], in: session)
        XCTAssertEqual(session.selectedNames.count, 2)
        XCTAssertEqual(session.enterPresses, 1)
    }

    func testStartsFromWhereverTheCursorIs() async throws {
        let session = FakeMenuSession(kind: .installer, items: installers(12), perPage: 5, cursor: 8)
        try await driver.select(exactly: [key(0), key(9)], in: session)
        XCTAssertEqual(session.selectedNames, ["app0.dmg", "app9.dmg"])
    }

    func testMissingRowQuitsAndThrows() async {
        let session = FakeMenuSession(kind: .installer, items: installers(8), perPage: 5)
        await assertMismatch(session) { try await self.driver.select(exactly: [self.key(1), "gone.dmg | Downloads"], in: session) }
        XCTAssertTrue(session.quitSent)
        XCTAssertEqual(session.enterPresses, 0)
    }

    func testDuplicateRowNamesThrow() async {
        var items = installers(6)
        items[4].name = items[1].name
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 3)
        await assertMismatch(session) { try await self.driver.select(exactly: [self.key(1)], in: session) }
        XCTAssertTrue(session.quitSent)
        XCTAssertEqual(session.enterPresses, 0)
    }

    func testDuplicateNamesThatAreNotWantedAreFine() async throws {
        var items = installers(6)
        items[4].name = items[1].name
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 3)
        try await driver.select(exactly: [key(2)], in: session)
        XCTAssertEqual(session.selectedNames, ["app2.dmg"])
    }

    func testSameNameInDifferentFoldersIsDistinct() async throws {
        var items = installers(4)
        items[3] = FakeMenuItem(name: "app0.dmg", location: "Desktop")
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 3)
        try await driver.select(exactly: ["app0.dmg | Desktop"], in: session)
        XCTAssertEqual(session.selectedNames, ["app0.dmg"])
        XCTAssertEqual(session.enterPresses, 1)
    }

    func testRequestingTheSameRowTwiceThrowsBeforeAnyKey() async {
        let session = FakeMenuSession(kind: .installer, items: installers(3))
        await assertMismatch(session) { try await self.driver.select(exactly: [self.key(1), self.key(1)], in: session) }
        XCTAssertEqual(session.sent, [TerminalKey.quit])
    }

    func testHeaderCountDisagreementQuits() async {
        let session = FakeMenuSession(kind: .installer, items: installers(8), perPage: 5)
        session.headerCountOffset = 1
        await assertMismatch(session) { try await self.driver.select(exactly: [self.key(2)], in: session) }
        XCTAssertTrue(session.quitSent)
        XCTAssertEqual(session.enterPresses, 0)
    }

    func testRowThatWillNotToggleQuits() async {
        let session = FakeMenuSession(kind: .installer, items: installers(8), perPage: 5)
        session.stuckRows = [3]
        await assertMismatch(session) { try await self.driver.select(exactly: [self.key(3)], in: session) }
        XCTAssertTrue(session.quitSent)
        XCTAssertEqual(session.enterPresses, 0)
    }

    func testEmptySelectionQuitsAndCancels() async {
        let session = FakeMenuSession(kind: .installer, items: installers(3))
        do {
            try await driver.select(exactly: [], in: session)
            XCTFail("expected throw")
        } catch BurrowError.cancelled {
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(session.quitSent)
    }

    func testPurgeUsesFullPathSoSameProjectRowsStayDistinct() async throws {
        var items = purgeItems(6)
        items[1] = FakeMenuItem(name: "node_modules", location: "~/mono", size: "2.0MB", path: "~/mono/web/node_modules")
        items[2] = FakeMenuItem(name: "node_modules", location: "~/mono", size: "2.0MB", path: "~/mono/api/node_modules")
        let session = FakeMenuSession(kind: .purge, items: items, perPage: 4)
        try await driver.select(exactly: ["~/mono/api/node_modules"], in: session)
        XCTAssertEqual(session.selectedNames.count, 1)
        XCTAssertEqual(session.enterPresses, 1)
        let report = try await driver.readAllRows(in: session)
        XCTAssertEqual(report.filter(\.row.isSelected).map(\.key), ["~/mono/api/node_modules"])
    }

    func testReadAllRowsTouchesNothing() async throws {
        let session = FakeMenuSession(kind: .installer, items: installers(12, selected: [2]), perPage: 5)
        let entries = try await driver.readAllRows(in: session)
        XCTAssertEqual(entries.map(\.key), (0..<12).map(key))
        XCTAssertEqual(entries.filter(\.row.isSelected).count, 1)
        XCTAssertFalse(session.sent.contains(TerminalKey.space))
        XCTAssertFalse(session.sent.contains(TerminalKey.enter))
        XCTAssertFalse(session.sent.contains(TerminalKey.quit))
    }

    // MARK: -

    // MARK: Path line lags the cursor (seen live with the real purge menu)

    func testPurgeIdentifiesRowsCorrectlyWhenMolesPathLineLagsTheCursor() async throws {
        // Mole draws the rows first and the Path line a few milliseconds later.
        let patient = MoleMenuDriver(firstFrameTimeout: 2, frameTimeout: 1, settleTime: 0.12)
        let session = FakeMenuSession(kind: .purge, items: purgeItems(6), perPage: 4)
        session.pathLag = 0.06
        let report = try await patient.select(exactly: ["~/p2/node_modules", "~/p4/node_modules"], in: session)
        XCTAssertEqual(Set(report.selectedKeys), ["~/p2/node_modules", "~/p4/node_modules"])
        XCTAssertEqual(session.selectedNames.count, 2)
        XCTAssertEqual(report.selectedSize, "2MB", "the driver reports Mole's own header total")
    }

    func testWithoutSettlingALaggingPathLineIsCaughtByTheVerificationPass() async {
        // Settling off: the stale Path makes rows look like their neighbours. Nothing wrong may be confirmed.
        let impatient = MoleMenuDriver(firstFrameTimeout: 2, frameTimeout: 1, settleTime: 0)
        let session = FakeMenuSession(kind: .purge, items: purgeItems(6), perPage: 4)
        session.pathLag = 0.06
        await assertMismatch(session) { try await impatient.select(exactly: ["~/p2/node_modules"], in: session) }
        XCTAssertEqual(session.enterPresses, 0, "a stale identity must never reach Enter")
    }

    // MARK: Mole exits instead of showing a menu

    func testMoleExitingBeforeTheMenuFailsFastWithItsExitCode() async {
        let session = FakeMenuSession(kind: .installer, items: installers(3), perPage: 5)
        session.exitCodeAfterExit = 3
        session.terminate()
        do {
            _ = try await driver.select(exactly: [key(0)], in: session)
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 3)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(session.enterPresses, 0)
    }

    private func purgeItems(_ count: Int, selected: Set<Int> = []) -> [FakeMenuItem] {
        (0..<count).map {
            FakeMenuItem(name: "node_modules", location: "~/p\($0)", size: "3.0MB", path: "~/p\($0)/node_modules", selected: selected.contains($0))
        }
    }

    private func assertMismatch(_ session: FakeMenuSession, _ body: () async throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected selectionMismatch", file: file, line: line)
        } catch BurrowError.selectionMismatch {
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
