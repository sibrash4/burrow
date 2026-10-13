import XCTest
@testable import BurrowCore

final class CleanJobTests: TempDirTestCase {
    private var listURL: URL { dir.appendingPathComponent("config/clean-list.txt") }
    private let original = Data("# my whitelist\n/Users/test/Documents/keep\n".utf8)

    private func makeJob(_ mole: FakeMole, _ launcher: CleanFakeLauncher) -> CleanJob {
        CleanJob(
            runner: mole, launcher: launcher,
            cleanListURL: listURL, whitelistURL: whitelist, backupURL: backup,
            home: "/Users/test", pollSeconds: 0.01, drainSeconds: 0
        )
    }

    private func setUpJob(
        session: FakeSession? = FakeSession(chunks: CleanTranscripts.skipSudoThenFinish),
        whitelistContent: Data? = nil
    ) throws -> (CleanJob, FakeMole, CleanFakeLauncher) {
        if let whitelistContent { try write(whitelistContent) }
        let mole = FakeMole(whitelistURL: whitelist, listURL: listURL)
        let launcher = CleanFakeLauncher(session: session)
        return (makeJob(mole, launcher), mole, launcher)
    }

    private func item(_ title: String, in scan: ScanResult) throws -> ScanItem {
        try XCTUnwrap(scan.allItems.first { $0.title == title }, "no item titled \(title)")
    }

    private func selection(_ scan: ScanResult, without titles: [String]) throws -> Set<ScanItem.ID> {
        var selected = scan.defaultSelection
        for title in titles { selected.remove(try item(title, in: scan).id) }
        return selected
    }

    // MARK: Scan

    func testScanRunsDryRunAndBuildsRows() async throws {
        let (job, mole, _) = try setUpJob()
        let scan = try await job.scan()

        XCTAssertEqual(mole.calls, [["clean", "--dry-run"]])
        XCTAssertEqual(mole.environments[0]["MOLE_TEST_NO_AUTH"], "1")
        XCTAssertEqual(mole.environments[0]["NO_COLOR"], "1")
        XCTAssertEqual(scan.kind, .clean)
        XCTAssertEqual(scan.reportedTotalBytes, 9_510_000_000)
        XCTAssertNoThrow(try item("Claude logs", in: scan))
        XCTAssertNoThrow(try item("Chrome service worker cache", in: scan))
        XCTAssertFalse(scan.notes.isEmpty)
    }

    func testScanNeverPassesAnythingButDryRun() async throws {
        let (job, mole, launcher) = try setUpJob()
        _ = try await job.scan()
        XCTAssertTrue(mole.calls.allSatisfy { $0.contains("--dry-run") })
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testScanFailsWhenMoleFails() async throws {
        let (job, mole, _) = try setUpJob()
        mole.exitCode = 3
        do {
            _ = try await job.scan()
            XCTFail("expected an error")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 3)
        }
    }

    func testScanFailsWhenCleanListIsMissing() async throws {
        let (job, mole, _) = try setUpJob()
        mole.writesList = false
        do {
            _ = try await job.scan()
            XCTFail("expected an error")
        } catch BurrowError.parseFailed {
        }
    }

    func testScanRejectsAStaleCleanList() async throws {
        let (job, mole, _) = try setUpJob()
        mole.writesList = false
        try CleanFixtures.text("clean_list").write(to: listURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: listURL.path)
        do {
            _ = try await job.scan()
            XCTFail("expected an error")
        } catch BurrowError.parseFailed {
        }
    }

    // MARK: Run

