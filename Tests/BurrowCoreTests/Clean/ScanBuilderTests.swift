import XCTest
@testable import BurrowCore

final class CleanScanBuilderTests: XCTestCase {
    private func item(_ title: String, in scan: ScanResult, file: StaticString = #filePath, line: UInt = #line) throws -> ScanItem {
        try XCTUnwrap(scan.allItems.first { $0.title == title }, "no item titled \(title)", file: file, line: line)
    }

    func testGroupsFollowMoleSections() throws {
        let scan = try CleanFixtures.scan()
        XCTAssertEqual(scan.kind, .clean)
        XCTAssertEqual(scan.groups.map(\.title), [
            "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools", "Apps & utilities",
            "Application Support", "Large files", "Project artifacts",
        ])
        XCTAssertEqual(scan.reportedTotalBytes, 9_510_000_000)
    }

    func testListIsHumanSized() throws {
        let scan = try CleanFixtures.scan()
        XCTAssertLessThan(scan.allItems.count, 80)
        XCTAssertEqual(Set(scan.allItems.map(\.id)).count, scan.allItems.count, "ids are unique")
    }

    func testClaudeLogsAndChromeAreSeparateItems() throws {
        let scan = try CleanFixtures.scan()
        let claude = try item("Claude logs", in: scan)
        XCTAssertEqual(claude.paths, ["/Users/test/Library/Logs/Claude-3p"])
        XCTAssertEqual(claude.bytes, 1_600_000)

        let chromeCache = try item("Google (Chrome) cache", in: scan)
        let chromeWorkers = try item("Chrome service worker cache", in: scan)
        XCTAssertNotEqual(claude.id, chromeCache.id)
        XCTAssertNotEqual(chromeCache.id, chromeWorkers.id)
        XCTAssertTrue(Set(claude.paths).isDisjoint(with: chromeCache.paths))
    }

    func testCountedUnderPathsJoinTheirOwnerWithoutDoubleCounting() throws {
        let scan = try CleanFixtures.scan()
        let chrome = try item("Google (Chrome) cache", in: scan)
        XCTAssertEqual(chrome.bytes, 632_800_000)
        XCTAssertEqual(Set(chrome.paths), [
            "/Users/test/Library/Caches/Google",
            "/Users/test/Library/Caches/Google/Chrome/Default",
        ])

        let homebrew = try item("Homebrew cache", in: scan)
        XCTAssertEqual(homebrew.bytes, 48_500_000)
        XCTAssertEqual(homebrew.paths.count, 3)
    }

    func testServiceWorkerCachesAreOneItem() throws {
        let scan = try CleanFixtures.scan()
        let workers = try item("Chrome service worker cache", in: scan)
        XCTAssertEqual(workers.paths.count, 45)
        XCTAssertTrue(workers.paths.allSatisfy { $0.contains("/Service Worker/CacheStorage/") })
        XCTAssertEqual(try XCTUnwrap(workers.bytes), 1_040_000_000, accuracy: 5_000_000)
    }

    func testEveryListedPathBelongsToExactlyOneItem() throws {
        let list = CleanListParser.parse(try CleanFixtures.text("clean_list"))
        let scan = try CleanFixtures.scan()
        let owned = scan.allItems.filter { !$0.id.hasPrefix("clean:cmd:") && !$0.id.hasPrefix("clean:info:") }.flatMap(\.paths)
        XCTAssertEqual(owned.count, Set(owned).count, "no path in two items")
        XCTAssertEqual(Set(owned), list.allPaths, "no listed path is missing from the rows")
    }

    func testRowBytesAddUpToMolesTotal() throws {
        let list = CleanListParser.parse(try CleanFixtures.text("clean_list"))
        let scan = try CleanFixtures.scan()
        let rows = scan.allItems.filter { !$0.id.hasPrefix("clean:info:") }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        XCTAssertEqual(rows, list.totalBytes)
    }

    func testTrashIsOneRowWithEveryEntry() throws {
        let scan = try CleanFixtures.scan()
        let trash = try item("Trash", in: scan)
        XCTAssertEqual(trash.id, CleanScanBuilder.trashID)
        XCTAssertEqual(trash.paths.count, 58)
        XCTAssertTrue(trash.paths.allSatisfy { $0.hasPrefix("/Users/test/.Trash/") })
        XCTAssertTrue(trash.selectable)
    }

    func testFriendlyTitles() throws {
        let scan = try CleanFixtures.scan()
        for title in [
            "Crash and diagnostic reports", "Zoom logs", "Slack cache", "Geod temp files", "Microsoft Word temp files",
            "Xcode DerivedData", "Clang module cache", "Next.js build cache (newsletter-site)",
            "Python bytecode cache (weekly-report)", "Ghostty cache", "macOS Help cache",
        ] {
            XCTAssertNoThrow(try item(title, in: scan), title)
        }
    }

