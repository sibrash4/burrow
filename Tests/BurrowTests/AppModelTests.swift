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
        let state = model.state(.purge)
        XCTAssertEqual(state.phase, .failed)
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

    func testActionTitles() {
        XCTAssertEqual(JobKind.clean.actionTitle(bytes: 7_800_000_000, count: 3), "Clean 7.8 GB")
        XCTAssertEqual(JobKind.clean.actionTitle(bytes: 0, count: 3), "Clean 3 items")
        XCTAssertEqual(JobKind.uninstall.actionTitle(bytes: 5, count: 2), "Uninstall 2 apps")
        XCTAssertEqual(JobKind.uninstall.actionTitle(bytes: 5, count: 1), "Uninstall 1 app")
        XCTAssertEqual(JobKind.purge.actionTitle(bytes: 1_000_000, count: 1), "Purge 1 MB")
    }
}
