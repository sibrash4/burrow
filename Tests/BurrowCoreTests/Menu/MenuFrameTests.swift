import XCTest
@testable import BurrowCore

final class MenuFrameTests: XCTestCase {
    func testInstallerFixtureFirstPage() throws {
        let frame = try XCTUnwrap(MenuFrame.parse(MenuFixtures.stripped(MenuFixtures.text("installer_dryrun"))))
        XCTAssertEqual(frame.kind, .installer)
        XCTAssertEqual(frame.header, MenuHeader(cursorPosition: 1, total: 23, selectedCount: 0, selectedSize: "0B"))
        XCTAssertEqual(frame.rows.count, 18)
        XCTAssertTrue(frame.isComplete)
        XCTAssertEqual(frame.cursorIndex, 0)
        XCTAssertEqual(frame.cursorRow, MenuRow(isCursor: true, isSelected: false, name: "1Password.zip", size: "21.8MB", location: "Downloads"))
        XCTAssertEqual(frame.cursorKey, "1Password.zip | Downloads")
        XCTAssertEqual(frame.rows.filter(\.isCursor).count, 1)
        XCTAssertTrue(frame.rows.allSatisfy { !$0.isSelected && $0.location == "Downloads" })
    }

    func testInstallerNameWithSpacesAndDashes() throws {
        let frame = try XCTUnwrap(MenuFrame.parse(MenuFixtures.stripped(MenuFixtures.text("installer_dryrun"))))
        let row = try XCTUnwrap(frame.rows.first { $0.name.hasPrefix("Mac - Example") })
        XCTAssertEqual(row.name, "Mac - Example Preview Installer.dmg")
        XCTAssertEqual(row.size, "1.4MB")
    }

    func testInstallerWithoutScrollIndicator() throws {
        let text = """
        Select Installers to Remove , 4.1MB, 1 selected

        ○ Flux.zip                      2.1MB | Downloads
        ➤ ● AppCleaner_3.7.zip          4.1MB | Desktop
        ↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit
        """
        let frame = try XCTUnwrap(MenuFrame.parse(text))
        XCTAssertNil(frame.header.cursorPosition)
        XCTAssertEqual(frame.header.selectedCount, 1)
        XCTAssertEqual(frame.header.selectedSize, "4.1MB")
        XCTAssertEqual(frame.totalRows, 2)
        XCTAssertEqual(frame.cursorIndex, 1)
        XCTAssertEqual(frame.cursorRow?.isSelected, true)
        XCTAssertEqual(frame.cursorRow?.location, "Desktop")
    }

    func testPurgeFrame() throws {
        let text = """
        Select Artifacts to Purge [2/9]
        1.5GB, 3 selected
        ● ┌ ~/dev/app                         1.2GB | node_modules | 3mo
        ➤ ● ├ ~/dev/app                       250.0MB | .next | <7d
        ○ └ [cloud] ~/Drive/site               12.0MB | dist
        ○ ─ ~/dev/tool                         unknown | target

        Project: ~/dev/app · 1.4GB · 2/2 selected
        Path: ~/dev/app/.next

        ↑↓ [] Projects / Find | Space Select | Enter Confirm | A All | I Invert | X Skip Project | Q Quit
        """
        let frame = try XCTUnwrap(MenuFrame.parse(text))
        XCTAssertEqual(frame.kind, .purge)
        XCTAssertEqual(frame.header, MenuHeader(cursorPosition: 2, total: 9, selectedCount: 3, selectedSize: "1.5GB"))
        XCTAssertEqual(frame.rows.count, 4)
        XCTAssertEqual(frame.rows[0], MenuRow(isCursor: false, isSelected: true, name: "node_modules", size: "1.2GB", location: "~/dev/app", age: "3mo"))
        XCTAssertEqual(frame.rows[1].name, ".next")
        XCTAssertEqual(frame.rows[1].age, "<7d")
        XCTAssertEqual(frame.rows[2].location, "[cloud] ~/Drive/site")
        XCTAssertNil(frame.rows[2].age)
        XCTAssertEqual(frame.rows[3].size, "unknown")
        XCTAssertEqual(frame.cursorKey, "~/dev/app/.next")
        XCTAssertEqual(frame.cursorIndex, 1)
        XCTAssertTrue(frame.isComplete)
    }

    func testPurgeSubtitleWithUnmeasuredAndSearchNote() throws {
        let text = """
        Select Artifacts to Purge
        1.0MB + 1 unmeasured, 2 selected · n: next match
        ➤ ● ─ ~/a                1.0MB | dist
        Path: ~/a/dist
        ↑↓ | Enter | X Skip | Q
        """
        let frame = try XCTUnwrap(MenuFrame.parse(text))
        XCTAssertEqual(frame.header.selectedCount, 2)
        XCTAssertEqual(frame.header.selectedSize, "1.0MB + 1 unmeasured")
        XCTAssertTrue(frame.isComplete)
    }

    func testPartiallyDrawnFrameIsNotComplete() throws {
        let text = "Select Installers to Remove [1/3] , 0B, 0 selected\n\n➤ ○ Flux.zip   2.1MB | Downloads"
        XCTAssertEqual(MenuFrame.parse(text)?.isComplete, false)
    }

    func testRowNamedQuitIsNotTheFooter() throws {
        let text = "Select Installers to Remove [1/3] , 0B, 0 selected\n\n➤ ○ Quit.dmg   2.1MB | Downloads"
        XCTAssertEqual(MenuFrame.parse(text)?.isComplete, false)
        XCTAssertEqual(MenuFrame.parse(text)?.rows.count, 1)
    }

    func testNotAMenu() {
        XCTAssertNil(MenuFrame.parse("Removing installers...\nDone"))
        XCTAssertNil(MenuFrame.parse(""))
    }
}
