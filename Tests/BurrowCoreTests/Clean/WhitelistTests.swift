import XCTest
@testable import BurrowCore

/// Every test uses its own temp folder; the real ~/.config/mole is never touched.
class TempDirTestCase: XCTestCase {
    var dir: URL!
    var whitelist: URL { dir.appendingPathComponent("config/whitelist") }
    var backup: URL { dir.appendingPathComponent("support/whitelist.backup") }
    var lockFile: URL { dir.appendingPathComponent("support/whitelist.lock") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("config"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ data: Data, to url: URL? = nil) throws {
        try data.write(to: url ?? whitelist)
    }

    func bytes() throws -> Data { try Data(contentsOf: whitelist) }
    func text() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    var whitelistExists: Bool { FileManager.default.fileExists(atPath: whitelist.path) }
    var backupExists: Bool { FileManager.default.fileExists(atPath: backup.path) }

    func transaction() -> WhitelistTransaction {
        WhitelistTransaction(fileURL: whitelist, backupURL: backup, home: "/Users/test")
    }
}

final class WhitelistTransactionTests: TempDirTestCase {
    func testAppendsPatternsUnderMarkerAndKeepsExistingLines() throws {
        let original = Data("# Mole Whitelist\n/Users/test/keep-me\n".utf8)
        try write(original)
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/Library/Logs/Claude-3p", "/Users/test/Library/Caches/Google"])

        let during = try text()
        XCTAssertTrue(during.hasPrefix("# Mole Whitelist\n/Users/test/keep-me\n"))
        XCTAssertTrue(during.contains(WhitelistTransaction.temporaryMarker + "\n/Users/test/Library/Logs/Claude-3p\n/Users/test/Library/Caches/Google\n"))
        XCTAssertTrue(tx.isActive)
    }

    func testRestorePutsBackExactBytes() throws {
        // No trailing newline, CRLF, and bytes that are not valid UTF-8.
        var original = Data("/Users/test/a\r\n/Users/test/b".utf8)
        original.append(contentsOf: [0xFF, 0xFE, 0x00, 0x41])
        try write(original)

        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        XCTAssertNotEqual(try bytes(), original)
        try tx.restore()

        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
        XCTAssertFalse(tx.isActive)
    }

    func testMissingFileGetsMoleDefaultsFirstAndIsRemovedAfterwards() throws {
        XCTAssertFalse(whitelistExists)
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/Library/Logs/Claude-3p"])

        let during = try text()
        // Without these, a file holding only our lines would replace Mole's optional defaults.
        XCTAssertTrue(during.contains("/Users/test/Library/Mobile Documents*"))
        XCTAssertTrue(during.contains("/Users/test/.ollama/models/*"))
        XCTAssertTrue(during.contains("/Users/test/Library/Caches/com.apple.finder"))
        XCTAssertTrue(during.contains("FINDER_METADATA"))
        XCTAssertTrue(during.contains("/Users/test/Library/Logs/Claude-3p"))

        try tx.restore()
        XCTAssertFalse(whitelistExists, "a file that did not exist is removed again")
        XCTAssertFalse(backupExists)
    }

    func testDefaultsMatchMoles14Patterns() {
        let patterns = MoleWhitelistDefaults.patterns(home: "/Users/test")
        XCTAssertEqual(patterns.count, 14)
        XCTAssertEqual(patterns.last, "FINDER_METADATA")
        XCTAssertTrue(patterns.dropLast().allSatisfy { $0.hasPrefix("/Users/test/") })
    }

    func testEmptyExistingFileIsNotGivenDefaults() throws {
        try write(Data())
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        XCTAssertFalse(try text().contains("Mobile Documents"), "an existing file already replaced the defaults")
        try tx.restore()
        XCTAssertEqual(try bytes(), Data())
    }

    func testRecoverIfNeededRestoresLeftoverBackup() throws {
        let original = Data("/Users/test/original\n".utf8)
        try write(original)
        try transaction().begin(extraPatterns: ["/Users/test/x"])
        // The app dies here. A new launch runs recovery.
        let recovered = try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup)

