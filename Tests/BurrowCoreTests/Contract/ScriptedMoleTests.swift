import XCTest
@testable import BurrowCore

/// The real PTYSession, virtual screen, MenuFrame, driver and jobs, run against scripted look-alikes of Mole.
final class ScriptedMoleTests: XCTestCase {
    private var directory: URL!

    private var pidFile: URL { directory.appendingPathComponent("pid") }

    override func setUpWithError() throws {
        directory = try makeTempDirectory()
        setenv("BURROW_SCRIPT_PIDFILE", pidFile.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BURROW_SCRIPT_PIDFILE")
        // The script leads its own session, so its pid is also its group: this ends `sleep 120` and other helpers too.
        if let pid = scriptPID { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private var scriptPID: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func launcher(_ script: String, name: String = "mo") throws -> PTYLauncher {
        PTYLauncher(executable: try writeExecutable(script, in: directory, name: name))
    }

    private struct NoRunner: CommandRunning {
        func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String) {
            XCTFail("no non-interactive command is expected: \(args)")
            return (1, "")
        }
    }

    private struct Events { var lines: [String] = []; var statuses: [String] = []; var result: RunResult? }

    private func drain(_ stream: AsyncThrowingStream<JobEvent, Error>) async throws -> Events {
        var events = Events()
        for try await event in stream {
            switch event {
            case .line(let l): events.lines.append(l)
            case .status(let s): events.statuses.append(s)
            case .finished(let r): events.result = r
            }
        }
        return events
    }

    // MARK: Installers

    func testInstallerScanSurvivesTheDryRunBannerThatMentionsNoInstallerFiles() async throws {
        // The banner says "No installer files will be removed". It once made the scan stop before the menu drew.
        let job = InstallerJob(launcher: try launcher(ScriptedMole.installer), driver: MoleMenuDriver(settleTime: 0))
        let scan = try await job.scan()
        XCTAssertEqual(scan.allItems.map(\.id), ["a.dmg | Downloads", "b.zip | Downloads", "c.pkg | Downloads", "d.dmg | Downloads", "e.dmg | Downloads"])
        XCTAssertEqual(scan.allItems.map(\.bytes), [1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000])
    }

    func testInstallerRunSelectsReadsTheHeaderConfirmsAndFinishes() async throws {
        let job = InstallerJob(launcher: try launcher(ScriptedMole.installer), driver: MoleMenuDriver(settleTime: 0))
        let scan = try await job.scan()
        let events = try await drain(job.run(selection: ["b.zip | Downloads", "d.dmg | Downloads"], from: scan))
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertEqual(result.freedBytes, Int64(6.0 * 1_048_576))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events.statuses, ["Opening Mole", "Selecting 2 items", "Removing installers"])
    }

    func testDriverReportsMolesOwnHeaderTotalFromTheVirtualScreen() async throws {
        let session = try launcher(ScriptedMole.installer).launch(["installer", "--dry-run"], environment: MenuSession.environment,
                                                                  columns: MenuSession.columns, rows: MenuSession.rows)
        defer { session.terminate() }
        let report = try await MoleMenuDriver(settleTime: 0).select(exactly: ["a.dmg | Downloads", "e.dmg | Downloads"], in: session)
        XCTAssertEqual(report.selectedKeys.sorted(), ["a.dmg | Downloads", "e.dmg | Downloads"])
        XCTAssertEqual(report.selectedSize, "6.0MB")
        XCTAssertEqual(report.totalRows, 5)
        let confirm = try await MenuSession.transcriptWait(session, timeout: 5) { $0.contains(MenuSession.confirmMarker) }
        let wanted = [ScanItem(id: "a", title: "a.dmg", bytes: 1_000_000), ScanItem(id: "e", title: "e.dmg", bytes: 5_000_000)]
        XCTAssertNil(InstallerParser.checkConfirm(screen: confirm, wanted: wanted))
        try session.send(MenuSession.escape)
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 0)
    }

