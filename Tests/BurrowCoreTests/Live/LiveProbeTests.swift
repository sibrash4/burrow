import XCTest
@testable import BurrowCore

/// Read-only probes against the real Mole on this Mac. Skipped unless BURROW_LIVE=1.
/// Only ever runs `mo ... --dry-run`, `mo uninstall --list`, and quits menus with q.
final class LiveProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BURROW_LIVE"] == "1", "set BURROW_LIVE=1")
    }

    func testDumpPurgeMenuFrame() async throws {
        let session = try PTYLauncher().launch(["purge", "--dry-run"], environment: MenuSession.environment, columns: 240, rows: 60)
        defer { session.terminate() }
        let started = Date()
        let frame = try await session.waitForFrame(timeout: 120) { $0.contains("Select Artifacts") && $0.contains("Quit") }
        print("LIVE purge first menu frame after \(Date().timeIntervalSince(started))s\n\(frame)\n=====")
        print("PARSE:", String(describing: MenuFrame.parse(frame).map { ($0.header, $0.rows.count, $0.isComplete, $0.cursorIndex as Any, $0.cursorKey as Any) }))
        try session.send(TerminalKey.quit)
        let code = try await session.waitForExit(timeout: 20)
        print("LIVE purge exit \(code)")
    }
}

extension LiveProbeTests {
    private func summarize(_ scan: ScanResult) -> String {
        var out = "kind=\(scan.kind) groups=\(scan.groups.count) items=\(scan.allItems.count) reported=\(scan.reportedTotalBytes.map(ByteSize.format) ?? "nil") sum=\(ByteSize.format(scan.groups.reduce(0) { $0 + $1.totalBytes })) notes=\(scan.notes.count)\n"
        for g in scan.groups {
            out += "  [\(g.title)] \(g.items.count) items \(ByteSize.format(g.totalBytes))\n"
            for i in g.items.prefix(6) {
                out += "     - \(i.title) | \(i.detail ?? "-") | \(i.bytes.map(ByteSize.format) ?? "nil") | sel=\(i.selectable) def=\(i.selectedByDefault) paths=\(i.paths.count) id=\(i.id)\(i.note.map { " note=\($0)" } ?? "")\n"
            }
        }
        for n in scan.notes { out += "  NOTE: \(n)\n" }
        return out
    }

    func testScanClean() async throws {
        let job = CleanJob(runner: ProcessRunner(), launcher: PTYLauncher())
        let t = Date()
        let scan = try await job.scan()
        print("LIVE clean (\(Int(Date().timeIntervalSince(t)))s)\n" + summarize(scan))
    }

    func testScanPurge() async throws {
        let job = PurgeJob(runner: ProcessRunner(), launcher: PTYLauncher())
        let t = Date()
        let scan = try await job.scan()
        print("LIVE purge (\(Int(Date().timeIntervalSince(t)))s)\n" + summarize(scan))
    }

    func testScanInstallers() async throws {
        let job = InstallerJob(launcher: PTYLauncher())
        let t = Date()
        let scan = try await job.scan()
        print("LIVE installers (\(Int(Date().timeIntervalSince(t)))s)\n" + summarize(scan))
    }

    func testScanUninstall() async throws {
        let job = UninstallJob(runner: ProcessRunner(), launcher: PTYLauncher())
        let t = Date()
        let scan = try await job.scan()
        print("LIVE uninstall (\(Int(Date().timeIntervalSince(t)))s)\n" + summarize(scan))
    }
}

