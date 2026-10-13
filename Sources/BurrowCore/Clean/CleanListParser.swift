import Foundation

/// `~/.config/mole/clean-list.txt`: every path `mo clean` would remove, grouped by category.
public struct CleanList: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        /// nil when Mole printed "size unknown".
        public var bytes: Int64?
        public var itemCount: Int
        /// Set when a measured ancestor already includes this entry's bytes.
        public var countedUnder: String?

        /// Bytes that count toward totals. Entries counted under another path add nothing.
        public var countedBytes: Int64 { countedUnder == nil ? (bytes ?? 0) : 0 }
    }

    public struct Section: Sendable, Equatable {
        public var name: String
        public var entries: [Entry]
    }

    public var sections: [Section] = []
    public var allEntries: [Entry] { sections.flatMap(\.entries) }
    public var allPaths: Set<String> { Set(allEntries.map(\.path)) }

    /// Sum of entries that are not counted under another path (Mole's own "Potential space").
    public var totalBytes: Int64 { allEntries.reduce(0) { $0 + $1.countedBytes } }
    public var summaryBytes: Int64?
    public var summaryItems: Int?
}

public enum CleanListParser {
    private static let separator = "  # "

    public static func parse(_ text: String) -> CleanList {
        var list = CleanList()
        for rawLine in TerminalText.lines(text) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") {
                parseSummary(line, into: &list)
            } else if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                list.sections.append(.init(name: String(line.dropFirst(4).dropLast(4)), entries: []))
            } else if let entry = parseEntry(line) {
                if list.sections.isEmpty { list.sections.append(.init(name: "Uncategorized", entries: [])) }
                list.sections[list.sections.count - 1].entries.append(entry)
            }
        }
        return list
    }

    static func parseEntry(_ line: String) -> CleanList.Entry? {
        guard let range = line.range(of: separator, options: .backwards), line.hasPrefix("/") else { return nil }
        let path = String(line[..<range.lowerBound])
        var meta = String(line[range.upperBound...])
        var countedUnder: String?
        if let marker = meta.range(of: ", counted under ") {
            countedUnder = String(meta[marker.upperBound...])
            meta = String(meta[..<marker.lowerBound])
        }
        let tokens = meta.components(separatedBy: ", ")
        var entry = CleanList.Entry(path: path, bytes: nil, itemCount: 1, countedUnder: countedUnder)
        entry.bytes = tokens.first.flatMap { ByteSize.parse($0) }
        for token in tokens.dropFirst() {
            if token.hasSuffix(" items"), let n = Int(token.dropLast(" items".count)) { entry.itemCount = n }
        }
        return entry
    }

    private static func parseSummary(_ line: String, into list: inout CleanList) {
        if let value = line.value(after: "# Potential cleanup:") {
            list.summaryBytes = ByteSize.parse(value.strip(prefix: "At least ") ?? value)
        } else if let value = line.value(after: "# Items:") {
            list.summaryItems = Int(value)
        }
    }
}
