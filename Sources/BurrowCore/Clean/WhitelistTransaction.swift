import CryptoKit
import Darwin
import Foundation

public enum WhitelistError: Error, LocalizedError, Sendable, Equatable {
    case invalidPattern(String)
    case backupUnreadable(String)
    /// A whitelist transaction is running (its backup exists); permanent edits would be lost on restore.
    case transactionInProgress
    case notUTF8
    /// The file no longer holds what Burrow wrote. Burrow leaves the file as it is.
    case changedDuringRun

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let p): "Can't protect \"\(p)\": it isn't a single-line path."
        case .backupUnreadable(let why): "Burrow's whitelist backup couldn't be read (\(why)). Your Mole whitelist was left as is."
        case .transactionInProgress: "A clean is running. Try again when it finishes."
        case .notUTF8: "Your Mole whitelist isn't plain text, so Burrow left it alone."
        case .changedDuringRun: "Your Mole whitelist changed during the clean, so Burrow left it as it is. Lines marked \"# Burrow: temporary\" may still be in it."
        }
    }
}

/// What Mole 1.59 uses when `~/.config/mole/whitelist` does not exist (`DEFAULT_WHITELIST_PATTERNS`
/// in lib/core/base.sh). Once the file exists these are no longer applied, so a file Burrow creates
/// must start with them or the first untick would silently drop protection such as iCloud Drive.
enum MoleWhitelistDefaults {
    static func patterns(home: String) -> [String] {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return [
            "\(h)/Library/Caches/ms-playwright*",
            "\(h)/.gradle/caches/*",
            "\(h)/.gradle/daemon/*",
            "\(h)/.ollama/models/*",
            "\(h)/Library/Caches/com.nssurge.surge-mac/*",
            "\(h)/Library/Application Support/com.nssurge.surge-mac/*",
            "\(h)/Library/Caches/org.R-project.R/R/renv/*",
            "\(h)/Library/Caches/JetBrains*",
            "\(h)/Library/Caches/com.jetbrains.toolbox*",
            "\(h)/Library/Caches/tealdeer/tldr-pages",
            "\(h)/Library/Application Support/JetBrains*",
            "\(h)/Library/Caches/com.apple.finder",
            "\(h)/Library/Mobile Documents*",
            "FINDER_METADATA",
        ]
    }

    static func fileText(home: String) -> String {
        let header = [
            "# Mole Whitelist - Protected paths won't be deleted",
            "# Burrow: no whitelist existed, so Mole's default protections are written here first.",
        ]
        return (header + patterns(home: home)).joined(separator: "\n") + "\n"
    }
}

enum WhitelistFile {
    static func resolved(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath() : url
    }

    static func validate(_ patterns: [String]) throws {
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || pattern.contains(where: { $0.isNewline || $0 == "\0" }) {
                throw WhitelistError.invalidPattern(pattern)
            }
        }
    }

    static func lines(_ patterns: [String]) -> String { patterns.joined(separator: "\n") + "\n" }
}

/// `whitelist.lock` sits next to the backup and holds the pid of the Burrow process that is mid-transaction.
enum WhitelistLock {
    static func url(beside backupURL: URL) -> URL {
        backupURL.deletingLastPathComponent().appendingPathComponent("whitelist.lock")
    }