extension LiveProbeTests {
    /// Real `mo installer --dry-run` PTY: select 2 specific rows, check header, Enter, confirm parse, finish.
    func testInstallerDriverSelectTwo() async throws {
        var job = InstallerJob(launcher: PTYLauncher())
        let scan = try await job.scan()
        print("LIVE installer scan: \(scan.allItems.count) items, sizes sum \(ByteSize.format(scan.allItems.reduce(0) { $0 + ($1.bytes ?? 0) }))")
        let pick = scan.allItems.filter { $0.selectable }
        XCTAssertGreaterThanOrEqual(pick.count, 4)
        let chosen = [pick[1], pick[3]]
        print("LIVE installer chose: \(chosen.map { "\($0.id) \($0.bytes.map(ByteSize.format) ?? "?")" })")

        // Drive the menu by hand first so the header can be inspected before Enter.
        let session = try PTYLauncher().launch(["installer", "--dry-run"], environment: MenuSession.environment, columns: MenuSession.columns, rows: MenuSession.rows)
        defer { session.terminate() }
        let driver = MoleMenuDriver()
        let report = try await driver.select(exactly: chosen.map(\.id), in: session)
        print("LIVE installer report: \(report)")
        let confirm = try await MenuSession.transcriptWait(session, timeout: 30) { $0.contains(MenuSession.confirmMarker) }
        print("LIVE installer confirm transcript tail:\n\(String(confirm.suffix(900)))")
        print("LIVE installer checkConfirm: \(String(describing: InstallerParser.checkConfirm(screen: confirm, wanted: chosen)))")
        try session.send(MenuSession.escape)
        let code = try await session.waitForExit(timeout: 30)
        print("LIVE installer exit after ESC: \(code)")
    }

    /// Full job.run against `--dry-run` (the seam only lives in tests).
    func testInstallerJobRunDryRun() async throws {
        var job = InstallerJob(launcher: PTYLauncher())
        job.runArguments = ["installer", "--dry-run"]
        let scan = try await job.scan()
        let pick = scan.allItems.filter { $0.selectable }
        let chosen = [pick[1], pick[3]]
        var lines: [String] = [], statuses: [String] = [], result: RunResult?
        for try await event in job.run(selection: Set(chosen.map(\.id)), from: scan) {
            switch event {
            case .line(let l): lines.append(l)
            case .status(let s): statuses.append(s)
            case .finished(let r): result = r
            }
        }
        print("LIVE installer job.run statuses=\(statuses)\nlines=\(lines)\nresult=\(String(describing: result))")
    }
}

extension LiveProbeTests {
    private func purgePick(_ scan: ScanResult) -> [ScanItem] {
        let ok = scan.allItems.filter { $0.selectable && ($0.bytes ?? 0) > 0 }
        return Array(ok.prefix(2))
    }

    func testPurgeDriverSelectTwo() async throws {
        let scan = try await PurgeJob(runner: ProcessRunner(), launcher: PTYLauncher()).scan()
        let chosen = purgePick(scan)
        XCTAssertEqual(chosen.count, 2)
        print("LIVE purge chose: \(chosen.map { "\($0.id) \($0.bytes.map(ByteSize.format) ?? "?")" })")
        let session = try PTYLauncher().launch(["purge", "--dry-run"], environment: MenuSession.environment, columns: MenuSession.columns, rows: MenuSession.rows)
        defer { session.terminate() }
        let started = Date()
        let report = try await MoleMenuDriver().select(exactly: chosen.map(\.id), in: session)
        print("LIVE purge report (\(Int(Date().timeIntervalSince(started)))s): \(report)")
        let confirm = try await MenuSession.transcriptWait(session, timeout: 60) { $0.contains(MenuSession.confirmMarker) }
        print("LIVE purge confirm tail:\n\(String(confirm.suffix(700)))")
        print("LIVE purge checkConfirm: \(String(describing: PurgeParser.checkConfirm(screen: confirm, wanted: chosen.map(\.id))))")
        try session.send(MenuSession.escape)
        let code = try await session.waitForExit(timeout: 30)
        print("LIVE purge exit after ESC: \(code)")
    }