        XCTAssertTrue(recovered)
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
        XCTAssertFalse(try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup), "nothing left to recover")
    }

    func testRecoverIfNeededRemovesFileThatDidNotExist() throws {
        try transaction().begin(extraPatterns: ["/Users/test/x"])
        XCTAssertTrue(whitelistExists)
        try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup)
        XCTAssertFalse(whitelistExists)
    }

    func testBeginAfterCrashDoesNotOverwriteTheRealBackup() throws {
        let original = Data("/Users/test/original\n".utf8)
        try write(original)
        try transaction().begin(extraPatterns: ["/Users/test/first"])
        // Crash, then a second run starts without calling recovery.
        let second = transaction()
        try second.begin(extraPatterns: ["/Users/test/second"])
        try second.restore()
        XCTAssertEqual(try bytes(), original)
    }

    func testRestoreWithoutTransactionDoesNothing() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        try transaction().restore()
        XCTAssertEqual(try bytes(), original)
    }

    func testInvalidPatternIsRejectedBeforeAnythingChanges() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        XCTAssertThrowsError(try transaction().begin(extraPatterns: ["/Users/test/ok", "/Users/test/evil\n/Users/test"])) { error in
            guard case WhitelistError.invalidPattern = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(backupExists)
    }

    func testPatternsAlreadyPresentAreNotRepeated() throws {
        try write(Data("/Users/test/a\n".utf8))
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/a", "/Users/test/b", "/Users/test/b"])
        let lines = try text().components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0 == "/Users/test/a" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "/Users/test/b" }.count, 1)
    }

    func testSymlinkedWhitelistStaysASymlink() throws {
        let real = dir.appendingPathComponent("dotfiles-whitelist")
        let original = Data("/Users/test/a\n".utf8)
        try original.write(to: real)
        try FileManager.default.createSymbolicLink(at: whitelist, withDestinationURL: real)

        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/b"])
        try tx.restore()

        XCTAssertEqual(try Data(contentsOf: real), original)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: whitelist.path))
    }

    func testCorruptBackupIsKeptAndWhitelistLeftAlone() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: backup)
        XCTAssertThrowsError(try transaction().restore())
        XCTAssertEqual(try bytes(), original)
        XCTAssertTrue(backupExists)
    }

    func testRestoreRefusesToOverwriteAWhitelistEditedDuringTheRun() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        let edited = Data("/Users/test/a\n/Users/test/user-added\n".utf8)
        try edited.write(to: whitelist)

        XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? WhitelistError, .changedDuringRun) }
        XCTAssertEqual(try bytes(), edited, "the user's later edit is kept")
        XCTAssertFalse(tx.isActive, "the file is no longer treated as a transaction")
        XCTAssertEqual(try Data(contentsOf: tx.unrestoredURL), original, "the original is kept aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFile.path))
    }

    func testRestoreAlsoCatchesAWhitelistThatWasDeletedDuringTheRun() throws {
        try write(Data("/Users/test/a\n".utf8))
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        try FileManager.default.removeItem(at: whitelist)

        XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? WhitelistError, .changedDuringRun) }
        XCTAssertFalse(whitelistExists, "a deleted file is not brought back")
    }

    func testConfirmIntactNeedsTheMarkerAndEveryPattern() throws {
        try write(Data("/Users/test/a\n".utf8))
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        XCTAssertNoThrow(try tx.confirmIntact(extraPatterns: ["/Users/test/x"]))

        try Data("/Users/test/a\n/Users/test/x\n".utf8).write(to: whitelist)
        XCTAssertThrowsError(try tx.confirmIntact(extraPatterns: ["/Users/test/x"]), "marker removed") {
            XCTAssertEqual($0 as? WhitelistError, .changedDuringRun)
        }
    }

    func testLockHeldByAnotherLiveBurrowBlocksRecoveryAndANewRun() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        let other = try startProcessNamedBurrow()
        defer { other.terminate() }
        try "\(other.processIdentifier)\n".write(to: lockFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup), "another Burrow is mid-run")
        XCTAssertTrue(backupExists)
        XCTAssertThrowsError(try transaction().begin(extraPatterns: ["/Users/test/y"])) {
            XCTAssertEqual($0 as? WhitelistError, .transactionInProgress)
        }
        XCTAssertThrowsError(try tx.restore()) { XCTAssertEqual($0 as? WhitelistError, .transactionInProgress) }
        XCTAssertTrue(backupExists, "the other run's backup is untouched")

        // Once the other process is gone, recovery works again.
        other.terminate()
        other.waitUntilExit()
        XCTAssertTrue(try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup))
        XCTAssertEqual(try bytes(), original)
    }

    func testLockFromAPidThatIsGoneDoesNotBlockRecovery() throws {
        let original = Data("/Users/test/a\n".utf8)
        try write(original)
        try transaction().begin(extraPatterns: ["/Users/test/x"])
        try "2000000\n".write(to: lockFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(try WhitelistTransaction.recoverIfNeeded(fileURL: whitelist, backupURL: backup))
        XCTAssertEqual(try bytes(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFile.path), "the lock is released")
    }

    /// A live process whose executable is named Burrow, as another running copy of the app is.
    private func startProcessNamedBurrow() throws -> Process {
        let folder = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("Burrow")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        return process
    }
}

