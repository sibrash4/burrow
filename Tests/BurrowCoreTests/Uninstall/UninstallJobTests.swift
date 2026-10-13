import XCTest
@testable import BurrowCore

final class UninstallJobTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "uninstall_list", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fastTimeouts() -> UninstallTimeouts {
        var t = UninstallTimeouts()
        t.firstPrompt = 1; t.preview = 1; t.removal = 2; t.poll = 0.01; t.promptGrace = 0
        return t
    }

    private func job(session: UninstallFakeSession) -> (UninstallJob, UninstallFakeLauncher) {
        let launcher = UninstallFakeLauncher(session: session)
        return (UninstallJob(runner: UninstallFakeRunner(output: "[]"), launcher: launcher, timeouts: fastTimeouts()), launcher)
    }

    private func scanResult(_ names: [(String, String, Int64?)], source: String = "App") -> ScanResult {
        let apps = names.map {
            UninstallApp(name: $0.0, bundleId: "com.example.\($0.0.lowercased())", source: source, uninstallName: $0.0,
                         path: "/Applications/\($0.0).app", sizeText: $0.1, bytes: $0.2)
        }
        return UninstallJob.makeResult(from: apps)
    }

    private func collect(_ stream: AsyncThrowingStream<JobEvent, Error>) async throws -> [JobEvent] {
        var events: [JobEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    // MARK: scan

    func testScanGroupsSortsAndNeverPreselects() async throws {
        let runner = UninstallFakeRunner(output: try fixture())
        let job = UninstallJob(runner: runner, launcher: UninstallFakeLauncher(session: UninstallFakeSession(frame: "")))
        let result = try await job.scan()

        XCTAssertEqual(runner.seen.all, [["uninstall", "--list"]])
        XCTAssertEqual(result.kind, .uninstall)
        XCTAssertEqual(result.groups.map(\.title), ["Applications", "Homebrew casks"])
        XCTAssertEqual(result.allItems.count, 25)
        XCTAssertTrue(result.defaultSelection.isEmpty)
        XCTAssertFalse(result.notes.isEmpty)

        let apps = try XCTUnwrap(result.groups.first)
        let sizes = apps.items.compactMap(\.bytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(apps.items.first?.bytes, sizes.max())
        XCTAssertNotNil(apps.items.first?.detail)
    }

    func testUnknownSizesSortLastAndPathIsIdFallback() {
        let apps = [
            UninstallApp(name: "Zed", bundleId: nil, source: "App", uninstallName: "Zed", path: "/Applications/Zed.app", sizeText: "N/A", bytes: nil),
            UninstallApp(name: "Big", bundleId: "x.big", source: "App", uninstallName: "Big", path: "/Applications/Big.app", sizeText: "2GB", bytes: 2_000_000_000),
            UninstallApp(name: "Small", bundleId: "x.small", source: "App", uninstallName: "Small", path: "/Applications/Small.app", sizeText: "1MB", bytes: 1_000_000),
        ]
        let items = UninstallJob.makeResult(from: apps).allItems
        XCTAssertEqual(items.map(\.title), ["Big", "Small", "Zed"])
        XCTAssertEqual(items.last?.id, "/Applications/Zed.app")
        XCTAssertNil(items.last?.bytes)
    }

    func testSameNameAppsAreNotSelectable() {
        let apps = [
            UninstallApp(name: "Twin", bundleId: "x.one", source: "App", uninstallName: "Twin", path: "/Applications/Twin.app", sizeText: "", bytes: 5),
            UninstallApp(name: "Twin", bundleId: "x.two", source: "App", uninstallName: "Twin", path: "/Users/test/Applications/Twin.app", sizeText: "", bytes: 4),
            UninstallApp(name: "Solo", bundleId: "x.solo", source: "App", uninstallName: "Solo", path: "/Applications/Solo.app", sizeText: "", bytes: 3),
        ]
        let items = UninstallJob.makeResult(from: apps).allItems
        XCTAssertEqual(items.filter(\.selectable).map(\.title), ["Solo"])
        XCTAssertNotNil(items.first { $0.title == "Twin" }?.note)
    }

    func testScanFailsOnNonZeroExit() async {
        let job = UninstallJob(runner: UninstallFakeRunner(code: 1, output: "boom"), launcher: UninstallFakeLauncher(session: UninstallFakeSession(frame: "")))
        do {
            _ = try await job.scan()
            XCTFail("expected error")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: run

    func testRunSendsYThenEnterOnlyAfterVerifyingTheList() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000), ("Beta", "1MB", 1_000_000), ("Gamma", "2MB", 2_000_000)])
        let ids = Set(scan.allItems.filter { $0.title != "Gamma" }.map(\.id))

        let session = UninstallFakeSession(frame: "Scanning applications...")
        session.onSend { s, keys in
            switch keys {
            case "y\r": s.show(UninstallScreens.plan(["Alpha", "Beta"]))
            case "\r":
                s.show("✓ [1/2] Alpha\n✓ [2/2] Beta\n", replace: false)
                s.show(UninstallScreens.summary(2, freed: "6.80MB", names: "Alpha, Beta"), replace: false)
                s.exit(0)
            default: break
            }
        }
        let (job, launcher) = job(session: session)

        let stream = job.run(selection: ids, from: scan)
        // Mole is still scanning: nothing may be sent yet.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(session.sent, [])
        session.show(UninstallScreens.matched([("Alpha", "5.8MB"), ("Beta", "1MB")]))

        let events = try await collect(stream)

        XCTAssertEqual(launcher.launches, [["uninstall", "Alpha", "Beta"]])
        XCTAssertFalse(launcher.launches.flatMap { $0 }.contains("--permanent"))
        XCTAssertFalse(launcher.launches.flatMap { $0 }.contains("--dry-run"))
        XCTAssertEqual(session.sent, ["y\r", "\r"])

        guard case .finished(let result)? = events.last else { return XCTFail("no result") }
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertEqual(result.freedBytes, 6_800_000)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testRunMismatchAnswersNoAndThrows() async throws {
        let scan = scanResult([("Alpha", "1MB", 1), ("Alphabet", "2MB", 2)])
        let alpha = try XCTUnwrap(scan.allItems.first { $0.title == "Alpha" })

        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "1MB"), ("Alphabet", "2MB")]))
        let (job, _) = job(session: session)

        do {
            _ = try await collect(job.run(selection: [alpha.id], from: scan))
            XCTFail("expected mismatch")
        } catch BurrowError.selectionMismatch(let expected, let actual) {
            XCTAssertEqual(expected, "Alpha")
            XCTAssertEqual(actual, "Alpha, Alphabet")
        }
        XCTAssertEqual(session.sent, ["n\r"])
        XCTAssertTrue(session.terminated)
    }

    func testRunMismatchWhenMoleMatchedNothing() async throws {
        let scan = scanResult([("Alpha", "1MB", 1)])
        let session = UninstallFakeSession(frame: "Warning: No application found matching 'Alpha'\nNo matching applications found.")
        let (job, _) = job(session: session)
        do {
            _ = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
            XCTFail("expected error")
        } catch let error as UninstallError {
            XCTAssertEqual(error, .appNotFound("Alpha"))
        }
        XCTAssertEqual(session.sent, [])
    }

    func testRunStopsIfConfirmScreenListsDifferentApps() async throws {
        let scan = scanResult([("Alpha", "1MB", 1)])
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "1MB")]))
        session.onSend { s, keys in
            if keys == "y\r" { s.show(UninstallScreens.plan(["Alpha", "Extra"])) }
        }
        let (job, _) = job(session: session)
        do {
            _ = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
            XCTFail("expected mismatch")
        } catch BurrowError.selectionMismatch {
        }
        XCTAssertEqual(session.sent, ["y\r", "q"])
        XCTAssertFalse(session.sent.contains("\r"))
    }

    func testPasswordPromptTerminatesWithoutTyping() async throws {
        let scan = scanResult([("Alpha", "1MB", 1)], source: "Homebrew")
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "1MB")]))
        session.onSend { s, keys in
            switch keys {
            case "y\r": s.show(UninstallScreens.plan(["Alpha"], brew: true))
            case "\r": s.show("\n➤ Admin required for Homebrew casks: openlogi\nEnter your credentials:\nPassword:", replace: false)
            default: break
            }
        }
        let (job, _) = job(session: session)
        do {
            _ = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
            XCTFail("expected admin error")
        } catch let error as UninstallError {
            XCTAssertEqual(error, .adminRequired(["Alpha"]))
        }
        XCTAssertTrue(session.terminated)
        XCTAssertEqual(session.sent, ["y\r", "\r"], "nothing typed after the password prompt")
    }

    func testRunRefusesEmptyAndAmbiguousSelections() async throws {
        let session = UninstallFakeSession(frame: "")
        let (job, launcher) = job(session: session)
        let scan = scanResult([("Alpha", "1MB", 1)])
        do {
            _ = try await collect(job.run(selection: [], from: scan))
            XCTFail("expected error")
        } catch let error as UninstallError {
            XCTAssertEqual(error, .nothingSelected)
        }

        var twin = scan
        twin.groups[0].items[0].selectable = false
        do {
            _ = try await collect(job.run(selection: Set(twin.allItems.map(\.id)), from: twin))
            XCTFail("expected error")
        } catch let error as UninstallError {
            XCTAssertEqual(error, .notSelectable("Alpha"))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testRunReportsFailuresFromSummary() async throws {
        let scan = scanResult([("Alpha", "1MB", 1)])
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "1MB")]))
        session.onSend { s, keys in
            switch keys {
            case "y\r": s.show(UninstallScreens.plan(["Alpha"]))
            case "\r":
                s.show("====\nUninstall incomplete\n• Failed: Alpha is still running\n====\n", replace: false)
                s.exit(0)
            default: break
            }
        }
        let (job, _) = job(session: session)
        let events = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
        guard case .finished(let result)? = events.last else { return XCTFail("no result") }
        XCTAssertEqual(result.problems, ["Failed: Alpha is still running"])
        XCTAssertNil(result.itemCount)
    }

    // MARK: preview

    func testPreviewLeftoversRunsDryRunAndCancels() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let item = try XCTUnwrap(scan.allItems.first)
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "5.8MB")]))
        session.onSend { s, keys in
            if keys == "y\r" { s.show(UninstallScreens.plan(["Alpha"])) }
        }
        let (job, launcher) = job(session: session)

        let lines = try await job.previewLeftovers(for: item)

        XCTAssertEqual(launcher.launches, [["uninstall", "--dry-run", "Alpha"]])
        XCTAssertEqual(session.sent, ["y\r", "q"])
        XCTAssertEqual(lines, ["~/Library/Preferences/com.example.alpha.plist, 4KB", "~/Library/Caches/com.example.alpha, 61KB"])
        XCTAssertTrue(session.terminated)
    }

    func testPreviewArgumentsAlwaysContainDryRun() {
        // previewLeftovers answers "y" to Mole's first prompt. That is only safe under --dry-run.
        for name in ["Alpha", "Microsoft Word", "--odd", "a b"] {
            XCTAssertTrue(UninstallJob.previewArguments(for: name).contains("--dry-run"), name)
            XCTAssertEqual(UninstallJob.previewArguments(for: name).first, "uninstall")
            XCTAssertFalse(UninstallJob.previewArguments(for: name).contains("--permanent"))
        }
    }

    func testPreviewLeftoversReadsTheWholeListEvenWhenItScrollsOffTheScreen() async throws {
        // A 40-row screen only shows the bottom of a long file list. The leftovers come from the transcript.
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let item = try XCTUnwrap(scan.allItems.first)
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "5.8MB")]))
        let files = (1...80).map { "  ✓ ~/Library/Caches/com.example.alpha/file\($0) , \($0)KB" }
        let full = "Files to be removed:\n\n◎ Alpha , 9MB\n  ✓ /Applications/Alpha.app , 5.8MB\n" + files.joined(separator: "\n")
            + "\n\n➤ Remove 1 app, 9MB  Enter confirm, ESC cancel: "
        session.onSend { s, keys in
            guard keys == "y\r" else { return }
            s.show(full, replace: false)
            s.show(files.suffix(8).joined(separator: "\n") + "\n\n➤ Remove 1 app, 9MB  Enter confirm, ESC cancel: ")
        }
        let (job, _) = job(session: session)
        let leftovers = try await job.previewLeftovers(for: item)
        XCTAssertEqual(leftovers.count, 80)
        XCTAssertEqual(leftovers.first, "~/Library/Caches/com.example.alpha/file1, 1KB")
    }

    func testMoleFinishingCleanlyWithoutAskingIsNotReportedAsACrash() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let session = UninstallFakeSession(frame: "Scanning applications...")
        session.show("Nothing to do here.\n")
        session.exit(0)
        let (job, _) = job(session: session)
        do {
            _ = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
            XCTFail("expected previewUnavailable")
        } catch UninstallError.previewUnavailable(let why) {
            XCTAssertEqual(why, "Nothing to do here.")
        }
        XCTAssertFalse(session.sent.contains("\r"), "Enter must never be sent")
    }

    func testMoleCrashingBeforeTheFirstPromptKeepsItsExitCode() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let session = UninstallFakeSession(frame: "Scanning applications...")
        session.exit(5)
        let (job, _) = job(session: session)
        do {
            _ = try await collect(job.run(selection: Set(scan.allItems.map(\.id)), from: scan))
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 5)
        }
    }

    func testPreviewLeftoversReportsMoleDyingAsAnError() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let item = try XCTUnwrap(scan.allItems.first)
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Alpha", "5.8MB")]))
        session.onSend { s, keys in
            if keys == "y\r" { s.show("Something went wrong\n"); s.exit(1) }
        }
        let (job, _) = job(session: session)
        do {
            _ = try await job.previewLeftovers(for: item)
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, let output) {
            XCTAssertEqual(code, 1)
            XCTAssertTrue(output.contains("Something went wrong"))
        }
    }

    func testPreviewLeftoversDeclinesWhenMatchDiffers() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let item = try XCTUnwrap(scan.allItems.first)
        let session = UninstallFakeSession(frame: UninstallScreens.matched([("Other", "1MB")]))
        let (job, _) = job(session: session)
        do {
            _ = try await job.previewLeftovers(for: item)
            XCTFail("expected mismatch")
        } catch BurrowError.selectionMismatch {
        }
        XCTAssertEqual(session.sent, ["n\r"])
    }

    func testPreviewTimesOutWhenMoleNeverPrompts() async throws {
        let scan = scanResult([("Alpha", "5.8MB", 5_800_000)])
        let item = try XCTUnwrap(scan.allItems.first)
        let session = UninstallFakeSession(frame: "Scanning applications...")
        let (job, _) = job(session: session)
        do {
            _ = try await job.previewLeftovers(for: item)
            XCTFail("expected timeout")
        } catch BurrowError.timeout {
        }
        XCTAssertEqual(session.sent, [])
        XCTAssertTrue(session.terminated)
    }
}
