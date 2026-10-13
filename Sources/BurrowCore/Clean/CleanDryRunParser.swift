import Foundation

/// What `mo clean --dry-run` prints: categories with one line per cleanup, plus notices and totals.
public struct CleanDryRun: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// "Chrome cache · 642.2MB dry": paths are listed in clean-list.txt.
            case measured
            /// "npm cache · would clean": a tool's own command, no paths.
            case wouldClean
            /// "Homebrew · would cleanup"
            case wouldCleanup
            /// "Trash · would empty, 58 items"
            case wouldEmpty
            /// "... would skip (whitelist)" or "skipped (whitelist)"
            case wouldSkip
        }

        public var label: String
        public var qualifier: String?
        public var bytes: Int64?
        public var count: Int?
        public var protectedCount: Int?
        public var kind: Kind
    }

    /// "⊙ Mail data · 1.08GB · ~/Library/Mail": shown by Mole for review, never cleaned by `mo clean`.
    public struct Info: Sendable, Equatable {
        public var label: String
        public var bytes: Int64?
        public var detail: String?
    }

    public struct Category: Sendable, Equatable {
        public var name: String
        public var rows: [Row] = []
        public var infos: [Info] = []
        public var warnings: [String] = []
        public var nothingToClean = false
    }

    public var categories: [Category] = []
    /// "◎" lines before the first category, e.g. the sudo notice.
    public var notes: [String] = []
    public var whitelistSummary: String?
    public var whitelistPatterns: [String] = []
    public var freeSpaceBytes: Int64?
    public var potentialBytes: Int64?
    /// "At least 9.51GB": some items could not be sized.
    public var potentialIsPartial = false
    public var itemCount: Int?
    public var categoryCount: Int?
    public var listPath: String?
    public var heading: String?

    public var completed: Bool { heading?.hasPrefix("Dry run complete") ?? false }
}