    func testPurgeJobRunDryRun() async throws {
        var job = PurgeJob(runner: ProcessRunner(), launcher: PTYLauncher())
        job.runArguments = ["purge", "--dry-run"]
        let scan = try await job.scan()
        let chosen = purgePick(scan)
        var lines: [String] = [], statuses: [String] = [], result: RunResult?
        for try await event in job.run(selection: Set(chosen.map(\.id)), from: scan) {
            switch event {
            case .line(let l): lines.append(l)
            case .status(let s): statuses.append(s)
            case .finished(let r): result = r
            }
        }
        print("LIVE purge job.run statuses=\(statuses)\nlines=\(lines)\nresult=\(String(describing: result))")
    }
}

extension LiveProbeTests {
    /// Forces Mole's paging (small terminal) and checks the driver walks the same rows as in the big terminal.
    func testPurgePagingMatchesBigTerminal() async throws {
        func rows(columns: Int, rows: Int) async throws -> [MenuEntry] {
            let s = try PTYLauncher().launch(["purge", "--dry-run"], environment: MenuSession.environment, columns: columns, rows: rows)
            defer { s.terminate() }
            let entries = try await MoleMenuDriver().readAllRows(in: s)
            MoleMenuDriver().quit(s)
            _ = try? await s.waitForExit(timeout: 10)
            return entries
        }
        let big = try await rows(columns: 240, rows: 60)
        let small = try await rows(columns: 120, rows: 24)
        print("LIVE purge paging: big=\(big.count) small=\(small.count) sameKeys=\(big.map(\.key) == small.map(\.key))")
        if big.map(\.key) != small.map(\.key) {
            for (i, (a, b)) in zip(big.map(\.key), small.map(\.key)).enumerated() where a != b { print("LIVE purge paging diff at \(i):\n  big:   \(a)\n  small: \(b)") }
        }
    }
}

extension LiveProbeTests {
    func testPurgeStaleFrameDebug() async throws {
        let s = try PTYLauncher().launch(["purge", "--dry-run"], environment: MenuSession.environment, columns: 120, rows: 24)
        defer { s.terminate() }
        var frame = try await s.waitForFrame(timeout: 120) { MenuFrame.parse($0)?.isComplete == true }
        for step in 1...14 {
            try s.send(TerminalKey.down)
            let want = step
            let immediate = try await s.waitForFrame(timeout: 10) { MenuFrame.parse($0)?.cursorIndex == want }
            let imm = MenuFrame.parse(immediate)
            try await Task.sleep(nanoseconds: 400_000_000)
            let settled = MenuFrame.parse(s.currentFrame())
            let same = imm?.cursorPath == settled?.cursorPath
            print("LIVE step \(step) idx=\(imm?.cursorIndex ?? -1) immPath=\(imm?.cursorPath ?? "-") settledPath=\(settled?.cursorPath ?? "-") consistent=\(same)")
            if !same { print("IMMEDIATE FRAME:\n\(immediate)\nSETTLED:\n\(s.currentFrame())") }
            frame = s.currentFrame()
        }
        _ = frame
        MoleMenuDriver().quit(s)
    }
}

extension LiveProbeTests {
    private func previewLive(_ title: String) async throws {
        let job = UninstallJob(runner: ProcessRunner(), launcher: PTYLauncher())
        let scan = try await job.scan()
        let item = try XCTUnwrap(scan.allItems.first { $0.title == title }, "no app \(title)")
        let t = Date()
        let files = try await job.previewLeftovers(for: item)
        print("LIVE previewLeftovers \(title) (\(Int(Date().timeIntervalSince(t)))s): \(files.count) leftovers")
        for f in files.prefix(40) { print("    \(f)") }
    }

    func testPreviewLeftoversSmall() async throws { try await previewLive("Flux") }
    func testPreviewLeftoversBig() async throws { try await previewLive("Microsoft Word") }
}

