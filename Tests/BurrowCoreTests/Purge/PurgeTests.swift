import XCTest
@testable import BurrowCore

final class PurgeTests: XCTestCase {
    private let fast = MoleMenuDriver(firstFrameTimeout: 2, frameTimeout: 0.3, settleTime: 0, promptGrace: 0)

    private func listing() throws -> PurgeListing { PurgeParser.parseListing(try MenuFixtures.text("purge_dryrun")) }

    func testParseListingFromFixture() throws {
        let l = try listing()
        XCTAssertEqual(l.found.count, 4)
        XCTAssertEqual(l.found[0], .init(path: "~/dev/tracker-app/hc-dashboard/client/node_modules", bytes: 54_300_000))
        XCTAssertEqual(l.found[2], .init(path: "~/dev/tracker-app/client/dist", bytes: 250_000))
        XCTAssertEqual(l.skipped.count, 10)
        XCTAssertTrue(l.skipped.allSatisfy(\.isCloud))
        XCTAssertEqual(l.skipped[0].path, "~/Library/CloudStorage/OneDrive-Personal/Archive/newsletter-site/.next")
        XCTAssertEqual(l.skipped[0].reason, "final removal check failed; re-run mo purge to review it again")
        XCTAssertEqual(l.reportedTotalBytes, 116_100_000)
    }

    func testScanResultGroupsByArtifactType() throws {
        let result = PurgeParser.scanResult(listing: try listing(), home: "/Users/test")
        XCTAssertEqual(result.kind, .purge)
        XCTAssertEqual(result.reportedTotalBytes, 116_100_000)
        XCTAssertEqual(result.groups.first?.title, "node_modules")
        let nodeModules = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(nodeModules.items.filter(\.selectable).count, 2)
        XCTAssertEqual(nodeModules.items.first?.bytes, 54_300_000)

        let next = try XCTUnwrap(result.groups.first { $0.title == ".next" })
        let good = try XCTUnwrap(next.items.first { $0.selectable })
        XCTAssertEqual(good.id, "~/dev/newsletter-site/.next")
        XCTAssertEqual(good.title, "dev/newsletter-site")
        XCTAssertEqual(good.paths, ["/Users/test/dev/newsletter-site/.next"])
        XCTAssertTrue(good.selectedByDefault)

        let cloud = try XCTUnwrap(next.items.first { !$0.selectable })
        XCTAssertTrue(cloud.id.hasPrefix("[cloud] ~/Library/CloudStorage"))
        XCTAssertFalse(cloud.selectedByDefault)
        XCTAssertNotNil(cloud.note)

        XCTAssertEqual(Set(result.groups.map(\.title)), ["node_modules", "dist", ".next", ".venv", "__pycache__"])
        XCTAssertEqual(result.defaultSelection.count, 4)
        XCTAssertTrue(result.notes.contains("10 in cloud storage were skipped."))
    }

    func testScanRunsOnlyDryRunAndToleratesExitOne() async throws {
        let runner = RecordingRunner(exitCode: 1, output: try MenuFixtures.text("purge_dryrun"))
        let job = PurgeJob(runner: runner, launcher: FakeLauncher(session: FakeMenuSession(kind: .purge, items: [])), home: "/Users/test")
        let result = try await job.scan()
        XCTAssertEqual(runner.calls, [["purge", "--dry-run"]])
        XCTAssertEqual(result.allItems.count, 14)
    }

