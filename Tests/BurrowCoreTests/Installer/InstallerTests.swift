import XCTest
@testable import BurrowCore

final class InstallerTests: XCTestCase {
    private let fast = MoleMenuDriver(firstFrameTimeout: 2, frameTimeout: 0.3, settleTime: 0, promptGrace: 0)

    private func fixtureEntries() throws -> [MenuEntry] {
        InstallerParser.entries(fromFrame: MenuFixtures.stripped(try MenuFixtures.text("installer_dryrun")))
    }

    func testScanResultFromFixture() throws {
        let result = InstallerParser.scanResult(entries: try fixtureEntries())
        XCTAssertEqual(result.kind, .installers)
        XCTAssertEqual(result.groups.map(\.title), ["Downloads"])
        XCTAssertEqual(result.allItems.count, 18)
        let first = try XCTUnwrap(result.allItems.first)
        XCTAssertEqual(first.id, "1Password.zip | Downloads")
        XCTAssertEqual(first.title, "1Password.zip")
        XCTAssertEqual(first.detail, "Downloads")
        XCTAssertEqual(first.bytes, 21_800_000)
        XCTAssertTrue(first.selectedByDefault && first.selectable)
        XCTAssertEqual(result.defaultSelection.count, 18)
    }

    func testGroupsByLocationInMenuOrderAndFlagsDuplicates() {
        func entry(_ name: String, _ location: String) -> MenuEntry {
            MenuEntry(key: "\(name) | \(location)", row: MenuRow(isCursor: false, isSelected: false, name: name, size: "1.0MB", location: location))
        }
        let result = InstallerParser.scanResult(entries: [
            entry("a.dmg", "Downloads"), entry("b.pkg", "Desktop"), entry("a.dmg", "Downloads"), entry("c.zip", "Downloads"),
        ])
        XCTAssertEqual(result.groups.map(\.title), ["Downloads", "Desktop"])
        XCTAssertEqual(result.groups[0].items.map(\.selectable), [false, false, true])
        XCTAssertNotNil(result.groups[0].items[0].note)
        XCTAssertEqual(result.defaultSelection, ["b.pkg | Desktop", "c.zip | Downloads"])
    }

    func testScanReadsEveryPageThenQuits() async throws {
        let items = (0..<9).map { FakeMenuItem(name: "app\($0).dmg", location: $0 < 6 ? "Downloads" : "Desktop", size: "2.0MB") }
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 4, transcript: "Select Installers to Remove [1/9] , 0B, 0 selected")
        let launcher = FakeLauncher(session: session)
        let result = try await InstallerJob(launcher: launcher, driver: fast).scan()
        XCTAssertEqual(launcher.launched, [["installer", "--dry-run"]])
        XCTAssertEqual(result.allItems.count, 9)
        XCTAssertEqual(result.groups.map(\.title), ["Downloads", "Desktop"])
        XCTAssertEqual(session.sent.last, TerminalKey.quit)
        XCTAssertFalse(session.sent.contains(TerminalKey.enter))
        XCTAssertFalse(session.sent.contains(TerminalKey.space))
    }

    func testScanWhenNothingToClean() async throws {
        let session = FakeMenuSession(kind: .installer, items: [], transcript: "Great! No installer files to clean")
        let result = try await InstallerJob(launcher: FakeLauncher(session: session), driver: fast).scan()
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testRunSelectsConfirmsAndSummarizes() async throws {
        let scan = InstallerParser.scanResult(entries: try fixtureEntries())
        let wanted = ["Flux.zip | Downloads", "Ice.zip | Downloads"]
        let items = scan.allItems.map { FakeMenuItem(name: $0.title, location: "Downloads", size: ByteSize.format($0.bytes ?? 0).replacingOccurrences(of: " MB", with: "MB")) }
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 6)
        session.confirmScreen = """

        Files to be removed:
          ✓ Flux.zip , 2.1MB
          ✓ Ice.zip , 3.5MB

        ➤ Delete 2 installers, 5.6MB  Enter confirm, ESC cancel:
        """
        session.runOutput = "\r\nRemoving...\r\n======\r\nInstallers cleaned\r\nRemoved 2 installers, freed 5.34MB\r\nYour Mac is cleaner now!\r\n======\r\n"
        let job = InstallerJob(launcher: FakeLauncher(session: session), driver: fast)

        let (lines, result) = try await collect(job.run(selection: Set(wanted), from: scan))
        XCTAssertEqual(Set(session.selectedNames), ["Flux.zip", "Ice.zip"])
        XCTAssertEqual(session.enterPresses, 2)
        XCTAssertTrue(lines.contains("Removed 2 installers, freed 5.34MB"))
        XCTAssertEqual(result?.itemCount, 2)
        XCTAssertEqual(result?.freedBytes, Int64(5.34 * 1_048_576))
        XCTAssertEqual(result?.exitCode, 0)
    }

    func testRunStopsWhenConfirmScreenDisagrees() async throws {
        let scan = InstallerParser.scanResult(entries: try fixtureEntries())
        let items = scan.allItems.map { FakeMenuItem(name: $0.title, location: "Downloads", size: "2.1MB") }
        let session = FakeMenuSession(kind: .installer, items: items, perPage: 6)
        session.confirmScreen = "Files to be removed:\n  ✓ Flux.zip , 2.1MB\n  ✓ Ice.zip , 2.1MB\n  ✓ Mole.dmg , 2.1MB\n➤ Delete 3 installers, 6.3MB  Enter confirm, ESC cancel: "
        session.runOutput = "Removed 3 installers"
        let job = InstallerJob(launcher: FakeLauncher(session: session), driver: fast)
        do {
            _ = try await collect(job.run(selection: ["Flux.zip | Downloads", "Ice.zip | Downloads"], from: scan))
            XCTFail("expected throw")
        } catch BurrowError.selectionMismatch {
        }
        XCTAssertEqual(session.enterPresses, 1)
        XCTAssertEqual(session.sent.last, "\u{1B}")
    }

    func testRunWithNothingSelectedNeverLaunches() async throws {
        let session = FakeMenuSession(kind: .installer, items: [])
        let launcher = FakeLauncher(session: session)
        let scan = InstallerParser.scanResult(entries: try fixtureEntries())
        let (_, result) = try await collect(InstallerJob(launcher: launcher, driver: fast).run(selection: [], from: scan))
        XCTAssertTrue(launcher.launched.isEmpty)
        XCTAssertEqual(result?.itemCount, 0)
    }

    func testSummaryWithFailures() {
        let log = """
        ======
        Installer cleanup incomplete
        Removed 1 installers, freed 4.10MB
        Failed to remove 2 installers
        ◎ /Users/test/Downloads/a.dmg (changed since scan)
        ======
        """
        let result = InstallerParser.summarize(log: log, exitCode: 1)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.problems, ["Failed to remove 2 installers", "/Users/test/Downloads/a.dmg (changed since scan)"])
        XCTAssertEqual(result.exitCode, 1)
    }

    func testSummaryWhenNothingRemoved() {
        let result = InstallerParser.summarize(log: "No installers were removed", exitCode: 0)
        XCTAssertNil(result.freedBytes)
        XCTAssertTrue(result.problems.isEmpty)
    }
}
