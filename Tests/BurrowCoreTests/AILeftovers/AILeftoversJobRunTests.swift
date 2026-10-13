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

/// Trashes through `inner`, then cancels the task it runs in, as pressing Stop mid-run would.
final class CancelAfterFirstTrash: Trashing, @unchecked Sendable {
    let inner: FakeTrasher

    init(inner: FakeTrasher) {
        self.inner = inner
    }

    func trash(_ url: URL) throws -> URL? {
        let moved = try inner.trash(url)
        withUnsafeCurrentTask { $0?.cancel() }
        return moved
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

    private func makeJob(cwds: ScriptedCwds, trasher: Trashing) -> AILeftoversJob {
        AILeftoversJob(
            config: config,
            shell: RoutingShell(),
            cwds: cwds,
            trasher: trasher,
            worktrees: GitWorktreePruner(shell: RoutingShell())
        )
    }

    /// Repo with a clean, old worktree plus one old Claude transcript and one recent transcript.
    /// The recent one is two days old: not offered, but outside the 24-hour "may be open" window.
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
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: recent.path)
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
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        XCTAssertFalse(wtItem.selectedByDefault)

        var selection = scan.defaultSelection
        selection.insert(transcriptItem.id)
        selection.insert(wtItem.id)
        let (result, lines) = try await collect(job, selection: selection, scan: scan)

        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.problems, [])
        XCTAssertEqual(run.itemCount, 2)
        XCTAssertGreaterThan(run.freedBytes ?? 0, 0)
        XCTAssertFalse(lines.isEmpty)

        // Worktree folder moved to the Trash, and git no longer lists it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.worktree.path))
        let list = try await Fixture.git(["worktree", "list", "--porcelain"], in: s.repo)
        XCTAssertFalse(list.contains(s.worktree.path))

        // Worktree first (scan order), then the old transcript to the (fake) Trash; the recent one untouched.
        XCTAssertEqual(trasher.trashed, [s.worktree.path, transcriptItem.paths[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptItem.paths[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.recent.path))
    }

    func testWorktreeDirtiedAfterScanIsSkipped() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        XCTAssertTrue(wtItem.selectable)

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

    func testWorktreeGoesToTrashWithItsIgnoredFiles() async throws {
        let s = try await makeScenario()
        // Git-ignored data that `git status` never reports, as in a real agent worktree.
        try Fixture.write(".env\n", to: s.repo.appendingPathComponent(".git/info/exclude"))
        try Fixture.write("SECRET=1\n", to: s.worktree.appendingPathComponent(".env"))
        try Fixture.backdate(s.worktree, days: 60)
        let trasher = FakeTrasher(folder: trashDir)
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)

        let scan = try await job.scan()
        let wtItem = try XCTUnwrap(scan.allItems.first { $0.id == s.worktree.path })
        XCTAssertTrue(wtItem.selectable)
        let (result, _) = try await collect(job, selection: [wtItem.id], scan: scan)

        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.problems, [])
        XCTAssertEqual(run.itemCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.worktree.path))
        // The ignored file survives in the Trash, not deleted by git.
        XCTAssertEqual(try String(contentsOf: trashDir.appendingPathComponent("0-clean/.env"), encoding: .utf8), "SECRET=1\n")
        let list = try await Fixture.git(["worktree", "list", "--porcelain"], in: s.repo)
        XCTAssertFalse(list.contains(s.worktree.path))
    }

    func testOpenClaudeProjectIsSkippedAtRunTime() async throws {
        let s = try await makeScenario()
        let trasher = FakeTrasher(folder: trashDir)
        // Nothing open at scan time; a session starts inside the project folder before the run.
        let projectCwd = home.appendingPathComponent("dev/Foo/src").path
        let job = makeJob(cwds: ScriptedCwds([[], [projectCwd]]), trasher: trasher)

        let scan = try await job.scan()
        let transcriptItem = try XCTUnwrap(scan.allItems.first { $0.id.hasPrefix("claude-transcripts:") })
        XCTAssertTrue(transcriptItem.selectable)
        let (result, _) = try await collect(job, selection: [transcriptItem.id], scan: scan)

        let run = try XCTUnwrap(result)
        XCTAssertEqual(run.itemCount, 0)
        XCTAssertTrue(run.problems.first?.contains("In use by a running process") ?? false, run.problems.description)
        XCTAssertEqual(trasher.trashed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.transcript.path))
    }

    func testCancelledRunReturnsWhatWasAlreadyMoved() async throws {
        // Two old, default-ticked rows: Claude file history and shell snapshots.
        let session = home.appendingPathComponent(".claude/file-history/session-1", isDirectory: true)
        try Fixture.write("old\n", to: session.appendingPathComponent("v1.txt"))
        try Fixture.backdate(session, days: 60)
        let snapshot = home.appendingPathComponent(".claude/shell-snapshots/snap-1.sh")
        try Fixture.write("export X=1\n", to: snapshot)
        try Fixture.backdate(snapshot, days: 60)

        let trasher = CancelAfterFirstTrash(inner: FakeTrasher(folder: trashDir))
        let job = makeJob(cwds: ScriptedCwds([[]]), trasher: trasher)
        let scan = try await job.scan()
        let selection = scan.defaultSelection
        XCTAssertEqual(selection.count, 2)

        // Runs in its own task so the cancel hits only this run.
        let execution = Task { try await job.execute(selection: selection, scan: scan, emit: { _ in }) }
        let run = try await execution.value

        XCTAssertEqual(trasher.inner.trashed.count, 1)
        XCTAssertEqual(run.itemCount, 1)
        XCTAssertGreaterThan(run.freedBytes ?? 0, 0)
        XCTAssertTrue(run.problems.contains { $0.hasPrefix("Stopped by you after 1 items") }, run.problems.description)
    }
}
