import XCTest
@testable import BurrowCore

final class CleanDryRunParserTests: XCTestCase {
    private func parsed() throws -> CleanDryRun {
        CleanDryRunParser.parse(try CleanFixtures.text("clean_dryrun"))
    }

    func testTotalsAndPaths() throws {
        let run = try parsed()
        XCTAssertTrue(run.completed)
        XCTAssertEqual(run.potentialBytes, 9_510_000_000)
        XCTAssertFalse(run.potentialIsPartial)
        XCTAssertEqual(run.itemCount, 427)
        XCTAssertEqual(run.categoryCount, 7)
        XCTAssertEqual(run.listPath, "/Users/test/.config/mole/clean-list.txt")
        XCTAssertEqual(run.freeSpaceBytes, 780_280_000_000)
    }

    func testNotesAndWhitelist() throws {
        let run = try parsed()
        XCTAssertEqual(run.notes.count, 1)
        XCTAssertTrue(run.notes[0].hasPrefix("System caches need sudo"))
        XCTAssertEqual(run.whitelistSummary, "7 core + 1 custom patterns active")
        XCTAssertEqual(run.whitelistPatterns.count, 7)
    }

    func testCategories() throws {
        let run = try parsed()
        XCTAssertEqual(run.categories.count, 14)
        XCTAssertEqual(run.categories.first?.name, "User essentials")
        let empty = run.categories.filter(\.nothingToClean).map(\.name)
        XCTAssertEqual(empty, ["Virtualization", "App leftovers", "Apple Silicon updates", "Device backups & firmware", "Time Machine"])
    }

    func testRows() throws {
        let run = try parsed()
        let rows = run.categories.flatMap(\.rows)

        let cache = try XCTUnwrap(rows.first { $0.label == "User app cache" })
        XCTAssertEqual(cache.count, 17)
        XCTAssertEqual(cache.bytes, 1_200_000_000)
        XCTAssertEqual(cache.kind, .measured)

        let trash = try XCTUnwrap(rows.first { $0.label == "Trash" })
        XCTAssertEqual(trash.kind, .wouldEmpty)
        XCTAssertEqual(trash.count, 58)
        XCTAssertNil(trash.bytes)

        let npm = try XCTUnwrap(rows.first { $0.label == "npm cache" })
        XCTAssertEqual(npm.kind, .wouldClean)
        XCTAssertNil(npm.bytes)

        let worker = try XCTUnwrap(rows.first { $0.label == "Chrome Service Worker" })
        XCTAssertEqual(worker.kind, .wouldClean)
        XCTAssertEqual(worker.bytes, 1_040_000_000)
        XCTAssertEqual(worker.protectedCount, 0)

        let python = try XCTUnwrap(rows.first { $0.label == "Python bytecode cache" && $0.qualifier == "weekly-report" })
        XCTAssertEqual(python.count, 1)
        XCTAssertEqual(python.bytes, 111_000)

        let derived = try XCTUnwrap(rows.first { $0.label == "Xcode DerivedData" })
        XCTAssertEqual(derived.count, 5)
        XCTAssertEqual(derived.bytes, 554_500_000)

        let small = try XCTUnwrap(rows.first { $0.label == "Apple Media Services cache" })
        XCTAssertEqual(small.bytes, 82_000)
        XCTAssertNil(small.count)
    }

    func testInformationalLines() throws {
        let run = try parsed()
        let infos = run.categories.flatMap(\.infos)
        XCTAssertEqual(infos.count, 2)
        XCTAssertEqual(infos[0].label, "Mail data")
        XCTAssertEqual(infos[0].bytes, 1_080_000_000)
        XCTAssertEqual(infos[0].detail, "~/Library/Mail")
        XCTAssertEqual(infos[1].label, "Build artifacts")
        XCTAssertEqual(infos[1].bytes, 98_300_000)
        XCTAssertEqual(infos[1].detail, "mo purge")
    }

    func testPartialTotalAndSkippedRows() {
        let run = CleanDryRunParser.parse("""
        ➤ Developer tools
          → bun cache · would skip (whitelist)
          ✓ Homebrew · skipped (whitelist)
          ◎ Trash · skipped, grant Full Disk Access

        Potential space: At least 2.50GB | Items: 9 | Categories: 1
        """)
        XCTAssertTrue(run.potentialIsPartial)
        XCTAssertEqual(run.potentialBytes, 2_500_000_000)
        let category = run.categories[0]
        XCTAssertEqual(category.rows.map(\.kind), [.wouldSkip, .wouldSkip])
        XCTAssertEqual(category.warnings, ["Trash · skipped, grant Full Disk Access"])
    }
}

final class CleanListParserTests: XCTestCase {
    private func parsed() throws -> CleanList {
        CleanListParser.parse(try CleanFixtures.text("clean_list"))
    }

    func testSections() throws {
        let list = try parsed()
        XCTAssertEqual(list.sections.map(\.name), [
            "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools", "Apps & utilities", "Application Support",
        ])
        XCTAssertEqual(list.allEntries.count, 407)
        XCTAssertEqual(list.allEntries.filter { $0.countedUnder == nil }.count, 403)
    }

    func testEntryFormats() throws {
        let list = try parsed()
        let google = try XCTUnwrap(list.allEntries.first { $0.path == "/Users/test/Library/Caches/Google" })
        XCTAssertEqual(google.bytes, 632_800_000)
        XCTAssertNil(google.countedUnder)

        let spaced = try XCTUnwrap(list.allEntries.first { $0.path.hasSuffix("Mi New Site/MI-New-Site/.next/cache/webpack") })
        XCTAssertEqual(spaced.bytes, 54_300_000)

        let zero = try XCTUnwrap(list.allEntries.first { $0.path.hasSuffix("/Caches/JNA") })
        XCTAssertEqual(zero.bytes, 0)
    }

    func testCountedUnderIsNotDoubleCounted() throws {
        let list = try parsed()
        let covered = list.allEntries.filter { $0.countedUnder != nil }
        XCTAssertEqual(covered.count, 4)
        let chrome = try XCTUnwrap(covered.first { $0.path.hasSuffix("Caches/Google/Chrome/Default") })
        XCTAssertEqual(chrome.countedUnder, "/Users/test/Library/Caches/Google")
        XCTAssertEqual(chrome.bytes, 642_200_000)
        XCTAssertEqual(chrome.countedBytes, 0)

        let rawSum = list.allEntries.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        XCTAssertEqual(rawSum - list.totalBytes, covered.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) })
    }

    func testSummaryAndComments() throws {
        let list = try parsed()
        XCTAssertEqual(list.summaryBytes, 9_510_000_000)
        XCTAssertEqual(list.summaryItems, 427)
        XCTAssertFalse(list.allPaths.contains { $0.hasPrefix("#") })
    }

    func testItemCountsAndUnknownSizes() {
        let list = CleanListParser.parse("""
        === Developer tools ===
        /Users/test/a  # 12KB, 3 items
        /Users/test/b  # size unknown
        /Users/test/c  # size unknown, counted under /Users/test
        """)
        let entries = list.allEntries
        XCTAssertEqual(entries[0].itemCount, 3)
        XCTAssertEqual(entries[0].bytes, 12_000)
        XCTAssertNil(entries[1].bytes)
        XCTAssertEqual(entries[2].countedUnder, "/Users/test")
        XCTAssertEqual(list.totalBytes, 12_000)
    }
}