    func testRunWithEverythingTickedLeavesTheWhitelistAlone() async throws {
        let (job, mole, launcher) = try setUpJob(whitelistContent: original)
        let scan = try await job.scan()
        let callsAfterScan = mole.calls.count

        let events = try await collectEvents(job.run(selection: scan.defaultSelection, from: scan))

        XCTAssertEqual(mole.calls.count, callsAfterScan, "no extra preview when nothing is protected")
        XCTAssertEqual(launcher.launches, [["clean"]])
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testUntickedRowsAreProtectedForTheRunThenRestored() async throws {
        let (job, mole, launcher) = try setUpJob(whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs", "Google (Chrome) cache", "Trash", "npm cache"])

        let whitelistAtLaunch = LockedBox<String?>(nil)
        let whitelistFile = whitelist
        launcher.onLaunch = { whitelistAtLaunch.set(try? String(contentsOf: whitelistFile, encoding: .utf8)) }

        let events = try await collectEvents(job.run(selection: chosen, from: scan))

        let during = try XCTUnwrap(whitelistAtLaunch.get())
        XCTAssertTrue(during.hasPrefix("# my whitelist\n/Users/test/Documents/keep\n"))
        XCTAssertTrue(during.contains("\n/Users/test/Library/Logs/Claude-3p\n"))
        XCTAssertTrue(during.contains("\n/Users/test/Library/Caches/Google\n"))
        XCTAssertTrue(during.contains("\n/Users/test/Library/Caches/Google/Chrome/Default\n"))
        XCTAssertTrue(during.contains("\n/Users/test/.Trash\n"), "Mole checks the Trash folder, not its contents")
        XCTAssertTrue(during.contains("\n/Users/test/.npm/_cacache/*\n"))
        XCTAssertFalse(during.contains("Service Worker"), "ticked rows are not protected")

        XCTAssertEqual(try bytes(), original, "restored byte for byte")
        XCTAssertFalse(backupExists)
        XCTAssertEqual(mole.calls.count, 2, "scan, then one verification preview")
        XCTAssertEqual(launcher.launches, [["clean"]])
        XCTAssertEqual(launcher.environments[0]["MOLE_TEST_NO_AUTH"], "1")
        XCTAssertTrue(events.statuses.contains("Checking your selection"))
    }

    func testMissingWhitelistGetsDefaultsDuringTheRunAndIsRemovedAfter() async throws {
        let (job, _, launcher) = try setUpJob()
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs"])

        let whitelistAtLaunch = LockedBox<String?>(nil)
        let whitelistFile = whitelist
        launcher.onLaunch = { whitelistAtLaunch.set(try? String(contentsOf: whitelistFile, encoding: .utf8)) }

        _ = try await collectEvents(job.run(selection: chosen, from: scan))

        let during = try XCTUnwrap(whitelistAtLaunch.get())
        XCTAssertTrue(during.contains("/Users/test/Library/Mobile Documents*"), "optional defaults stay in force")
        XCTAssertTrue(during.contains("/Users/test/Library/Logs/Claude-3p"))
        XCTAssertFalse(whitelistExists)
        XCTAssertFalse(backupExists)
    }

    func testVerificationMismatchStopsBeforeCleaningAndRestores() async throws {
        let (job, mole, launcher) = try setUpJob(whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs"])
        mole.honorsWhitelist = false

        do {
            _ = try await collectEvents(job.run(selection: chosen, from: scan))
            XCTFail("expected selectionMismatch")
        } catch BurrowError.selectionMismatch(let expected, let actual) {
            XCTAssertTrue(expected.contains("1 unticked item"))
            XCTAssertTrue(actual.contains("Claude logs"))
        }

        XCTAssertTrue(launcher.launches.isEmpty, "nothing was cleaned")
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
    }

    func testCommandRowThatStaysQueuedIsAMismatch() async throws {
        let (job, mole, launcher) = try setUpJob(whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["npm cache"])
        mole.honorsWhitelist = false

        do {
            _ = try await collectEvents(job.run(selection: chosen, from: scan))
            XCTFail("expected selectionMismatch")
        } catch BurrowError.selectionMismatch(_, let actual) {
            XCTAssertTrue(actual.contains("npm cache"))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(try bytes(), original)
    }

    func testRowsThatCannotBeProtectedAreNeverWhitelisted() async throws {
        let (job, _, launcher) = try setUpJob(whitelistContent: original)
        let scan = ScanResult(kind: .clean, groups: [ScanGroup(id: "g", title: "Developer tools", items: [
            ScanItem(id: "clean:cmd:mystery", title: "mystery cache", selectable: false, selectedByDefault: true, note: "Always cleaned by Mole"),
            ScanItem(id: "clean:x", title: "Claude logs", paths: ["/Users/test/Library/Logs/Claude-3p"]),
        ])])

        let whitelistAtLaunch = LockedBox<String?>(nil)
        let whitelistFile = whitelist
        launcher.onLaunch = { whitelistAtLaunch.set(try? String(contentsOf: whitelistFile, encoding: .utf8)) }
        // Neither row is in the selection: only the selectable one is protected.
        _ = try? await collectEvents(job.run(selection: [], from: scan))

        let during = try XCTUnwrap(whitelistAtLaunch.get())
        XCTAssertTrue(during.contains("/Users/test/Library/Logs/Claude-3p"))
        XCTAssertFalse(during.contains("mystery"))
    }

    func testRestoresWhenTheLaunchFails() async throws {
        let (job, _, launcher) = try setUpJob(session: nil, whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs"])
        do {
            _ = try await collectEvents(job.run(selection: chosen, from: scan))
            XCTFail("expected an error")
        } catch BurrowError.moleNotFound {
        }
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
    }

    func testPasswordPromptStopsTheRunWithoutTypingAnything() async throws {
        let session = FakeSession(chunks: ["Clean Your Mac\n", "➤ Enter your credentials:\nPassword:"])
        let (job, _, _) = try setUpJob(session: session, whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs"])

        do {
            _ = try await collectEvents(job.run(selection: chosen, from: scan))
            XCTFail("expected passwordRequested")
        } catch let error as CleanJobError {
            XCTAssertEqual(error, .passwordRequested)
        }
        XCTAssertTrue(session.terminated)
        XCTAssertEqual(session.sent, [], "no keys were sent")
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
    }

    func testSystemCachePromptIsSkippedWithSpaceOnce() async throws {
        let session = FakeSession(chunks: CleanTranscripts.skipSudoThenFinish)
        let (job, _, _) = try setUpJob(session: session)
        let scan = try await job.scan()
        let events = try await collectEvents(job.run(selection: scan.defaultSelection, from: scan))

        XCTAssertEqual(session.sent, [" "])
        XCTAssertTrue(events.lines.contains { $0.contains("skipping") })
    }

    func testFirstTimeSetupPromptGetsEnter() async throws {
        let session = FakeSession(chunks: [
            "First-time setup\nmacOS will request permissions.\n➤ Press Enter to continue: ",
            "\nCleanup complete\nTracked cleanup: 5KB | Items cleaned: 1\n",
        ])
        let (job, _, _) = try setUpJob(session: session)
        let scan = try await job.scan()
        _ = try await collectEvents(job.run(selection: scan.defaultSelection, from: scan))
        XCTAssertEqual(session.sent, ["\r"])
    }

    func testRunReportsFreedSpaceAndProgress() async throws {
        let (job, _, _) = try setUpJob()
        let scan = try await job.scan()
        let events = try await collectEvents(job.run(selection: scan.defaultSelection, from: scan))

        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.freedBytes, 1_200_000_000)
        XCTAssertEqual(result.itemCount, 17)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(result.log.contains("Cleanup complete"))
        XCTAssertTrue(events.statuses.contains("Cleaning Browsers"))
        XCTAssertFalse(events.statuses.contains { $0.contains("need sudo") })
    }

    func testCancelTerminatesMoleAndRestoresTheWhitelist() async throws {
        let session = FakeSession(chunks: ["Clean Your Mac\n"], neverExits: true)
        let (job, _, launcher) = try setUpJob(session: session, whitelistContent: original)
        let scan = try await job.scan()
        let chosen = try selection(scan, without: ["Claude logs"])

        let consumer = Task { _ = try? await collectEvents(job.run(selection: chosen, from: scan)) }
        try await waitUntil { !launcher.launches.isEmpty }
        XCTAssertNotEqual(try bytes(), original, "protected while running")
        consumer.cancel()

        let backupFile = backup
        try await waitUntil { session.terminated && !FileManager.default.fileExists(atPath: backupFile.path) }
        XCTAssertEqual(try bytes(), original)
    }

    // MARK: Always keep

    func testKeepPatternsAreFoldersSoNewFilesStayProtected() async throws {
        let (job, _, _) = try setUpJob()
        let scan = try await job.scan()
        XCTAssertEqual(job.keepPatterns(for: try item("Claude logs", in: scan)), ["/Users/test/Library/Logs/Claude-3p"])
        XCTAssertEqual(job.keepPatterns(for: try item("Google (Chrome) cache", in: scan)), ["/Users/test/Library/Caches/Google"])
        XCTAssertEqual(job.keepPatterns(for: try item("Trash", in: scan)), ["/Users/test/.Trash"])
        XCTAssertEqual(job.keepPatterns(for: try item("npm cache", in: scan)), ["/Users/test/.npm/_cacache/*"])
        XCTAssertEqual(
            job.keepPatterns(for: try item("Chrome service worker cache", in: scan)),
            ["/Users/test/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*"]
        )
        XCTAssertEqual(job.keepPatterns(for: try item("Mail data", in: scan)), [])
    }

    func testAlwaysKeepWritesTheBlockAndNextPreviewDropsTheRow() async throws {
        let (job, _, _) = try setUpJob(whitelistContent: original)
        let scan = try await job.scan()
        try job.alwaysKeep(try item("Claude logs", in: scan))

        XCTAssertEqual(try job.keeps.list(), ["/Users/test/Library/Logs/Claude-3p"])
        let rescanned = try await job.scan()
        XCTAssertNil(rescanned.allItems.first { $0.title == "Claude logs" })
        XCTAssertTrue(try text().hasPrefix("# my whitelist\n/Users/test/Documents/keep\n"))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}

struct WaitTimedOut: Error {}

func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw WaitTimedOut() }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
