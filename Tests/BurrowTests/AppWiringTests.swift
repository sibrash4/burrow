import XCTest
import BurrowCore
@testable import Burrow

/// Never calls `AppWiring.makeModel()`: that recovers the real Mole whitelist and builds real jobs.
@MainActor
final class AppWiringTests: XCTestCase {
    private func fakeMole(version: String) throws -> (MoleLocator, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mo = dir.appendingPathComponent("mo")
        try "#!/bin/sh\necho 'Mole version \(version)'\n".write(to: mo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mo.path)
        return (MoleLocator(candidates: [mo.path], searchPATH: false), dir)
    }

    func testStatusReadyForTheSupportedVersion() throws {
        let (locator, dir) = try fakeMole(version: "1.59.1")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(AppWiring.moleStatus(locator), .ready)
    }

    func testStatusVersionMismatchCarriesTheVersion() throws {
        let (locator, dir) = try fakeMole(version: "1.61.0")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(AppWiring.moleStatus(locator), .versionMismatch("1.61.0"))
    }

    func testStatusMissingWhenThereIsNoMole() {
        XCTAssertEqual(AppWiring.moleStatus(MoleLocator(candidates: ["/nonexistent/mo"], searchPATH: false)), .missing)
    }

    func testLeftoverMappingParsesSizesAndBarePaths() {
        let sized = Leftover(previewLine: "~/Library/Caches/org.herf.Flux, 135KB")
        XCTAssertEqual(sized.path, "~/Library/Caches/org.herf.Flux")
        XCTAssertEqual(sized.bytes, 135_000)
        let bare = Leftover(previewLine: "~/Library/Application Support/Flux")
        XCTAssertEqual(bare.path, "~/Library/Application Support/Flux")
        XCTAssertNil(bare.bytes)
        let commaInName = Leftover(previewLine: "~/Library/Containers/a, b app, 2.5MB")
        XCTAssertEqual(commaInName.path, "~/Library/Containers/a, b app")
        XCTAssertEqual(commaInName.bytes, 2_500_000)
        let unparsable = Leftover(previewLine: "~/Library/Containers/a, b app")
        XCTAssertEqual(unparsable.path, "~/Library/Containers/a, b app")
        XCTAssertNil(unparsable.bytes)
    }

    func testAIPlaceholderIsLabelledAsSampleData() async throws {
        let job = AppWiring.aiLeftoversPlaceholder()
        XCTAssertEqual(job.kind, .aiLeftovers)
        let scan = try await job.scan()
        XCTAssertTrue(scan.notes.first?.hasPrefix("Sample data") == true)
        XCTAssertFalse(scan.allItems.isEmpty)
    }

    func testAlwaysKeepOnlyReachesTheHandlerForClean() async throws {
        let recorder = Recorder()
        var jobs: [JobKind: MoleJob] = [:]
        for kind in JobKind.allCases { jobs[kind] = MockJob(kind: kind, scanDelay: .zero, stepDelay: .milliseconds(1)) }
        let model = AppModel(jobs: jobs, alwaysKeep: { recorder.add($0.id) })
        let purgeItem = ScanItem(id: "~/dev/x/node_modules", title: "x", paths: ["~/dev/x/node_modules"])
        model.alwaysKeep(purgeItem, in: .purge)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(recorder.all.isEmpty)
        model.alwaysKeep(ScanItem(id: "clean:x", title: "x"), in: .clean)
        for _ in 0..<100 where recorder.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.all, ["clean:x"])
    }

    /// Mole's MOLE_TEST_* variables are its internal test hooks. Nothing in Burrow may set them.
    func testNoSourceFileSetsAMoleTestVariable() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files where file.lastPathComponent != "ProcessEnvironment.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("MOLE_TEST") {
                XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("//"), "\(file.lastPathComponent): \(line)")
            }
        }
    }
}