final class PersistentKeepsTests: TempDirTestCase {
    private func keeps() -> PersistentKeeps {
        PersistentKeeps(fileURL: whitelist, backupURL: backup, home: "/Users/test")
    }

    func testAddListAndRemoveLeaveOtherLinesAlone() throws {
        let original = "# Mole Whitelist\n/Users/test/mine\n\n# another comment\n/Users/test/other\n"
        try write(Data(original.utf8))

        try keeps().add(["/Users/test/Library/Logs/Claude-3p", "/Users/test/Library/Caches/Google"])
        XCTAssertEqual(try keeps().list(), ["/Users/test/Library/Logs/Claude-3p", "/Users/test/Library/Caches/Google"])
        XCTAssertTrue(try text().hasPrefix(original.trimmingCharacters(in: .newlines)))

        try keeps().add(["/Users/test/more", "/Users/test/Library/Caches/Google"])
        XCTAssertEqual(try keeps().list().count, 3, "duplicates are not added")

        try keeps().remove(["/Users/test/Library/Logs/Claude-3p"])
        XCTAssertEqual(try keeps().list(), ["/Users/test/Library/Caches/Google", "/Users/test/more"])

        try keeps().remove(["/Users/test/Library/Caches/Google", "/Users/test/more"])
        XCTAssertEqual(try keeps().list(), [])
        XCTAssertFalse(try text().contains(PersistentKeeps.marker))
        XCTAssertTrue(try text().contains("/Users/test/mine"))
        XCTAssertTrue(try text().contains("/Users/test/other"))
    }

    func testBlockEndsAtBlankLineSoNeighboursAreNotListed() throws {
        try write(Data("\(PersistentKeeps.marker)\n/Users/test/a\n\n/Users/test/not-ours\n".utf8))
        XCTAssertEqual(try keeps().list(), ["/Users/test/a"])
    }

    func testAddingWithNoFileWritesMoleDefaultsFirst() throws {
        try keeps().add(["/Users/test/Library/Logs/Claude-3p"])
        let content = try text()
        XCTAssertTrue(content.contains("/Users/test/Library/Mobile Documents*"))
        XCTAssertEqual(try keeps().list(), ["/Users/test/Library/Logs/Claude-3p"])
    }

    func testListWithNoFileIsEmptyAndDoesNotCreateOne() throws {
        XCTAssertEqual(try keeps().list(), [])
        XCTAssertFalse(whitelistExists)
        try keeps().remove(["/Users/test/x"])
        XCTAssertFalse(whitelistExists)
    }

    func testEditsAreRefusedWhileATransactionIsOpen() throws {
        try write(Data("/Users/test/a\n".utf8))
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/x"])
        XCTAssertThrowsError(try keeps().add(["/Users/test/y"])) { XCTAssertEqual($0 as? WhitelistError, .transactionInProgress) }
        try tx.restore()
        XCTAssertNoThrow(try keeps().add(["/Users/test/y"]))
    }

    func testKeepsSurviveATransaction() throws {
        try keeps().add(["/Users/test/forever"])
        let before = try bytes()
        let tx = transaction()
        try tx.begin(extraPatterns: ["/Users/test/once"])
        XCTAssertTrue(try text().contains("/Users/test/forever"))
        try tx.restore()
        XCTAssertEqual(try bytes(), before)
        XCTAssertEqual(try keeps().list(), ["/Users/test/forever"])
    }
}