public enum CleanDryRunParser {
    public static func parse(_ text: String) -> CleanDryRun {
        var result = CleanDryRun()
        for rawLine in TerminalText.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let name = line.strip(prefix: "➤ ") {
                result.categories.append(.init(name: name))
            } else if let rest = line.strip(prefix: "→ ") {
                append(row: parseRow(rest), to: &result)
            } else if let rest = line.strip(prefix: "⊙ ") {
                append(info: parseInfo(rest), to: &result)
            } else if let rest = line.strip(prefix: "◎ ") {
                if result.categories.isEmpty { result.notes.append(rest) } else { result.categories[result.categories.count - 1].warnings.append(rest) }
            } else if let rest = line.strip(prefix: "↳ ") {
                result.whitelistPatterns.append(rest)
            } else if let rest = line.strip(prefix: "✓ ") {
                parseCheck(rest, into: &result)
            } else if line.contains("Free space:"), let value = line.value(after: "Free space:") {
                result.freeSpaceBytes = ByteSize.parse(value.components(separatedBy: " ").first ?? "")
            } else if line.hasPrefix("Potential space:") {
                parsePotential(line, into: &result)
            } else if let path = line.strip(prefix: "Detailed file list:") {
                result.listPath = path.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Dry run ") {
                result.heading = line
            }
        }
        return result
    }

    static func parseRow(_ text: String) -> CleanDryRun.Row {
        let parts = text.components(separatedBy: " · ")
        let label: String
        var qualifier: String?
        let tokens: [String]
        if parts.count == 1 {
            // "Chrome Service Worker, would clean 1.04GB, 0 protected"
            let pieces = text.components(separatedBy: ", ")
            label = pieces[0]
            tokens = Array(pieces.dropFirst())
        } else {
            label = parts[0]
            if parts.count > 2 { qualifier = parts[1..<(parts.count - 1)].joined(separator: " · ") }
            tokens = parts[parts.count - 1].components(separatedBy: ", ")
        }

        var row = CleanDryRun.Row(label: label, qualifier: qualifier, kind: .measured)
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("would empty") {
                row.kind = .wouldEmpty
            } else if t.hasPrefix("would cleanup") {
                row.kind = .wouldCleanup
            } else if t.hasPrefix("would clean") {
                row.kind = .wouldClean
                let rest = String(t.dropFirst("would clean".count)).trimmingCharacters(in: .whitespaces)
                if let bytes = ByteSize.parse(rest) { row.bytes = bytes } else if let n = Int(rest) { row.count = n }
            } else if t.hasPrefix("would skip") || t.hasPrefix("skipped (whitelist)") {
                row.kind = .wouldSkip
            } else if let n = t.leadingInt(suffix: " protected") {
                row.protectedCount = n
            } else if let n = t.leadingCount() {
                row.count = n
            } else {
                let sized = t.hasSuffix(" dry") ? String(t.dropLast(4)) : t
                if let bytes = ByteSize.parse(sized) { row.bytes = bytes }
            }
        }
        return row
    }

    private static func parseInfo(_ text: String) -> CleanDryRun.Info {
        let parts = text.components(separatedBy: " · ")
        var info = CleanDryRun.Info(label: parts[0])
        for part in parts.dropFirst() {
            let sizeToken = part.components(separatedBy: ", ").last ?? part
            if info.bytes == nil, let bytes = ByteSize.parse(sizeToken) {
                info.bytes = bytes
            } else if info.bytes != nil || ByteSize.parse(sizeToken) == nil {
                info.detail = [info.detail, part].compactMap { $0 }.joined(separator: " · ")
            }
        }
        return info
    }

    private static func parseCheck(_ text: String, into result: inout CleanDryRun) {
        if let summary = text.strip(prefix: "Whitelist:") {
            result.whitelistSummary = summary.trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("Nothing to clean") {
            if !result.categories.isEmpty { result.categories[result.categories.count - 1].nothingToClean = true }
        } else if text.contains("(whitelist)"), !result.categories.isEmpty {
            append(row: parseRow(text), to: &result)
        }
    }

    private static func parsePotential(_ line: String, into result: inout CleanDryRun) {
        for field in line.components(separatedBy: " | ") {
            if var value = field.strip(prefix: "Potential space:")?.trimmingCharacters(in: .whitespaces) {
                if let rest = value.strip(prefix: "At least ") {
                    result.potentialIsPartial = true
                    value = rest
                }
                result.potentialBytes = ByteSize.parse(value)
            } else if let value = field.strip(prefix: "Items:") {
                result.itemCount = Int(value.trimmingCharacters(in: .whitespaces))
            } else if let value = field.strip(prefix: "Categories:") {
                result.categoryCount = Int(value.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private static func append(row: CleanDryRun.Row, to result: inout CleanDryRun) {
        guard !result.categories.isEmpty else { return }
        result.categories[result.categories.count - 1].rows.append(row)
    }

    private static func append(info: CleanDryRun.Info, to result: inout CleanDryRun) {
        guard !result.categories.isEmpty else { return }
        result.categories[result.categories.count - 1].infos.append(info)
    }
}

/// Small text helpers shared by the Clean parsers.
enum TerminalText {
    /// Splits terminal output into lines. Carriage returns (spinner redraws) keep only the last redraw.
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in line.components(separatedBy: "\r").last ?? line }
    }
}

extension String {
    func strip(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    func value(after marker: String) -> String? {
        guard let range = range(of: marker) else { return nil }
        return String(self[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// "17 items" or "5 projects" -> 17 / 5. Sizes like "1.20GB" return nil.
    func leadingCount() -> Int? {
        let pieces = split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, let n = Int(pieces[0]), pieces[1].allSatisfy({ $0.isLetter }) else { return nil }
        return n
    }

    func leadingInt(suffix: String) -> Int? {
        guard hasSuffix(suffix) else { return nil }
        return Int(dropLast(suffix.count))
    }
}
