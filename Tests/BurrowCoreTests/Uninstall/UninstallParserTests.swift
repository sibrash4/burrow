import XCTest
@testable import BurrowCore

final class UninstallParserTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesListFixture() throws {
        let apps = try UninstallListParser.parse(fixture("uninstall_list", "json"))
        XCTAssertEqual(apps.count, 25)
        let first = try XCTUnwrap(apps.first)
        XCTAssertEqual(first.name, "GarageBand")
        XCTAssertEqual(first.bundleId, "com.apple.garageband10")
        XCTAssertEqual(first.source, "App")
        XCTAssertEqual(first.path, "/Applications/GarageBand.app")
        XCTAssertEqual(first.bytes, 1_200_000_000)
        XCTAssertTrue(apps.contains { $0.source == "Homebrew" })
    }

    func testUnknownSizeAndBundleId() throws {
        let json = """
        [{"name": "A", "bundle_id": "", "source": "App", "uninstall_name": "A", "path": "/Applications/A.app", "size": "--"},
         {"name": "B", "bundle_id": "unknown", "source": "App", "uninstall_name": "B", "path": "/Applications/B.app", "size": "N/A"}]
        """
        let apps = try UninstallListParser.parse(json)
        XCTAssertEqual(apps.map(\.bytes), [nil, nil])
        XCTAssertEqual(apps.map(\.bundleId), [nil, nil])
    }

    func testIgnoresTextAroundTheArray() throws {
        let text = "Warning: something\n[\n  {\"name\": \"A\", \"bundle_id\": \"x.a\", \"source\": \"App\", \"uninstall_name\": \"A\", \"path\": \"/Applications/A.app\", \"size\": \"1MB\"}\n]\nDone\n"
        XCTAssertEqual(try UninstallListParser.parse(text).count, 1)
        XCTAssertEqual(try UninstallListParser.parse("[]").count, 0)
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try UninstallListParser.parse("No applications found."))
    }

    func testMatchedNamesFromDryRunFixture() throws {
        let text = try fixture("uninstall_dryrun", "txt")
        XCTAssertEqual(UninstallOutput.matchedNames(in: text), ["Flux"])
    }

    func testMatchedNamesWithOddNames() {
        let text = UninstallScreens.matched([("Cisco Secure Client - DART", "7.2MB"), ("Steam Link", "N/A (Steam-managed)")])
        XCTAssertEqual(UninstallOutput.matchedNames(in: text), ["Cisco Secure Client - DART", "Steam Link"])
        XCTAssertEqual(UninstallOutput.matchedNames(in: "nothing here"), [])
    }

    func testRemovalPlan() {
        let plan = UninstallOutput.removalPlan(in: UninstallScreens.plan(["Alpha", "Beta"]))
        XCTAssertEqual(plan.names, ["Alpha", "Beta"])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.files["Alpha"]?.first, "/Applications/Alpha.app, 5.8MB")
        XCTAssertEqual(plan.files["Alpha"]?.count, 3)
    }

    func testRemovalPlanBrewHeaderAndZapNote() {
        var text = "Files to be removed:\n\n◎ Homebrew apps will be fully cleaned, --zap removes configs and data\n\n"
        text += UninstallScreens.plan(["Gamma"], brew: true).replacingOccurrences(of: "Files to be removed:\n\n", with: "")
        let plan = UninstallOutput.removalPlan(in: text)
        XCTAssertEqual(plan.names, ["Gamma"])
        XCTAssertEqual(plan.notes.count, 1)
    }

    func testSummaryParsing() {
        let summary = UninstallOutput.summary(in: UninstallScreens.summary(1, freed: "12.80GB", names: "Alpha"))
        XCTAssertEqual(summary.apps, 1)
        XCTAssertEqual(summary.freedBytes, 12_800_000_000)
        XCTAssertTrue(summary.problems.isEmpty)
        XCTAssertTrue(summary.found)
    }

    func testSummaryWithFailureAndWarning() {
        let text = """
        ====
        Uninstall incomplete
        Removed 2 apps, freed 40MB: A, B
        • Failed: C is still running
        ⊙ System extensions may remain after removal: D
        ====
        """
        let summary = UninstallOutput.summary(in: text)
        XCTAssertEqual(summary.apps, 2)
        XCTAssertEqual(summary.freedBytes, 40_000_000)
        XCTAssertEqual(summary.problems, ["Failed: C is still running", "System extensions may remain after removal: D"])
    }

    func testStatusLines() {
        XCTAssertEqual(UninstallOutput.status(for: "[1/2] Uninstalling Foo..."), "Uninstalling Foo")
        XCTAssertEqual(UninstallOutput.status(for: "Removing Foo (1.2GB)..."), "Removing Foo (1.2GB)")
        XCTAssertNil(UninstallOutput.status(for: "✓ [1/2] Foo"))
    }

    func testPasswordDetectionOnlyLooksPastOffset() {
        XCTAssertFalse(UninstallJob.asksForPassword("Admin required earlier", after: 100))
        XCTAssertTrue(UninstallJob.asksForPassword("abc\n➤ Admin required for Homebrew casks: x", after: 3))
        XCTAssertFalse(UninstallJob.asksForPassword("Admin required", after: 14))
    }
}
