import XCTest
import BurrowCore
@testable import Burrow

struct FailingJob: MoleJob {
    var kind: JobKind
    var error: BurrowError
    func scan() async throws -> ScanResult { throw error }
    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

/// Behaves like an engine that is stopped: `run` registers the run, the stream ends at once when stopped,
/// and the engine then takes `teardown` longer to put things back before it settles the run.
struct TeardownJob: MoleJob {
    var kind: JobKind
    var teardown: Duration
    func scan() async throws -> ScanResult {
        ScanResult(kind: kind, groups: [ScanGroup(id: "g", title: "Group", items: [ScanItem(id: "a", title: "Item", bytes: 1_000)])])
    }
    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        RunTeardown.shared.begin(kind)
        let kind = kind, teardown = teardown
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { RunTeardown.shared.end(kind, result: RunResult(freedBytes: 3_000_000_000, itemCount: 4, exitCode: -1, log: "")) }
                _ = try? await Task.sleep(for: .seconds(30))
                await Task.detached { try? await Task.sleep(for: teardown) }.value
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Emits `count` log lines and finishes with `result`.
struct ScriptedJob: MoleJob {
    var kind: JobKind
    var count = 0
    var result: RunResult?
    func scan() async throws -> ScanResult {
        ScanResult(kind: kind, groups: [ScanGroup(id: "g", title: "Group", items: [ScanItem(id: "a", title: "Item", bytes: 1_000)])])
    }
    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            for n in 0..<count { continuation.yield(.line("line \(n)")) }
            if let result { continuation.yield(.finished(result)) }
            continuation.finish()
        }
    }
}

struct SaveFailed: LocalizedError {
    var errorDescription: String? { "the whitelist is busy" }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(step: Duration = .milliseconds(1), recorder: Recorder = Recorder()) -> AppModel {
        var jobs: [JobKind: MoleJob] = [:]
        for kind in JobKind.allCases { jobs[kind] = MockJob(kind: kind, scanDelay: .zero, stepDelay: step) }
        return AppModel(jobs: jobs, alwaysKeep: { recorder.add($0.id) })
    }

    private func until(_ model: AppModel, _ kind: JobKind, _ phase: Phase, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if model.state(kind).phase == phase { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never reached \(phase), stuck at \(model.state(kind).phase)", file: file, line: line)
    }

    func testScanSelectsDefaultsAndSumsBytes() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        let expected = MockData.clean.allItems.filter { $0.selectable && $0.selectedByDefault }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        XCTAssertEqual(model.selectedBytes(.clean), expected)
        XCTAssertGreaterThan(model.totalBytes(.clean), model.selectedBytes(.clean) - 1)
    }

    func testUninstallStartsWithNothingSelected() async {
        let model = makeModel()
        model.scan(.uninstall)
        await until(model, .uninstall, .review)
        XCTAssertEqual(model.selectedCount(.uninstall), 0)
        XCTAssertNil(model.sidebarSize(.uninstall))
        model.toggle("com.numi.app", in: .uninstall)
        XCTAssertEqual(model.selectedCount(.uninstall), 1)
        XCTAssertEqual(model.sidebarSize(.uninstall), ByteSize.format(47_000_000))
    }