    func testMoleFinishingWithoutAMenuIsFinishedNotAnError() async throws {
        let script = ScriptedMole.exits(code: 0, message: "Great! No installer files to clean")
        let job = InstallerJob(launcher: try launcher(script), driver: MoleMenuDriver(settleTime: 0))
        let scan = ScanResult(kind: .installers, groups: [ScanGroup(id: "d", title: "Downloads", items: [ScanItem(id: "a.dmg | Downloads", title: "a.dmg", bytes: 1)])])
        let events = try await drain(job.run(selection: ["a.dmg | Downloads"], from: scan))
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.itemCount, 0)
        XCTAssertEqual(result.problems.count, 1, "the user is told nothing was removed")
    }

    func testMoleCrashingBeforeTheMenuIsAnErrorWithItsExitCode() async throws {
        let script = ScriptedMole.exits(code: 2, message: "something broke")
        let job = InstallerJob(launcher: try launcher(script), driver: MoleMenuDriver(settleTime: 0))
        let scan = ScanResult(kind: .installers, groups: [ScanGroup(id: "d", title: "Downloads", items: [ScanItem(id: "a.dmg | Downloads", title: "a.dmg", bytes: 1)])])
        do {
            _ = try await drain(job.run(selection: ["a.dmg | Downloads"], from: scan))
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, let output) {
            XCTAssertEqual(code, 2)
            XCTAssertTrue(output.contains("something broke"))
        }
    }

    func testInstallerScanReportsAMoleThatDiesInsteadOfWaitingForTheTimeout() async throws {
        let job = InstallerJob(launcher: try launcher(ScriptedMole.exits(code: 2, message: "boom")), driver: MoleMenuDriver(settleTime: 0))
        let started = Date()
        do {
            _ = try await job.scan()
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, _) {
            XCTAssertEqual(code, 2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "must not sit out the 120 s scan timeout")
    }

    func testInstallerScanWithNothingToCleanIsEmpty() async throws {
        let job = InstallerJob(launcher: try launcher(ScriptedMole.exits(code: 0, message: "Great! No installer files to clean")),
                               driver: MoleMenuDriver(settleTime: 0))
        let scan = try await job.scan()
        XCTAssertTrue(scan.groups.isEmpty)
    }

    // MARK: Purge

    func testPurgeRunWithMolesLaggingPathLineSelectsExactlyTheRequestedFolders() async throws {
        let job = PurgeJob(runner: NoRunner(), launcher: try launcher(ScriptedMole.purge(lag: "0.08")))
        let items = ["~/dev/a/node_modules", "~/dev/a/dist", "~/dev/b/node_modules", "~/dev/c/.venv"].map {
            ScanItem(id: $0, title: $0, bytes: 1_000_000, paths: [$0])
        }
        let scan = ScanResult(kind: .purge, groups: [ScanGroup(id: "g", title: "g", items: items)])
        let events = try await drain(job.run(selection: ["~/dev/a/dist", "~/dev/b/node_modules"], from: scan))
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertEqual(result.freedBytes, 9_000_000, "2 MB + 7 MB, from Mole's own summary")
        XCTAssertTrue(events.lines.contains { $0.contains("~/dev/a/dist") })
        XCTAssertTrue(events.lines.contains { $0.contains("~/dev/b/node_modules") })
        XCTAssertFalse(events.lines.contains { $0.contains("~/dev/a/node_modules") || $0.contains(".venv") })
    }

    // MARK: Clean

    /// Answers the fresh preview every clean run makes first: a completed dry run whose list matches `oneItemScan`.
    private struct PreviewRunner: CommandRunning {
        let listURL: URL
        func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String) {
            guard args == ["clean", "--dry-run"] else {
                XCTFail("only the clean preview is expected: \(args)")
                return (1, "")
            }
            try "=== g ===\n/tmp/x  # 1.0MB\n".write(to: listURL, atomically: true, encoding: .utf8)
            return (0, "Dry run complete - no changes made\nPotential space: 1.0MB | Items: 1 | Categories: 1\n")
        }
    }

    private func cleanJob(_ script: String) throws -> CleanJob {
        let list = directory.appendingPathComponent("clean-list.txt")
        return CleanJob(runner: PreviewRunner(listURL: list), launcher: try launcher(script),
                 cleanListURL: list,
                 whitelistURL: directory.appendingPathComponent("whitelist"),
                 backupURL: directory.appendingPathComponent("whitelist.backup"),
                 home: directory.path, pollSeconds: 0.05, drainSeconds: 0.2)
    }

    private var oneItemScan: ScanResult {
        ScanResult(kind: .clean, groups: [ScanGroup(id: "g", title: "g", items: [ScanItem(id: "x", title: "X", paths: ["/tmp/x"])])])
    }

    func testCleanAnswersMolesAdminPromptWithSpaceAndNeverPressesEnterOrTypesAnything() async throws {
        let job = try cleanJob(ScriptedMole.clean)
        let events = try await drain(job.run(selection: ["x"], from: oneItemScan))
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.exitCode, 0, "the script exits 9 if it gets anything but Space: \(result.log)")
        XCTAssertEqual(result.freedBytes, 1_200_000_000)
        XCTAssertEqual(result.itemCount, 17)
        XCTAssertTrue(result.log.contains("Skipped"), result.log)
        XCTAssertFalse(result.log.contains("WRONG ANSWER"))
    }

    func testCleanStopsAtAPasswordPromptAndSendsNothing() async throws {
        let job = try cleanJob(ScriptedMole.cleanPasswordPrompt)
        do {
            _ = try await drain(job.run(selection: ["x"], from: oneItemScan))
            XCTFail("expected passwordRequested")
        } catch let error as CleanJobError {
            XCTAssertEqual(error, .passwordRequested)
        }
    }

    // MARK: Uninstall

    private func uninstallJob(_ script: String) throws -> UninstallJob {
        var timeouts = UninstallTimeouts()
        timeouts.firstPrompt = 10; timeouts.preview = 10; timeouts.removal = 10; timeouts.poll = 0.05
        return UninstallJob(runner: NoRunner(), launcher: try launcher(script), timeouts: timeouts)
    }

    private var fluxScan: ScanResult {
        ScanResult(kind: .uninstall, groups: [ScanGroup(id: "a", title: "Applications", items: [
            ScanItem(id: "org.herf.Flux", title: "Flux", detail: "/Applications/Flux.app", bytes: 5_800_000, paths: ["/Applications/Flux.app"], selectedByDefault: false),
        ])])
    }

    func testUninstallRunThroughARealPTYWithAFileListLongerThanTheScreen() async throws {
        let job = try uninstallJob(ScriptedMole.uninstall)
        let events = try await drain(job.run(selection: ["org.herf.Flux"], from: fluxScan))
        let result = try XCTUnwrap(events.result)
        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.freedBytes, 5_900_000)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(events.statuses.contains("Removing Flux"), "\(events.statuses)")
    }

    func testUninstallPreviewThroughARealPTYReturnsEveryLeftoverEvenThoughTheListScrolled() async throws {
        let job = try uninstallJob(ScriptedMole.uninstall)
        let item = try XCTUnwrap(fluxScan.allItems.first)
        let leftovers = try await job.previewLeftovers(for: item)
        XCTAssertEqual(leftovers.count, 70, "the first lines scrolled off a 40-row screen")
        XCTAssertEqual(leftovers.first, "~/Library/Caches/org.herf.Flux/file1, 1KB")
        try await waitFor("the script to be stopped") { self.scriptPID.map { !self.isAlive($0) } ?? false }
    }

    // MARK: Cancelling a run terminates Mole

    func testCancellingAMenuRunTerminatesMole() async throws {
        let job = InstallerJob(launcher: try launcher(ScriptedMole.installer), driver: MoleMenuDriver(settleTime: 0))
        let scan = ScanResult(kind: .installers, groups: [ScanGroup(id: "d", title: "Downloads", items: [
            ScanItem(id: "a.dmg | Downloads", title: "a.dmg", bytes: 1_000_000)])])
        let consumer = Task { _ = try? await self.drain(job.run(selection: ["a.dmg | Downloads"], from: scan)) }
        try await waitFor("Mole to start") { self.scriptPID != nil }
        let pid = try XCTUnwrap(scriptPID)
        XCTAssertTrue(isAlive(pid))
        consumer.cancel()
        try await waitFor("Mole to be terminated") { !self.isAlive(pid) }
    }

    func testCancellingACleanRunTerminatesMole() async throws {
        let job = try cleanJob(ScriptedMole.cleanHangs)
        let consumer = Task { _ = try? await self.drain(job.run(selection: ["x"], from: self.oneItemScan)) }
        try await waitFor("Mole to start") { self.scriptPID != nil }
        let pid = try XCTUnwrap(scriptPID)
        consumer.cancel()
        try await waitFor("Mole to be terminated") { !self.isAlive(pid) }
    }

    func testCancellingAnUninstallRunTerminatesMole() async throws {
        let job = try uninstallJob(ScriptedMole.uninstall)
        let consumer = Task { _ = try? await self.drain(job.run(selection: ["org.herf.Flux"], from: self.fluxScan)) }
        try await waitFor("Mole to start") { self.scriptPID != nil }
        let pid = try XCTUnwrap(scriptPID)
        consumer.cancel()
        try await waitFor("Mole to be terminated") { !self.isAlive(pid) }
    }

    // MARK: Mole throws away keys typed right after a confirm prompt

    func testEnterAfterTheConfirmPromptSurvivesMolesInputFlush() async throws {
        let job = try uninstallJob(ScriptedMole.uninstallDrainingInput)
        let events = try await drain(job.run(selection: ["org.herf.Flux"], from: fluxScan))
        XCTAssertEqual(try XCTUnwrap(events.result).itemCount, 1)
    }

    func testControlWithoutTheGraceTimeTheFlushedEnterNeverArrives() async throws {
        // Documents the hazard the grace time protects against: Enter pressed the instant the prompt shows
        // is flushed away, and Mole waits forever (here: until the test's short removal timeout).
        var timeouts = UninstallTimeouts()
        timeouts.firstPrompt = 10; timeouts.preview = 10; timeouts.removal = 2; timeouts.poll = 0.05; timeouts.promptGrace = 0
        let job = UninstallJob(runner: NoRunner(), launcher: try launcher(ScriptedMole.uninstallDrainingInput), timeouts: timeouts)
        do {
            _ = try await drain(job.run(selection: ["org.herf.Flux"], from: fluxScan))
            XCTFail("expected the run to stall")
        } catch BurrowError.timeout {
        }
    }

    func testMenuRunEnterAlsoWaitsForAQuietScreen() async throws {
        XCTAssertTrue(ScriptedMole.installerDrainingInput.contains("tcflush"), "the script must really flush input")
        let job = InstallerJob(launcher: try launcher(ScriptedMole.installerDrainingInput), driver: MoleMenuDriver(settleTime: 0))
        let scan = try await job.scan()
        let events = try await drain(job.run(selection: ["b.zip | Downloads"], from: scan))
        XCTAssertEqual(try XCTUnwrap(events.result).itemCount, 1)
    }
}
