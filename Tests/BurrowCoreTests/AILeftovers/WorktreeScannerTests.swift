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

        let byName = Dictionary(uniqueKeysWithValues: group.items.map { ($0.detail ?? "", $0) })
        let clean = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/clean") }?.value)
        let dirty = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/dirty") }?.value)
        let unmerged = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/unmerged") }?.value)
        let recent = try XCTUnwrap(byName.first { $0.key.hasSuffix("/wts/recent") }?.value)

        XCTAssertEqual(clean.title, "Repo / clean")
        XCTAssertTrue(clean.selectable)
        XCTAssertTrue(clean.selectedByDefault)
        XCTAssertNil(clean.note)

        XCTAssertFalse(dirty.selectable)
        XCTAssertFalse(dirty.selectedByDefault)
        XCTAssertEqual(dirty.note, "Has uncommitted changes")

        XCTAssertFalse(unmerged.selectable)
        XCTAssertFalse(unmerged.selectedByDefault)
        XCTAssertEqual(unmerged.note, "Commits not pushed or merged")

        XCTAssertFalse(recent.selectable)
        XCTAssertFalse(recent.selectedByDefault)
        XCTAssertEqual(recent.note, "Changed recently (within the age threshold)")

        XCTAssertEqual(group.items.filter(\.selectedByDefault).map(\.id), [clean.id])
    }

    func testWorktreeInUseByProcessIsUnselectable() async throws {
        let f = try await makeFixtureWorktrees()
        let shell = RoutingShell(lsofOutput: "p4242\nfcwd\nn\(f.clean.path)/src\n")
        let maybeGroup = await WorktreeScanner(config: config(), shell: shell).scanGroup(cwds: [f.clean.path + "/src"])
        let group = try XCTUnwrap(maybeGroup)
        let clean = try XCTUnwrap(group.items.first { $0.detail == f.clean.path })
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
        let oldItem = try XCTUnwrap(group.items.first { $0.detail == old.path })
        let youngItem = try XCTUnwrap(group.items.first { $0.detail == young.path })
        XCTAssertTrue(oldItem.selectedByDefault)
        XCTAssertFalse(youngItem.selectable)
        XCTAssertFalse(youngItem.selectedByDefault)
    }

    func testNoWorktreesMeansNoGroup() async throws {
        _ = try await Fixture.makeRepo(home: home)
        let group = await WorktreeScanner(config: config(), shell: RoutingShell()).scanGroup(cwds: [])
        XCTAssertNil(group)
    }
}
