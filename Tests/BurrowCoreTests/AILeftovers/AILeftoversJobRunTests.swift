import Foundation
import XCTest
@testable import BurrowCore

/// Returns scripted answers for each call, repeating the last one. A nil answer means lsof failed.
final class ScriptedCwds: ProcessCwdProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]?]

    init(_ answers: [[String]?]) {
        self.answers = answers
    }

    func currentWorkingDirectories() async throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        guard let answer else { throw FixtureError.git("lsof", "unavailable") }
        return answer
    }
}

final class AILeftoversJobRunTests: XCTestCase {
    var home: URL!
    var trashDir: URL!

    override func setUp() async throws {
        home = try Fixture.makeHome()
        trashDir = home.deletingLastPathComponent().appendingPathComponent("trash-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: trashDir)
    }

    private var config: AILeftoversConfig {
        AILeftoversConfig(home: home, now: .now, thresholdDays: 30)
    }

    private func makeJob(cwds: ScriptedCwds, trasher: FakeTrasher) -> AILeftoversJob {
        AILeftoversJob(
            config: config,
            shell: RoutingShell(),
            cwds: cwds,
            trasher: trasher,
            worktrees: GitWorktreeRemover(shell: RoutingShell())
        )
    }

    /// Repo with a clean, old worktree plus one old Claude transcript and one recent transcript.
    private func makeScenario() async throws -> (repo: URL, worktree: URL, transcript: URL, recent: URL) {
        let repo = try await Fixture.makeRepo(home: home)
        let wt = home.appendingPathComponent("dev/wts/clean", isDirectory: true)
        try await Fixture.addWorktree(repo: repo, at: wt, branch: "clean-branch")
        try Fixture.backdate(wt, days: 60)

        let project = home.appendingPathComponent(".claude/projects/\(home.path.replacingOccurrences(of: "/", with: "-"))-dev-Foo", isDirectory: true)
        let transcript = project.appendingPathComponent("old.jsonl")
        try Fixture.write("{}\n", to: transcript)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: transcript.path)
        let recent = project.appendingPathComponent("new.jsonl")
        try Fixture.write("{}\n", to: recent)
        return (repo, wt, transcript, recent)
    }

    private func collect(_ job: AILeftoversJob, selection: Set<ScanItem.ID>, scan: ScanResult) async throws -> (RunResult?, [String]) {
        var result: RunResult?
        var lines: [String] = []
        for try await event in job.run(selection: selection, from: scan) {
            switch event {
            case .line(let text): lines.append(text)
            case .status: break
            case .finished(let r): result = r
            }
        }
        return (result, lines)
    }

    func testRunRemovesWorktreeWithGitAndTrashesTranscripts() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let transcriptItem = try XCTUnwrap(scan.allItems.first { $0.id.hasPrefix("claude-transcripts:") })
        XCTAssertFalse(transcriptItem.selectedByDefault)

        var selection = scan.defaultSelection
        selection.insert(transcriptItem.id)
        let (result, lines) = try await collect(job, selection: selection, scan: scan)

        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.problems, [])
        XCTAssertEqual(run.itemCount, 2)
        XCTAssertGreaterThan(run.freedBytes ?? 0, 0)
        XCTAssertFalse(lines.isEmpty)

        // Worktree gone, and git no longer lists it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.worktree.path))
        let list = try await Fixture.git(["worktree", "list", "--porcelain"], in: s.repo)
        XCTAssertFalse(list.contains(s.worktree.path))

        // Old transcript moved to the (fake) Trash; the recent one untouched.
        XCTAssertEqual(trasher.trashed, [transcriptItem.paths[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptItem.paths[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.recent.path))
    }

    func testWorktreeDirtiedAfterScanIsSkipped() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        XCTAssertTrue(wtItem.selectedByDefault)

        // The user (or another process) edits the worktree between scan and run.
        try Fixture.write("new work\n", to: s.worktree.appendingPathComponent("unsaved.txt"))

        let (result, _) = try await collect(job, selection: [wtItem.id], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertEqual(run.problems.count, 1)
        XCTAssertTrue(run.problems[0].contains("Has uncommitted changes"), run.problems[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktree.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktree.appendingPathComponent("unsaved.txt").path))
        XCTAssertEqual(trasher.trashed, [])
    }

    func testWorktreeInUseAtRunTimeIsSkipped() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        // Nothing running at scan time; a shell opened inside the worktree before the run.
        let job = makeJob(cwds: ScriptedCwds([[], [s.worktree.path]]), trasher: trasher)

        let scan = try await job.scan()
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        let (result, _) = try await collect(job, selection: [wtItem.id], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertTrue(run.problems.first?.contains("In use") ?? false, run.problems.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktree.path))
    }

    func testUnticketedItemsAreKept() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let (result, _) = try await collect(job, selection: [], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertEqual(run.problems, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktree.path))
        XCTAssertEqual(trasher.trashed, [])
    }

    func testUnselectableItemInSelectionIsNotRemoved() async throws {
        let repo = try await Fixture.makeRepo(home: home)
        let wt = home.appendingPathComponent("dev/wts/fresh", isDirectory: true)
        try await Fixture.addWorktree(repo: repo, at: wt, branch: "fresh-branch")
        // Not backdated: recent, so unselectable.
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let item = try XCTUnwrap(scan.allItems.first { $0.id == wt.path })
        XCTAssertFalse(item.selectable)
        let (result, _) = try await collect(job, selection: [item.id], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertEqual(run.problems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
    }

    func testUnknownSelectionIdIsReported() async throws {
        _ = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)
        let scan = try await job.scan()
        let (result, _) = try await collect(job, selection: ["/nowhere/at/all"], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertTrue(run.problems.contains { $0.contains("Unknown item") })
    }

    func testUnreadableProcessListMakesEverythingUnselectable() async throws {
        _ = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([nil]), trasher: trasher)

        let scan = try await job.scan()
        XCTAssertFalse(scan.allItems.isEmpty)
        XCTAssertTrue(scan.allItems.allSatisfy { !$0.selectable && !$0.selectedByDefault })
        XCTAssertEqual(scan.defaultSelection, [])
    }

    func testFailedRunPathIsReportedNotThrown() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        // Remove the worktree dir by hand after the scan: git must refuse, and nothing else may break.
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)
        let scan = try await job.scan()
        try FileManager.default.moveItem(at: s.worktree, to: home.appendingPathComponent("moved-away"))
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        let (result, _) = try await collect(job, selection: [wtItem.id], scan: scan)
        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertFalse(run.problems.isEmpty)
    }
}