    func testUntickingShrinksGroupAndTotal() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        let before = model.selectedBytes(.clean)
        let group = MockData.clean.groups.first { $0.id == "browsers" }!
        model.setSelected(group.items.map(\.id), false, in: .clean)
        XCTAssertEqual(model.selectedBytes(of: group, in: .clean), 0)
        XCTAssertEqual(model.selectedBytes(.clean), before - 1_682_200_000)
    }

    func testUnselectableRowsCannotBeTicked() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        model.toggle("system-caches", in: .clean)
        XCTAssertFalse(model.isSelected("system-caches", in: .clean))
    }

    func testConfirmCancelReturnsToReview() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        model.beginConfirm(.clean)
        XCTAssertEqual(model.state(.clean).phase, .confirming)
        model.cancelConfirm(.clean)
        XCTAssertEqual(model.state(.clean).phase, .review)
    }

    func testCannotConfirmWithNothingSelected() async {
        let model = makeModel()
        model.scan(.uninstall)
        await until(model, .uninstall, .review)
        model.beginConfirm(.uninstall)
        XCTAssertEqual(model.state(.uninstall).phase, .review)
    }

    func testRunFinishesWithFreedBytesAndLog() async {
        let model = makeModel()
        model.scan(.installers)
        await until(model, .installers, .review)
        model.setSelected(["i1", "i2"], true, in: .installers)
        model.beginConfirm(.installers)
        model.confirmRun(.installers)
        await until(model, .installers, .done)
        let state = model.state(.installers)
        XCTAssertEqual(state.result?.freedBytes, 72_000_000 + 60_800_000)
        XCTAssertEqual(state.log.count, 2)
    }

    func testCancelRunEndsInStoppedFailure() async {
        let model = makeModel(step: .seconds(5))
        model.scan(.purge)
        await until(model, .purge, .review)
        model.beginConfirm(.purge)
        model.confirmRun(.purge)
        XCTAssertEqual(model.state(.purge).phase, .running)
        model.cancelRun(.purge)
        XCTAssertEqual(model.state(.purge).phase, .stopping)
        await until(model, .purge, .failed)
        let state = model.state(.purge)
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.errorText, "Cancelled.")
    }

    func testScanFailureShowsErrorDescription() async {
        let model = AppModel(jobs: [.clean: FailingJob(kind: .clean, error: .timeout("mo clean"))])
        model.scan(.clean)
        await until(model, .clean, .failed)
        XCTAssertEqual(model.state(.clean).errorText, BurrowError.timeout("mo clean").errorDescription)
        XCTAssertEqual(model.moleStatus, .ready)
    }

    func testMoleNotFoundFlipsStatus() async {
        let model = AppModel(jobs: [.clean: FailingJob(kind: .clean, error: .moleNotFound)])
        model.scan(.clean)
        await until(model, .clean, .failed)
        XCTAssertEqual(model.moleStatus, .missing)
    }

    func testAlwaysKeepUntickssAndCallsHandler() async {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.scan(.clean)
        await until(model, .clean, .review)
        let item = MockData.clean.allItems.first { $0.id == "clang" }!
        XCTAssertTrue(model.isSelected("clang", in: .clean))
        model.alwaysKeep(item, in: .clean)
        XCTAssertFalse(model.isSelected("clang", in: .clean))
        for _ in 0..<100 where recorder.all.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.all, ["clang"])
    }

    func testRescanKeepsNothingFromOldSelection() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        model.selectNone(.clean)
        model.scan(.clean)
        await until(model, .clean, .review)
        XCTAssertGreaterThan(model.selectedCount(.clean), 0)
    }

    // MARK: Stop, scan and quit

    func testStopShowsStoppingUntilTeardownAndKeepsWhatWasFreed() async {
        var jobs: [JobKind: MoleJob] = [:]
        jobs[.purge] = TeardownJob(kind: .purge, teardown: .milliseconds(300))
        let model = AppModel(jobs: jobs)
        model.scan(.purge)
        await until(model, .purge, .review)
        model.setSelected(["a"], true, in: .purge)
        model.beginConfirm(.purge)
        model.confirmRun(.purge)
        model.cancelRun(.purge)
        XCTAssertEqual(model.state(.purge).phase, .stopping)
        // A new scan must wait until the stopped run has torn down.
        model.scan(.purge)
        XCTAssertEqual(model.state(.purge).phase, .stopping)
        await until(model, .purge, .failed)
        let state = model.state(.purge)
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.result?.freedBytes, 3_000_000_000)
        XCTAssertFalse(RunTeardown.shared.isActive(.purge))
    }

    func testQuitWaitsForTheRunToTearDown() async {
        var jobs: [JobKind: MoleJob] = [:]
        jobs[.purge] = TeardownJob(kind: .purge, teardown: .milliseconds(300))
        let model = AppModel(jobs: jobs)
        model.scan(.purge)
        await until(model, .purge, .review)
        model.setSelected(["a"], true, in: .purge)
        model.beginConfirm(.purge)
        model.confirmRun(.purge)
        XCTAssertTrue(model.hasActiveRun)
        await model.stopAllAndWait()
        XCTAssertFalse(RunTeardown.shared.isActive(.purge))
        XCTAssertFalse(model.hasActiveRun)
    }

    func testScanCanBeCancelled() async {
        let model = AppModel(jobs: [.clean: MockJob(kind: .clean, scanDelay: .seconds(5))])
        model.scan(.clean)
        XCTAssertEqual(model.state(.clean).phase, .scanning)
        model.cancelScan(.clean)
        let state = model.state(.clean)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(state.errorText, BurrowError.cancelled.errorDescription)
    }

    func testScanGivesUpAfterTheTimeout() async {
        let model = AppModel(jobs: [.clean: MockJob(kind: .clean, scanDelay: .seconds(5))], scanTimeout: .milliseconds(100))
        model.scan(.clean)
        await until(model, .clean, .failed)
        XCTAssertEqual(model.state(.clean).errorText, BurrowError.timeout("mo clean --dry-run").errorDescription)
        XCTAssertFalse(model.state(.clean).wasCancelled)
    }

    func testScanIsIgnoredWhileTheConfirmSheetIsUp() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        model.beginConfirm(.clean)
        let before = model.state(.clean).selection
        model.scan(.clean)
        XCTAssertEqual(model.state(.clean).phase, .confirming)
        XCTAssertEqual(model.state(.clean).selection, before)
    }

    func testFailedRunKeepsWhatMoleReported() async {
        let freed = RunResult(freedBytes: 4_000_000_000, exitCode: 1, log: "Mole exited")
        let model = AppModel(jobs: [.purge: ScriptedJob(kind: .purge, result: freed)])
        model.scan(.purge)
        await until(model, .purge, .review)
        model.setSelected(["a"], true, in: .purge)
        model.beginConfirm(.purge)
        model.confirmRun(.purge)
        await until(model, .purge, .failed)
        XCTAssertEqual(model.state(.purge).result?.freedBytes, 4_000_000_000)
        XCTAssertFalse(model.state(.purge).wasCancelled)
    }

    func testLogRevisionKeepsCountingPastTheCap() async {
        let model = AppModel(jobs: [.purge: ScriptedJob(kind: .purge, count: 2_100, result: RunResult(exitCode: 0, log: ""))])
        model.scan(.purge)
        await until(model, .purge, .review)
        model.setSelected(["a"], true, in: .purge)
        model.beginConfirm(.purge)
        model.confirmRun(.purge)
        await until(model, .purge, .done)
        XCTAssertEqual(model.state(.purge).log.count, 2_000)
        XCTAssertEqual(model.state(.purge).logRevision, 2_100)
    }

    /// The failed screen shows the stored result. A scan that fails or is cancelled after an earlier run must not
    /// repeat that run's freed bytes as if they belonged to this failure.
    func testFailedOrCancelledScanDoesNotRepeatAnEarlierRunsResult() async {
        let earlier = JobState(phase: .done, result: RunResult(freedBytes: 4_000_000_000, itemCount: 9, exitCode: 0, log: ""))

        let failing = AppModel(jobs: [.purge: FailingJob(kind: .purge, error: BurrowError.timeout("mo purge --dry-run"))])
        failing.preload(.purge, earlier)
        failing.scan(.purge)
        await until(failing, .purge, .failed)
        XCTAssertNil(failing.state(.purge).result)

        let cancelled = AppModel(jobs: [.purge: MockJob(kind: .purge, scanDelay: .seconds(5))])
        cancelled.preload(.purge, earlier)
        cancelled.scan(.purge)
        cancelled.cancelScan(.purge)
        XCTAssertEqual(cancelled.state(.purge).phase, .failed)
        XCTAssertNil(cancelled.state(.purge).result)
    }

    /// A stop whose teardown outlived the UI's wait must still block a new scan: the whitelist may not be back yet.
    func testScanIsRefusedWhileAStoppedRunIsStillTearingDown() async {
        let model = AppModel(jobs: [.purge: MockJob(kind: .purge, scanDelay: .zero)])
        RunTeardown.shared.begin(.purge)
        defer { RunTeardown.shared.end(.purge) }
        model.scan(.purge)
        XCTAssertEqual(model.state(.purge).phase, .failed)
        XCTAssertNil(model.state(.purge).scan)
        XCTAssertTrue(model.state(.purge).errorText?.contains("still stopping") == true)
    }

    // MARK: Selection and always keep

    func testSelectAllWithinVisibleRowsOnly() async {
        let model = makeModel()
        model.scan(.clean)
        await until(model, .clean, .review)
        model.selectNone(.clean)
        model.selectAll(.clean, within: ["clang", "brew"])
        XCTAssertTrue(model.isSelected("clang", in: .clean))
        XCTAssertTrue(model.isSelected("brew", in: .clean))
        XCTAssertFalse(model.isSelected("xcode-dd", in: .clean))
        model.selectNone(.clean, within: ["clang"])
        XCTAssertFalse(model.isSelected("clang", in: .clean))
        XCTAssertTrue(model.isSelected("brew", in: .clean))
    }

    func testFailedAlwaysKeepLeavesTheRowTickedAndSaysWhy() async {
        let model = AppModel(jobs: [.clean: MockJob(kind: .clean, scanDelay: .zero)], alwaysKeep: { _ in throw SaveFailed() })
        model.scan(.clean)
        await until(model, .clean, .review)
        let item = MockData.clean.allItems.first { $0.id == "clang" }!
        model.alwaysKeep(item, in: .clean)
        XCTAssertTrue(model.isSelected("clang", in: .clean))
        let notice = model.state(.clean).keepError ?? ""
        XCTAssertTrue(notice.contains("Clang module cache"))
        XCTAssertTrue(notice.contains("the whitelist is busy"))
    }

    func testSuccessfulAlwaysKeepClearsTheError() async {
        let model = AppModel(jobs: [.clean: MockJob(kind: .clean, scanDelay: .zero)], alwaysKeep: { _ in throw SaveFailed() })
        model.scan(.clean)
        await until(model, .clean, .review)
        let item = MockData.clean.allItems.first { $0.id == "clang" }!
        model.alwaysKeep(item, in: .clean)
        XCTAssertNotNil(model.state(.clean).keepError)
        let saved = AppModel(jobs: [.clean: MockJob(kind: .clean, scanDelay: .zero)], alwaysKeep: { _ in })
        saved.scan(.clean)
        await until(saved, .clean, .review)
        saved.alwaysKeep(item, in: .clean)
        XCTAssertNil(saved.state(.clean).keepError)
        XCTAssertFalse(saved.isSelected("clang", in: .clean))
    }

    // MARK: Launch and copy

    func testMoleCheckRunsAfterLaunchNotBeforeIt() async {
        let model = AppModel(jobs: [:], moleStatus: .checking, locateMole: { .ready })
        XCTAssertEqual(model.moleStatus, .checking)
        await model.checkMole()
        XCTAssertEqual(model.moleStatus, .ready)
    }

    func testConfirmCopySaysWhatReallyHappens() {
        XCTAssertEqual(JobKind.clean.consequence(), "Caches and logs are deleted.")
        XCTAssertEqual(JobKind.clean.consequence(trashIncluded: true), "Caches and logs are deleted. The Trash is emptied permanently.")
        XCTAssertEqual(JobKind.uninstall.consequence(), "Apps go to the Trash. Running apps are quit first.")
        XCTAssertTrue(JobKind.aiLeftovers.consequence().hasPrefix("Ticked worktrees, transcripts and model caches go to the Trash."))
    }

    func testActionTitles() {
        XCTAssertEqual(JobKind.clean.actionTitle(bytes: 7_800_000_000, count: 3), "Clean 7.8 GB")
        XCTAssertEqual(JobKind.clean.actionTitle(bytes: 0, count: 3), "Clean 3 items")
        XCTAssertEqual(JobKind.uninstall.actionTitle(bytes: 5, count: 2), "Uninstall 2 apps")
        XCTAssertEqual(JobKind.uninstall.actionTitle(bytes: 5, count: 1), "Uninstall 1 app")
        XCTAssertEqual(JobKind.purge.actionTitle(bytes: 1_000_000, count: 1), "Purge 1 MB")
    }
}