    func testEmptyFoldersAreFoldedPerGroup() throws {
        let scan = try CleanFixtures.scan()
        let essentials = try XCTUnwrap(scan.groups.first { $0.title == "User essentials" })
        let folded = essentials.items.filter { $0.id.hasPrefix("clean:empty:") }
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].bytes, 0)
        XCTAssertTrue(folded[0].paths.contains("/Users/test/Library/Caches/JNA"))
        XCTAssertEqual(essentials.items.last?.id, folded[0].id, "folded row sorts last")
    }

    func testCommandBasedRows() throws {
        let scan = try CleanFixtures.scan()
        let npm = try item("npm cache", in: scan)
        XCTAssertTrue(npm.selectable)
        XCTAssertNil(npm.bytes)
        XCTAssertEqual(npm.paths, ["/Users/test/.npm/_cacache/*"])
        XCTAssertEqual(try item("pip cache", in: scan).paths, ["/Users/test/Library/Caches/pip/*"])
        XCTAssertEqual(try item("GitHub CLI cache", in: scan).paths, ["/Users/test/.cache/gh"])
    }

    func testUnknownCommandRowCannotBeProtected() {
        let dry = CleanDryRunParser.parse("""
        ➤ Developer tools
          → mystery tool cache · would clean
        """)
        let scan = CleanScanBuilder.build(dryRun: dry, list: CleanList(), home: "/Users/test")
        let item = scan.allItems[0]
        XCTAssertFalse(item.selectable)
        XCTAssertTrue(item.selectedByDefault)
        XCTAssertEqual(item.note, "Always cleaned by Mole")
        XCTAssertTrue(scan.defaultSelection.isEmpty)
    }

    func testHomebrewRowMergesIntoItsFolderRow() {
        let dry = CleanDryRunParser.parse("""
        ➤ Developer tools
          → Homebrew · would cleanup
        """)
        let list = CleanListParser.parse("""
        === User essentials ===
        /Users/test/Library/Caches/Homebrew  # 48.5MB
        """)
        let scan = CleanScanBuilder.build(dryRun: dry, list: list, home: "/Users/test")
        XCTAssertEqual(scan.allItems.map(\.title), ["Homebrew cache"])
    }

    func testSimulatorDevicesCannotBeProtected() {
        let list = CleanListParser.parse("""
        === Developer tools ===
        /Users/test/Library/Developer/CoreSimulator/Devices/AAAAAAAA-1111-2222-3333-444444444444  # 300.0MB
        """)
        let scan = CleanScanBuilder.build(dryRun: CleanDryRun(), list: list, home: "/Users/test")
        let item = scan.allItems[0]
        XCTAssertEqual(item.title, "Unavailable Xcode simulators")
        XCTAssertFalse(item.selectable)
        XCTAssertTrue(item.selectedByDefault)
        XCTAssertEqual(item.note, "Always cleaned by Mole")
        XCTAssertTrue(scan.defaultSelection.isEmpty)
    }

    func testInformationalRowsAreNeverSelected() throws {
        let scan = try CleanFixtures.scan()
        let mail = try item("Mail data", in: scan)
        XCTAssertFalse(mail.selectable)
        XCTAssertFalse(mail.selectedByDefault)
        XCTAssertFalse(scan.defaultSelection.contains(mail.id))
        XCTAssertEqual(mail.bytes, 1_080_000_000)
    }

    func testDefaultSelectionCoversEveryCleanableRow() throws {
        let scan = try CleanFixtures.scan()
        let cleanable = scan.allItems.filter(\.selectable)
        XCTAssertEqual(scan.defaultSelection, Set(cleanable.map(\.id)))
    }

    func testSudoNoticeBecomesNote() throws {
        let scan = try CleanFixtures.scan()
        XCTAssertEqual(scan.notes, ["System caches need admin access and are skipped."])
    }

    func testPartialTotalAddsNote() {
        let dry = CleanDryRunParser.parse("""
        ➤ Application Support
          → Application Support logs/caches · 33.4MB dry

        Dry run complete - no changes made
        Potential space: At least 33.4MB | Items: 1 | Categories: 1
        """)
        let scan = CleanScanBuilder.build(dryRun: dry, list: CleanList(), home: "/Users/test")
        XCTAssertTrue(scan.notes.contains { $0.contains("minimum") })
    }

    func testRowsWithTheSameNameGetTheirFolderAppended() {
        let list = CleanListParser.parse("""
        === User essentials ===
        /Users/test/Library/Caches/Claude-3p/x  # 1.0MB
        === Application Support ===
        /Users/test/Library/Application Support/Claude/Cache/y  # 2.0MB
        """)
        let scan = CleanScanBuilder.build(dryRun: CleanDryRun(), list: list, home: "/Users/test")
        XCTAssertEqual(Set(scan.allItems.map(\.title)), ["Claude cache (Claude-3p)", "Claude cache (Claude)"])
    }

    func testFriendlyNames() {
        XCTAssertEqual(FriendlyName.make("com.mitchellh.ghostty"), "Ghostty")
        XCTAssertEqual(FriendlyName.make("com.wisp.app.sparkle"), "Wisp")
        XCTAssertEqual(FriendlyName.make("com.todesktop.230313mzl4w4u92"), "Todesktop")
        XCTAssertEqual(FriendlyName.make("com.microsoft.Word"), "Microsoft Word")
        XCTAssertEqual(FriendlyName.make("94KV3E626L.com.example.app"), "Example")
        XCTAssertEqual(FriendlyName.make("group.com.example.notes"), "Notes")
        XCTAssertEqual(FriendlyName.make("claude-cli-nodejs"), "Claude CLI")
        XCTAssertEqual(FriendlyName.make("printscout-ui"), "Printscout Ui")
        XCTAssertEqual(FriendlyName.make("GeoServices"), "GeoServices")
        XCTAssertEqual(FriendlyName.make("DiscRecording.log"), "DiscRecording")
    }
}

