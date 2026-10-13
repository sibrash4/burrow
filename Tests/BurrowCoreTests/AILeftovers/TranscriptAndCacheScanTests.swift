import Foundation
import XCTest
@testable import BurrowCore

final class AILeftoversScanTests: XCTestCase {
    var home: URL!

    override func setUp() async throws {
        home = try Fixture.makeHome()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var config: AILeftoversConfig {
        AILeftoversConfig(home: home, now: .now, thresholdDays: 30)
    }

    private var gate: SafetyGate {
        SafetyGate(config: config, cwds: [])
    }

    /// Project folder name as Claude Code encodes it for a path under the test home.
    private func encodedProject(_ suffix: String) -> String {
        home.path.replacingOccurrences(of: "/", with: "-") + "-" + suffix
    }

    func testClaudeTranscriptsAreGroupedPerProjectAndUnticked() throws {
        let project = home.appendingPathComponent(".claude/projects/\(encodedProject("dev-Foo"))", isDirectory: true)
        let oldFile = project.appendingPathComponent("aaaa.jsonl")
        let newFile = project.appendingPathComponent("bbbb.jsonl")
        try Fixture.write("{}\n", to: oldFile)
        try Fixture.write("{}\n", to: newFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: oldFile.path)
        // Two days old: not offered, and outside the 24-hour window that keeps a whole folder in use.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: newFile.path)

        // A second project with only recent transcripts should produce no row.
        let other = home.appendingPathComponent(".claude/projects/\(encodedProject("dev-Bar"))", isDirectory: true)
        try Fixture.write("{}\n", to: other.appendingPathComponent("cccc.jsonl"))

        let group = try XCTUnwrap(ClaudeScanner.scanGroup(config: config, gate: gate))
        XCTAssertEqual(group.items.count, 1)
        let item = group.items[0]
        XCTAssertEqual(item.title, "Transcripts: ~/dev/Foo")
        XCTAssertEqual(item.paths, [oldFile.path])
        XCTAssertEqual(item.count, 1)
        XCTAssertFalse(item.selectedByDefault)
        XCTAssertTrue(item.selectable)
        XCTAssertEqual(item.note, "Needed for claude --resume")
    }

    func testOpenSessionKeepsItsProjectFolderUnselectable() throws {
        let project = home.appendingPathComponent(".claude/projects/\(encodedProject("dev-Foo"))", isDirectory: true)
        let oldFile = project.appendingPathComponent("aaaa.jsonl")
        try Fixture.write("{}\n", to: oldFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: oldFile.path)

        // A shell open in a subfolder of the project, on a transcript that has not been written to for 60 days.
        let openCwd = home.appendingPathComponent("dev/Foo/src").path
        let gate = SafetyGate(config: config, cwds: [openCwd])
        let item = try XCTUnwrap(ClaudeScanner.scanGroup(config: config, gate: gate)?.items.first)
        XCTAssertFalse(item.selectable)
        XCTAssertFalse(item.selectedByDefault)
        XCTAssertEqual(item.note, "In use by a running process")
        XCTAssertEqual(item.paths, [oldFile.path])
    }

    func testNonAsciiFolderNameIsEncodedLikeClaudeDoes() throws {
        // Claude turns every non-ASCII-alphanumeric character into "-", so "Café" is stored as "Caf-".
        XCTAssertEqual(ClaudeScanner.encodedKey("/Users/x/dev/Café"), "-Users-x-dev-Caf-")
        let project = home.appendingPathComponent(".claude/projects/-Users-x-dev-Caf-", isDirectory: true)
        let oldFile = project.appendingPathComponent("aaaa.jsonl")
        try Fixture.write("{}\n", to: oldFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: oldFile.path)
        let gate = SafetyGate(config: config, cwds: ["/Users/x/dev/Café/src"])
        let item = try XCTUnwrap(ClaudeScanner.scanGroup(config: config, gate: gate)?.items.first)
        XCTAssertFalse(item.selectable)
        XCTAssertEqual(item.note, "In use by a running process")
    }

    func testTranscriptWrittenInLastDayKeepsProjectFolderUnselectable() throws {
        let project = home.appendingPathComponent(".claude/projects/\(encodedProject("dev-Foo"))", isDirectory: true)
        let oldFile = project.appendingPathComponent("aaaa.jsonl")
        let todayFile = project.appendingPathComponent("bbbb.jsonl")
        try Fixture.write("{}\n", to: oldFile)
        try Fixture.write("{}\n", to: todayFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: oldFile.path)

        let item = try XCTUnwrap(ClaudeScanner.scanGroup(config: config, gate: gate)?.items.first)
        XCTAssertFalse(item.selectable)
        XCTAssertEqual(item.note, "Changed in the last 24 hours, so it may be open")
    }

    func testClaudeFileHistoryAndSnapshotsAreDefaultTicked() throws {
        let history = home.appendingPathComponent(".claude/file-history/session-1/v1.txt")
        try Fixture.write("old\n", to: history)
        let snapshot = home.appendingPathComponent(".claude/shell-snapshots/snap-1.sh")
        try Fixture.write("export X=1\n", to: snapshot)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: history.deletingLastPathComponent().deletingLastPathComponent().path)
        for path in [history.deletingLastPathComponent().path, history.path, snapshot.path] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: path)
        }

        let group = try XCTUnwrap(ClaudeScanner.scanGroup(config: config, gate: gate))
        let fileHistory = try XCTUnwrap(group.items.first { $0.id == "claude-file-history" })
        let snapshots = try XCTUnwrap(group.items.first { $0.id == "claude-shell-snapshots" })
        XCTAssertTrue(fileHistory.selectedByDefault)
        XCTAssertTrue(snapshots.selectedByDefault)
        XCTAssertEqual(snapshots.paths, [snapshot.path])
    }

    func testRecentClaudeEntriesAreNotOffered() throws {
        let snapshot = home.appendingPathComponent(".claude/shell-snapshots/fresh.sh")
        try Fixture.write("x\n", to: snapshot)
        XCTAssertNil(ClaudeScanner.scanGroup(config: config, gate: gate))
    }

    func testProjectFolderDecoding() {
        XCTAssertEqual(ClaudeScanner.displayPath(forProjectFolder: encodedProject("dev-Foo"), config: config), "~/dev/Foo")
        XCTAssertEqual(ClaudeScanner.displayPath(forProjectFolder: "-opt-thing", config: config), "/opt/thing")
    }

    func testCodexSessionsGroupedPerMonthAndUnticked() throws {
        let jan5 = home.appendingPathComponent(".codex/sessions/2025/01/05/rollout-a.jsonl")
        let jan6 = home.appendingPathComponent(".codex/sessions/2025/01/06/rollout-b.jsonl")
        let feb = home.appendingPathComponent(".codex/sessions/2025/02/01/rollout-c.jsonl")
        for f in [jan5, jan6, feb] { try Fixture.write("{}\n", to: f) }
        let old = Date().addingTimeInterval(-60 * 86400)
        for f in [jan5, jan6] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        }
        // feb stays recent, so it must not be offered.

        let group = try XCTUnwrap(CodexScanner.scanGroup(config: config, gate: gate))
        XCTAssertEqual(group.items.count, 1)
        let jan = group.items[0]
        XCTAssertEqual(jan.id, "codex-sessions:2025-01")
        XCTAssertEqual(Set(jan.paths), Set([jan5.path, jan6.path]))
        XCTAssertEqual(jan.count, 2)
        XCTAssertFalse(jan.selectedByDefault)
        XCTAssertEqual(jan.note, "Needed to resume Codex sessions")
    }

    func testCodexRuntimesAreInfoOnly() throws {
        let runtime = home.appendingPathComponent(".cache/codex-runtimes/node/bin/node")
        try Fixture.write("bin\n", to: runtime)
        let group = try XCTUnwrap(CodexScanner.scanGroup(config: config, gate: gate))
        let info = try XCTUnwrap(group.items.first { $0.id == "codex-runtimes" })
        XCTAssertFalse(info.selectable)
        XCTAssertEqual(info.note, "In use by Codex")
        XCTAssertTrue(info.paths.isEmpty)
    }

    func testHuggingFaceModelsAreOneRowEachAndUnticked() throws {
        let model = home.appendingPathComponent(".cache/huggingface/hub/models--org--tiny-model", isDirectory: true)
        try Fixture.write("weights\n", to: model.appendingPathComponent("snapshots/w.bin"))
        try Fixture.backdate(model, days: 90)
        let fresh = home.appendingPathComponent(".cache/huggingface/hub/models--org--fresh-model", isDirectory: true)
        try Fixture.write("weights\n", to: fresh.appendingPathComponent("w.bin"))

        let group = try XCTUnwrap(ModelCacheScanner.scanGroup(config: config, gate: gate))
        let tiny = try XCTUnwrap(group.items.first { $0.id == "hf:models--org--tiny-model" })
        let freshItem = try XCTUnwrap(group.items.first { $0.id == "hf:models--org--fresh-model" })
        XCTAssertEqual(tiny.title, "org/tiny-model")
        XCTAssertTrue(tiny.selectable)
        XCTAssertFalse(tiny.selectedByDefault)
        XCTAssertEqual(tiny.note, "May be used by an app on this Mac")
        XCTAssertFalse(freshItem.selectable)
        XCTAssertFalse(freshItem.selectedByDefault)
    }

    func testOllamaIsInfoOnly() throws {
        try Fixture.write("blob\n", to: home.appendingPathComponent(".ollama/models/blobs/sha256-abc"))
        let group = try XCTUnwrap(ModelCacheScanner.scanGroup(config: config, gate: gate))
        let ollama = try XCTUnwrap(group.items.first { $0.id == "ollama-models" })
        XCTAssertFalse(ollama.selectable)
        XCTAssertEqual(ollama.note, "Remove with: ollama rm <model>")
    }

    func testEmptyHomeHasNoGroups() {
        XCTAssertNil(ClaudeScanner.scanGroup(config: config, gate: gate))
        XCTAssertNil(CodexScanner.scanGroup(config: config, gate: gate))
        XCTAssertNil(ModelCacheScanner.scanGroup(config: config, gate: gate))
    }

    func testSafetyGateRefusesProtectedAndDatabasePaths() throws {
        let db = home.appendingPathComponent(".claude/projects/p/state.sqlite")
        try Fixture.write("x", to: db)
        let settings = home.appendingPathComponent(".claude/projects/p/settings.json")
        try Fixture.write("{}", to: settings)
        let plugin = home.appendingPathComponent(".codex/plugins/tool/index.js")
        try Fixture.write("x", to: plugin)
        let outside = home.appendingPathComponent("Documents/notes.txt")
        try Fixture.write("x", to: outside)

        XCTAssertEqual(gate.blockReason(for: db.path), "Database file")
        XCTAssertEqual(gate.blockReason(for: settings.path), "Config or credential file")
        XCTAssertEqual(gate.blockReason(for: plugin.path), "Outside the folders this job may touch")
        XCTAssertNotNil(gate.blockReason(for: outside.path))
    }

    func testLsofParsing() {
        let out = "p100\nfcwd\nn/Users/x/dev/a\np200\nfcwd\nn/tmp/b\n"
        XCTAssertEqual(LsofCwdProvider.parse(out), ["/Users/x/dev/a", "/tmp/b"])
    }
}