extension LiveProbeTests {
    /// UninstallJob.run against `mo uninstall --dry-run Flux`: y, confirm list check, Enter (dry run removes nothing), summary.
    func testUninstallRunDryRun() async throws {
        var job = UninstallJob(runner: ProcessRunner(), launcher: PTYLauncher())
        job.extraRunArguments = ["--dry-run"]
        let scan = try await job.scan()
        let flux = try XCTUnwrap(scan.allItems.first { $0.title == "Flux" })
        var lines: [String] = [], statuses: [String] = [], result: RunResult?
        for try await event in job.run(selection: [flux.id], from: scan) {
            switch event {
            case .line(let l): lines.append(l)
            case .status(let s): statuses.append(s)
            case .finished(let r): result = r
            }
        }
        print("LIVE uninstall dry-run statuses=\(statuses)\nlines=\(lines)\nresult=\(String(describing: result.map { ($0.itemCount as Any, $0.freedBytes as Any, $0.problems, $0.exitCode) }))")
    }
}

extension LiveProbeTests {
    /// Runs Mole's own `prompt_for_system_clean` (extracted from bin/clean.sh) in a PTY with the authentication
    /// functions replaced by stubs, so no `mo` run and no sudo is possible. Checks the prompt text Burrow
    /// looks for and that a single Space is understood as "skip".
    func testMolesSudoPromptUnderstandsSpaceAsSkip() async throws {
        let source = ProcessInfo.processInfo.environment["BURROW_MOLE_SRC"] ?? "/tmp/cmp/Mole"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source + "/bin/clean.sh"), "no Mole source at \(source)")
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = """
        #!/bin/bash
        set -euo pipefail
        export LC_ALL=C LANG=C
        source "\(source)/lib/core/common.sh"
        source "\(source)/lib/core/sudo.sh"
        ensure_sudo_session() { echo "STUB ensure_sudo_session CALLED"; return 1; }
        ensure_sudo_session_with_password() { echo "STUB ensure_sudo_session_with_password CALLED"; return 1; }
        SYSTEM_CLEAN=unset
        eval "$(awk '/^read_clean_sudo_choice\\(\\)/,/^CLEANUP_DONE=false/' "\(source)/bin/clean.sh" | sed '$d')"
        prompt_for_system_clean
        echo "RESULT SYSTEM_CLEAN=$SYSTEM_CLEAN"
        """
        let script = try writeExecutable(harness, in: dir, name: "harness.sh")
        let session = try PTYLauncher(executable: script).launch([], environment: ["NO_COLOR": "1"], columns: 120, rows: 40)
        defer { session.terminate() }
        var prompt: CleanPrompt?
        for _ in 0..<200 where prompt == nil {
            prompt = CleanPrompt.detect(inTail: session.transcript())
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("LIVE sudo prompt transcript: \(session.transcript().debugDescription)")
        XCTAssertEqual(prompt, .systemCaches)
        try session.send(TerminalKey.space)
        let code = try await session.waitForExit(timeout: 10)
        let transcript = session.transcript()
        print("LIVE sudo prompt after Space (exit \(code)): \(transcript.debugDescription)")
        XCTAssertTrue(transcript.contains("RESULT SYSTEM_CLEAN=false"))
        XCTAssertFalse(transcript.contains("STUB"))
    }
}

extension LiveProbeTests {
    func testInstallerPagingMatchesBigTerminal() async throws {
        func keys(columns: Int, rows: Int) async throws -> [String] {
            let s = try PTYLauncher().launch(["installer", "--dry-run"], environment: MenuSession.environment, columns: columns, rows: rows)
            defer { s.terminate() }
            let entries = try await MoleMenuDriver().readAllRows(in: s)
            MoleMenuDriver().quit(s)
            _ = try? await s.waitForExit(timeout: 10)
            return entries.map(\.key)
        }
        let big = try await keys(columns: 240, rows: 60)
        let small = try await keys(columns: 100, rows: 14)
        print("LIVE installer paging: big=\(big.count) small=\(small.count) same=\(big == small)")
        XCTAssertEqual(big, small)
    }
}
