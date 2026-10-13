import Foundation
import XCTest
@testable import BurrowCore

final class AILeftoversWorktreeScannerTests: XCTestCase {
    var home: URL!

    override func setUp() async throws {
        home = try Fixture.makeHome()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func config(now: Date = .now) -> AILeftoversConfig {
        AILeftoversConfig(home: home, now: now, thresholdDays: 30)
    }

    /// Repo plus four worktrees: clean+merged, dirty, unmerged commit, and clean but recently touched.
    private func makeFixtureWorktrees() async throws -> (repo: URL, clean: URL, dirty: URL, unmerged: URL, recent: URL) {
        let repo = try await Fixture.makeRepo(home: home)
        let wts = home.appendingPathComponent("dev/wts", isDirectory: true)

        let clean = wts.appendingPathComponent("clean")
        try await Fixture.addWorktree(repo: repo, at: clean, branch: "clean-branch")

        let dirty = wts.appendingPathComponent("dirty")
        try await Fixture.addWorktree(repo: repo, at: dirty, branch: "dirty-branch")
        try Fixture.write("scratch\n", to: dirty.appendingPathComponent("scratch.txt"))

        let unmerged = wts.appendingPathComponent("unmerged")
        try await Fixture.addWorktree(repo: repo, at: unmerged, branch: "unmerged-branch")
        try await Fixture.commitIn(unmerged, file: "feature.txt")

        let recent = wts.appendingPathComponent("recent")
        try await Fixture.addWorktree(repo: repo, at: recent, branch: "recent-branch")

        // Everything except "recent" is 60 days old.
        for url in [clean, dirty, unmerged] {
            try Fixture.backdate(url, days: 60)
        }
        return (repo, clean, dirty, unmerged, recent)
    }

    func testMainRepoIsReadFromGitFile() async throws {
        let f = try await makeFixtureWorktrees()
        let main = WorktreeScanner.mainRepo(ofWorktree: f.clean.path)
        XCTAssertEqual(main, f.repo.path)
    }

    func testFindsOnlyLinkedWorktrees() async throws {
        let f = try await makeFixtureWorktrees()
        let found = WorktreeScanner(config: config(), shell: RoutingShell()).findWorktrees()
        XCTAssertEqual(Set(found), Set([f.clean.path, f.dirty.path, f.unmerged.path, f.recent.path]))
    }

    func testOnlyCleanMergedOldWorktreeIsSelected() async throws {
        _ = try await makeFixtureWorktrees()
        let scanner = WorktreeScanner(config: config(), shell: RoutingShell())
        let maybeGroup = await scanner.scanGroup(cwds: [])
        let group = try XCTUnwrap(maybeGroup)
        XCTAssertEqual(group.id, "agent-worktrees")

        let byName = Dictionary(uniqueKeysWithValues: group.items.map { ($0.id, $0) })
        let clean = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/clean") }?.value)
        let dirty = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/dirty") }?.value)
        let unmerged = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/unmerged") }?.value)
        let recent = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/recent") }?.value)

        XCTAssertEqual(clean.title, "Repo / clean")
        XCTAssertTrue(clean.selectable)
        // Clean and old, but never ticked by default: git-ignored data inside is not visible to the checks.
        XCTAssertFalse(clean.selectedByDefault)
        XCTAssertNil(clean.note)
        XCTAssertTrue(clean.detail?.contains("git-ignored files inside go to the Trash too") ?? false)

        XCTAssertFalse(dirty.selectable)
        XCTAssertFalse(dirty.selectedByDefault)
        XCTAssertEqual(dirty.note, "Has uncommitted changes")

        XCTAssertFalse(unmerged.selectable)
        XCTAssertFalse(unmerged.selectedByDefault)
        XCTAssertEqual(unmerged.note, "Commits not pushed or merged")

        XCTAssertFalse(recent.selectable)
        XCTAssertFalse(recent.selectedByDefault)
        XCTAssertEqual(recent.note, "Changed recently (within the age threshold)")

        XCTAssertEqual(group.items.filter(\.selectedByDefault), [])
    }

    func testUntrackedFilesCountAsDirtyEvenWhenGitHidesThem() async throws {
        let f = try await makeFixtureWorktrees()
        // A user config that hides untracked files from `git status`.
        try await Fixture.git(["config", "status.showUntrackedFiles", "no"], in: f.repo)
        try Fixture.write("notes\n", to: f.clean.appendingPathComponent("notes.txt"))

        let dirty = await WorktreeScanner(config: config(), shell: RoutingShell()).isDirty(f.clean.path)
        XCTAssertTrue(dirty)
    }

    func testWorktreeInUseThroughSymlinkedFolderIsDetected() async throws {
        // ~/dev is a symlink to a folder elsewhere (for example on an external drive). lsof reports the real path.
        let real = home.appendingPathComponent("vol/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("dev"), withDestinationURL: real)
        let repo = try await Fixture.makeRepo(home: home)
        let wt = home.appendingPathComponent("dev/wts/clean", isDirectory: true)
        try await Fixture.addWorktree(repo: repo, at: wt, branch: "clean-branch")
        try Fixture.backdate(wt, days: 60)

        let realWorktree = real.appendingPathComponent("wts/clean").path
        let shell = RoutingShell(lsofOutput: "p4242\nfcwd\nn\(realWorktree)/src\n")
        let cwds = try await LsofCwdProvider(shell: shell).currentWorkingDirectories()
        let maybeGroup = await WorktreeScanner(config: config(), shell: shell).scanGroup(cwds: cwds)
        let group = try XCTUnwrap(maybeGroup)
        let item = try XCTUnwrap(group.items.first { $0.id == realWorktree })
        XCTAssertFalse(item.selectable)
        XCTAssertEqual(item.note, "In use by a running process")
    }

    func testWorktreeInUseByProcessIsUnselectable() async throws {
        let f = try await makeFixtureWorktrees()
        let shell = RoutingShell(lsofOutput: "p4242\nfcwd\nn\(f.clean.path)/src\n")
        let maybeGroup = await WorktreeScanner(config: config(), shell: shell).scanGroup(cwds: [f.clean.path + "/src"])
        let group = try XCTUnwrap(maybeGroup)
        let clean = try XCTUnwrap(group.items.first { $0.id == f.clean.path })
        XCTAssertFalse(clean.selectable)
        XCTAssertFalse(clean.selectedByDefault)
        XCTAssertEqual(clean.note, "In use by a running process")
    }

    func testAgeThresholdIsRespected() async throws {
        let repo = try await Fixture.makeRepo(home: home)
        let wts = home.appendingPathComponent("dev/wts", isDirectory: true)
        let old = wts.appendingPathComponent("old")
        let young = wts.appendingPathComponent("young")
        try await Fixture.addWorktree(repo: repo, at: old, branch: "old-branch")
        try await Fixture.addWorktree(repo: repo, at: young, branch: "young-branch")
        try Fixture.backdate(old, days: 31)
        try Fixture.backdate(young, days: 29)

        let maybeGroup = await WorktreeScanner(config: config(), shell: RoutingShell()).scanGroup(cwds: [])
        let group = try XCTUnwrap(maybeGroup)
        let oldItem = try XCTUnwrap(group.items.first { $0.id == old.path })
        let youngItem = try XCTUnwrap(group.items.first { $0.id == young.path })
        XCTAssertTrue(oldItem.selectable)
        XCTAssertFalse(oldItem.selectedByDefault)
        XCTAssertFalse(youngItem.selectable)
        XCTAssertFalse(youngItem.selectedByDefault)
    }

    func testNoWorktreesMeansNoGroup() async throws {
        _ = try await Fixture.makeRepo(home: home)
        let group = await WorktreeScanner(config: config(), shell: RoutingShell()).scanGroup(cwds: [])
        XCTAssertNil(group)
    }
}