    func testScanEmptyAndFailure() async throws {
        let launcher = FakeLauncher(session: FakeMenuSession(kind: .purge, items: []))
        let empty = try await PurgeJob(runner: RecordingRunner(exitCode: 0, output: "No artifacts found to purge\n"), launcher: launcher).scan()
        XCTAssertTrue(empty.groups.isEmpty)
        do {
            _ = try await PurgeJob(runner: RecordingRunner(exitCode: 2, output: "boom"), launcher: launcher).scan()
            XCTFail("expected throw")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 2)
        }
    }

    func testRunSelectsByFullPathConfirmsAndSummarizes() async throws {
        let scan = PurgeParser.scanResult(listing: try listing(), home: "/Users/test")
        let wanted = ["~/dev/tracker-app/client/dist", "~/dev/newsletter-site/.next"]
        let items = ["~/dev/tracker-app/hc-dashboard/client/node_modules", "~/dev/tracker-app/hc-dashboard/server/node_modules",
                     "~/dev/tracker-app/client/dist", "~/dev/newsletter-site/.next", "~/dev/other/target", "~/dev/recent/dist"]
            .map { FakeMenuItem(name: String($0.split(separator: "/").last!), location: String($0.split(separator: "/").dropLast().joined(separator: "/")),
                                path: $0, selected: $0 != "~/dev/recent/dist") }
        let session = FakeMenuSession(kind: .purge, items: items, perPage: 3)
        session.confirmScreen = """

        Selected paths:
          ~/dev/tracker-app/client/dist
          ~/dev/newsletter-site/.next
        ➤ Remove 2 artifacts, 57.6MB  Enter confirm, ESC cancel:
        """
        session.runOutput = "\r\n✓ ~/dev/tracker-app/client/dist, 250KB\r\n◎ Skipped ~/dev/x (path changed after review)\r\n======\r\nPurge incomplete\r\nEstimated space freed: 57.3MB | Items: 1 | Free: 100.00GB\r\n======\r\n"
        let job = PurgeJob(runner: RecordingRunner(exitCode: 0, output: ""), launcher: FakeLauncher(session: session), driver: fast, home: "/Users/test")

        let (lines, result) = try await collect(job.run(selection: Set(wanted), from: scan))
        XCTAssertEqual(session.selectedNames.count, 2)
        XCTAssertEqual(session.enterPresses, 2)
        XCTAssertTrue(lines.contains("✓ ~/dev/tracker-app/client/dist, 250KB"))
        XCTAssertEqual(result?.freedBytes, 57_300_000)
        XCTAssertEqual(result?.itemCount, 1)
        XCTAssertEqual(result?.problems, ["Skipped ~/dev/x (path changed after review)"])
    }

    func testRunRefusesWhenConfirmListsADifferentFolder() async throws {
        let scan = PurgeParser.scanResult(listing: try listing(), home: "/Users/test")
        let items = [FakeMenuItem(name: "dist", location: "~/dev/tracker-app/client", path: "~/dev/tracker-app/client/dist"),
                     FakeMenuItem(name: "dist", location: "~/dev/other", path: "~/dev/other/dist")]
        let session = FakeMenuSession(kind: .purge, items: items, perPage: 5)
        session.confirmScreen = "Selected paths:\n  ~/dev/other/dist\n➤ Remove 1 artifact, 1MB  Enter confirm, ESC cancel: "
        session.runOutput = "Estimated space freed: 1MB | Items: 1"
        let job = PurgeJob(runner: RecordingRunner(exitCode: 0, output: ""), launcher: FakeLauncher(session: session), driver: fast)
        do {
            _ = try await collect(job.run(selection: ["~/dev/tracker-app/client/dist"], from: scan))
            XCTFail("expected throw")
        } catch BurrowError.selectionMismatch {
        }
        XCTAssertEqual(session.enterPresses, 1)
        XCTAssertEqual(session.sent.last, "\u{1B}")
    }

    func testRunNeverTouchesCloudItems() async throws {
        let scan = PurgeParser.scanResult(listing: try listing(), home: "/Users/test")
        let cloud = try XCTUnwrap(scan.allItems.first { !$0.selectable })
        let launcher = FakeLauncher(session: FakeMenuSession(kind: .purge, items: []))
        let (_, result) = try await collect(PurgeJob(runner: RecordingRunner(exitCode: 0, output: ""), launcher: launcher, driver: fast)
            .run(selection: [cloud.id], from: scan))
        XCTAssertTrue(launcher.launched.isEmpty)
        XCTAssertEqual(result?.itemCount, 0)
    }

    func testSummaryDryRunAndNoArtifacts() {
        let a = PurgeParser.summarize(log: "Would free approximately: 116.1MB | Items: 4 | Free: 780.21GB", exitCode: 1)
        XCTAssertEqual(a.freedBytes, 116_100_000)
        XCTAssertEqual(a.itemCount, 4)
        let b = PurgeParser.summarize(log: "No artifacts were removed.\nFree space: 10GB", exitCode: 1)
        XCTAssertEqual(b.itemCount, 0)
        XCTAssertNil(b.freedBytes)
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let exitCode: Int32
    let output: String
    init(exitCode: Int32, output: String) { self.exitCode = exitCode; self.output = output }
    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String) {
        lock.withLock { recorded.append(args) }
        return (exitCode, output)
    }
}