    /// True only when a live process named Burrow wrote the lock. A stale pid, or a pid reused by another
    /// program, does not count, so a crash never blocks recovery for good.
    static func heldByOtherBurrow(beside backupURL: URL) -> Bool {
        guard let text = try? String(contentsOf: url(beside: backupURL), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, pid != getpid()
        else { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        return executableName(of: pid) == "Burrow"
    }

    static func write(beside backupURL: URL) throws {
        let file = url(beside: backupURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(getpid())\n".utf8).write(to: file, options: .atomic)
    }

    static func remove(beside backupURL: URL) {
        try? FileManager.default.removeItem(at: url(beside: backupURL))
    }

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Edits Mole's whitelist for one run and puts the exact original bytes back afterwards.
///
/// Mole reads `~/.config/mole/whitelist` fresh on every run, so appended lines protect those
/// paths for this run only. Appending never weakens existing protection. The one trap is a
/// missing file: Mole then applies its optional defaults, and a new file that held only our
/// lines would replace them. `begin` writes those defaults first in that case.
///
/// Only one Burrow transaction may be open at a time: the lock and the backup say which process owns it.
/// Restore runs only while the file still holds the bytes Burrow wrote (the backup stores their hash).
public final class WhitelistTransaction: @unchecked Sendable {
    public static let temporaryMarker = "# Burrow: temporary (removed after the run)"
    private static let backupMagic = "BURROW-WHITELIST-BACKUP 2\n"
    /// Backups left by earlier builds hold the real original too. They carry no hash, so they restore unchecked.
    private static let legacyBackupMagic = "BURROW-WHITELIST-BACKUP 1\n"

    public static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole/whitelist")
    }

    public static var defaultBackupURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Burrow/whitelist.backup")
    }

    public let fileURL: URL
    public let backupURL: URL
    private let home: String

    public init(fileURL: URL = defaultFileURL, backupURL: URL = defaultBackupURL, home: String = NSHomeDirectory()) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        self.home = home
    }

    public var isActive: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Where the original goes when a restore finds the file changed. It is no longer a transaction.
    public var unrestoredURL: URL { backupURL.appendingPathExtension("unrestored") }

    /// Backs up the whitelist, then appends `extraPatterns` under a marker line.
    public func begin(extraPatterns: [String]) throws {
        try WhitelistFile.validate(extraPatterns)
        // Another live Burrow is mid-run: its backup and lock are not ours to touch.
        guard !WhitelistLock.heldByOtherBurrow(beside: backupURL) else { throw WhitelistError.transactionInProgress }
        // A backup left by a crash holds the real original; put it back before backing up again.
        try restore()

        let fm = FileManager.default
        let target = WhitelistFile.resolved(fileURL)
        let original: Data? = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil

        var data = original ?? Data(MoleWhitelistDefaults.fileText(home: home).utf8)
        if let last = data.last, last != 0x0A { data.append(0x0A) }
        let present = Set(String(decoding: data, as: UTF8.self).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var seen = Set<String>()
        let fresh = extraPatterns.filter { !present.contains($0) && seen.insert($0).inserted }
        data.append(Data(("\n" + Self.temporaryMarker + "\n" + (fresh.isEmpty ? "" : WhitelistFile.lines(fresh))).utf8))

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WhitelistLock.write(beside: backupURL)
            try writeBackup(original, written: Self.digest(data))
            try data.write(to: target, options: .atomic)
        } catch {
            try? finish(checkingFile: false)
            WhitelistLock.remove(beside: backupURL)
            throw error
        }
    }

    /// Right before `mo` starts: the whitelist must still hold Burrow's marker and every pattern it added.
    /// Mole reads the file when it starts, so a block removed after the preview would not protect anything.
    public func confirmIntact(extraPatterns: [String]) throws {
        guard let text = try? String(contentsOf: WhitelistFile.resolved(fileURL), encoding: .utf8) else {
            throw WhitelistError.changedDuringRun
        }
        let lines = Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        guard lines.contains(Self.temporaryMarker),
              extraPatterns.allSatisfy({ lines.contains($0.trimmingCharacters(in: .whitespaces)) })
        else { throw WhitelistError.changedDuringRun }
    }

    /// Puts the original whitelist back (or removes the file if there was none) and deletes the backup.
    /// Only while the file still holds what Burrow wrote. Otherwise the file is left alone, the original is
    /// kept as `unrestoredURL`, and `WhitelistError.changedDuringRun` is thrown.
    /// Does nothing when no transaction is open.
    public func restore() throws { try finish(checkingFile: true) }

    private func finish(checkingFile: Bool) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else { return }
        guard !WhitelistLock.heldByOtherBurrow(beside: backupURL) else { throw WhitelistError.transactionInProgress }
        let saved = try readBackup()
        let target = WhitelistFile.resolved(fileURL)
        let current: Data? = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil

        if checkingFile, let written = saved.written {
            // Absent before the run and still absent, or present and byte-for-byte what Burrow wrote.
            let unchanged = current.map { Self.digest($0) == written } ?? !saved.existed
            guard unchanged else {
                // Keep the earlier file for the user, then stop treating the run as open so Burrow is not stuck.
                if saved.existed { try saved.payload.write(to: unrestoredURL, options: .atomic) }
                try fm.removeItem(at: backupURL)
                WhitelistLock.remove(beside: backupURL)
                throw WhitelistError.changedDuringRun
            }
        }

        if saved.existed {
            try saved.payload.write(to: target, options: .atomic)
        } else if current != nil {
            try fm.removeItem(at: target)
        }
        try fm.removeItem(at: backupURL)
        WhitelistLock.remove(beside: backupURL)
    }

    /// Call at launch. Restores a whitelist left modified by a crashed run. Returns true if it did.
    /// Skips (returns false) when another live Burrow is mid-run.
    @discardableResult
    public static func recoverIfNeeded(fileURL: URL = defaultFileURL, backupURL: URL = defaultBackupURL) throws -> Bool {
        let transaction = WhitelistTransaction(fileURL: fileURL, backupURL: backupURL)
        guard transaction.isActive, !WhitelistLock.heldByOtherBurrow(beside: backupURL) else { return false }
        try transaction.restore()
        return true
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Backup file

    private func writeBackup(_ original: Data?, written: String) throws {
        var data = Data(Self.backupMagic.utf8)
        data.append(Data((original == nil ? "absent\n" : "existed\n").utf8))
        data.append(Data("written \(written)\n".utf8))
        if let original { data.append(original) }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: backupURL, options: .atomic)
    }

