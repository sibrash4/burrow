// Shared contract between the job engines (BurrowCore) and the UI (Burrow).
// Change this file only with care: every job and every view builds against it.

import Foundation

public enum JobKind: String, CaseIterable, Identifiable, Sendable {
    case clean, purge, installers, uninstall, aiLeftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clean: "Clean"
        case .purge: "Purge"
        case .installers: "Installers"
        case .uninstall: "Uninstall"
        case .aiLeftovers: "AI leftovers"
        }
    }

    public var subtitle: String {
        switch self {
        case .clean: "Caches, logs and app junk"
        case .purge: "Build folders in your projects"
        case .installers: "Leftover .dmg, .pkg and .zip files"
        case .uninstall: "Apps and the files they leave behind"
        case .aiLeftovers: "Old agent worktrees, transcripts and model caches"
        }
    }

    public var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .purge: "shippingbox"
        case .installers: "opticaldiscdrive"
        case .uninstall: "trash"
        case .aiLeftovers: "brain"
        }
    }
}

/// One row the user can tick or untick.
public struct ScanItem: Identifiable, Hashable, Sendable {
    /// Stable across rescans: a path, an app bundle id, or a file name.
    public let id: String
    public var title: String
    /// Secondary line: a path, location, or "Last used ..." text.
    public var detail: String?
    /// nil means Mole did not report a size ("would clean").
    public var bytes: Int64?
    public var count: Int?
    /// Concrete paths this row covers. Clean uses these to build whitelist entries.
    public var paths: [String]
    /// false = shown for information only (needs sudo, skipped by Mole, protected).
    public var selectable: Bool
    /// Default tick state after a scan.
    public var selectedByDefault: Bool
    /// Short reason shown when not selectable, e.g. "Needs admin", "Skipped: in iCloud".
    public var note: String?

    public init(
        id: String, title: String, detail: String? = nil, bytes: Int64? = nil, count: Int? = nil,
        paths: [String] = [], selectable: Bool = true, selectedByDefault: Bool = true, note: String? = nil
    ) {
        self.id = id; self.title = title; self.detail = detail; self.bytes = bytes; self.count = count
        self.paths = paths; self.selectable = selectable; self.selectedByDefault = selectedByDefault; self.note = note
    }
}

/// A category of rows, e.g. "Browsers" or "Downloads".
public struct ScanGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var items: [ScanItem]

    public init(id: String, title: String, items: [ScanItem]) {
        self.id = id; self.title = title; self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

public struct ScanResult: Sendable {
    public var kind: JobKind
    public var groups: [ScanGroup]
    /// Mole's own reported total, when it prints one ("Potential space: 9.51GB").
    public var reportedTotalBytes: Int64?
    /// One-line notices to show above the list, e.g. "System caches need admin; skipped."
    public var notes: [String]
    public var scannedAt: Date

    public init(kind: JobKind, groups: [ScanGroup], reportedTotalBytes: Int64? = nil, notes: [String] = [], scannedAt: Date = .now) {
        self.kind = kind; self.groups = groups; self.reportedTotalBytes = reportedTotalBytes; self.notes = notes; self.scannedAt = scannedAt
    }

    public var allItems: [ScanItem] { groups.flatMap(\.items) }
    public var defaultSelection: Set<ScanItem.ID> {
        Set(allItems.filter { $0.selectable && $0.selectedByDefault }.map(\.id))
    }
}

public struct RunResult: Sendable {
    public var freedBytes: Int64?
    public var itemCount: Int?
    /// Human-readable failures or skips Mole reported.
    public var problems: [String]
    public var exitCode: Int32
    public var log: String

    public init(freedBytes: Int64? = nil, itemCount: Int? = nil, problems: [String] = [], exitCode: Int32, log: String) {
        self.freedBytes = freedBytes; self.itemCount = itemCount; self.problems = problems; self.exitCode = exitCode; self.log = log
    }
}

public enum JobEvent: Sendable {
    /// A cleaned-up line of Mole output (ANSI stripped) for the live log.
    case line(String)
    /// Short status for the progress label, e.g. "Cleaning Browsers".
    case status(String)
    case finished(RunResult)
}

public protocol MoleJob: Sendable {
    var kind: JobKind { get }
    /// Read-only preview. Must only ever run Mole with --dry-run (or --list).
    func scan() async throws -> ScanResult
    /// Real run, limited to `selection`. Items not in `selection` must be kept.
    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error>
}

public enum BurrowError: Error, LocalizedError, Sendable {
    case moleNotFound
    case unsupportedMoleVersion(String)
    case parseFailed(String)
    /// The TUI showed a different selection than requested; nothing was confirmed.
    case selectionMismatch(expected: String, actual: String)
    case timeout(String)
    case processFailed(exitCode: Int32, output: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .moleNotFound: "Mole isn't installed. Install it with: brew install mole"
        case .unsupportedMoleVersion(let v): "Burrow was built for Mole 1.59. You have \(v)."
        case .parseFailed(let what): "Couldn't read Mole's output (\(what))."
        case .selectionMismatch(let e, let a): "Stopped before cleaning: expected \(e) selected, Mole showed \(a). Nothing was removed."
        case .timeout(let what): "Mole stopped responding (\(what))."
        case .processFailed(let code, _): "Mole exited with code \(code)."
        case .cancelled: "Cancelled."
        }
    }
}

public enum ByteSize {
    /// Parses Mole sizes: "1.20GB", "642.2MB", "4KB", "0B", "98.3MB+". Decimal units (1 KB = 1000 B), as Mole prints.
    public static func parse(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, mult) in units where s.uppercased().hasSuffix(suffix) {
            guard let n = Double(s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64(n * mult)
        }
        return nil
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