    private func readBackup() throws -> (existed: Bool, written: String?, payload: Data) {
        let data: Data
        do { data = try Data(contentsOf: backupURL) } catch { throw WhitelistError.backupUnreadable(error.localizedDescription) }
        let magic = Data(Self.backupMagic.utf8)
        let legacy = Data(Self.legacyBackupMagic.utf8)
        let isLegacy = !data.starts(with: magic) && data.starts(with: legacy)
        guard data.starts(with: magic) || isLegacy else { throw WhitelistError.backupUnreadable("unknown format") }

        var index = data.index(data.startIndex, offsetBy: isLegacy ? legacy.count : magic.count)
        func nextLine() throws -> String {
            guard let end = data[index...].firstIndex(of: 0x0A) else { throw WhitelistError.backupUnreadable("missing state") }
            defer { index = data.index(after: end) }
            return String(decoding: data[index..<end], as: UTF8.self)
        }
        let state = try nextLine()
        guard state == "existed" || state == "absent" else { throw WhitelistError.backupUnreadable("missing state") }
        if isLegacy { return (state == "existed", nil, Data(data[index...])) }
        let writtenLine = try nextLine()
        guard writtenLine.hasPrefix("written ") else { throw WhitelistError.backupUnreadable("missing state") }
        return (state == "existed", String(writtenLine.dropFirst("written ".count)), Data(data[index...]))
    }
}

/// Patterns the user chose to keep for good, stored in their own block of the whitelist:
///
///     # Burrow: always keep
///     /Users/test/Library/Logs/Claude-3p
///
/// The block ends at the next blank or comment line.
public struct PersistentKeeps: Sendable {
    public static let marker = "# Burrow: always keep"

    public let fileURL: URL
    public let backupURL: URL
    private let home: String

    public init(
        fileURL: URL = WhitelistTransaction.defaultFileURL,
        backupURL: URL = WhitelistTransaction.defaultBackupURL,
        home: String = NSHomeDirectory()
    ) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        self.home = home
    }

    public func list() throws -> [String] {
        guard let text = try read() else { return [] }
        let lines = text.components(separatedBy: "\n")
        guard let range = Self.blockRange(in: lines) else { return [] }
        return lines[range].map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func add(_ patterns: [String]) throws {
        try WhitelistFile.validate(patterns)
        try guardNoTransaction()
        let existing = try read()
        var lines = (existing ?? MoleWhitelistDefaults.fileText(home: home)).components(separatedBy: "\n")
        let present = Set(lines.map { $0.trimmingCharacters(in: .whitespaces) })
        var seen = Set<String>()
        let fresh = patterns.filter { !present.contains($0) && seen.insert($0).inserted }
        guard !fresh.isEmpty || existing == nil else { return }

        if let range = Self.blockRange(in: lines) {
            lines.insert(contentsOf: fresh, at: range.upperBound)
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", Self.marker] + fresh + [""]
        }
        try write(lines.joined(separator: "\n"))
    }

    public func remove(_ patterns: [String]) throws {
        try guardNoTransaction()
        guard let text = try read() else { return }
        var lines = text.components(separatedBy: "\n")
        guard let range = Self.blockRange(in: lines) else { return }
        let drop = Set(patterns)
        let kept = lines[range].filter { !drop.contains($0.trimmingCharacters(in: .whitespaces)) }
        if kept.isEmpty {
            var start = range.lowerBound - 1
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            lines.removeSubrange(start..<range.upperBound)
        } else {
            lines.replaceSubrange(range, with: kept)
        }
        try write(lines.joined(separator: "\n"))
    }

    // MARK: Private

    /// Index range of the pattern lines after the marker.
    static func blockRange(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let line = lines[end].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { break }
            end += 1
        }
        return (start + 1)..<end
    }

    private func read() throws -> String? {
        let target = WhitelistFile.resolved(fileURL)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let text = String(data: try Data(contentsOf: target), encoding: .utf8) else { throw WhitelistError.notUTF8 }
        return text
    }

    private func write(_ text: String) throws {
        let target = WhitelistFile.resolved(fileURL)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
    }

    private func guardNoTransaction() throws {
        if FileManager.default.fileExists(atPath: backupURL.path) || WhitelistLock.heldByOtherBurrow(beside: backupURL) {
            throw WhitelistError.transactionInProgress
        }
    }
}
