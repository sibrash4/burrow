import Foundation

public enum MenuKind: Sendable {
    case installer, purge
}

public struct MenuHeader: Equatable, Sendable {
    /// 1-based cursor position. Mole prints "[3/23]" only when the list needs scrolling.
    public var cursorPosition: Int?
    public var total: Int?
    public var selectedCount: Int
    public var selectedSize: String

    public init(cursorPosition: Int? = nil, total: Int? = nil, selectedCount: Int, selectedSize: String) {
        self.cursorPosition = cursorPosition; self.total = total
        self.selectedCount = selectedCount; self.selectedSize = selectedSize
    }
}

/// One visible menu row. For installers `name` is the file name and `location` is "Downloads".
/// For purge `name` is the artifact ("node_modules") and `location` is the project folder.
public struct MenuRow: Equatable, Sendable {
    public var isCursor: Bool
    public var isSelected: Bool
    public var name: String
    public var size: String
    public var location: String
    /// Purge only: "3d", "2mo", "<7d".
    public var age: String?

    public init(isCursor: Bool, isSelected: Bool, name: String, size: String, location: String, age: String? = nil) {
        self.isCursor = isCursor; self.isSelected = isSelected; self.name = name
        self.size = size; self.location = location; self.age = age
    }
}

/// A parsed screen of Mole's interactive selection menu (`mo installer`, `mo purge`).
public struct MenuFrame: Equatable, Sendable {
    public var kind: MenuKind
    public var header: MenuHeader
    public var rows: [MenuRow]
    /// Purge shows the full path of the focused row on a "Path:" line.
    public var cursorPath: String?
    /// True once the footer (key hints) is on screen, i.e. Mole finished drawing this frame.
    public var isComplete: Bool

    public static func installerKey(name: String, location: String) -> String { "\(name) | \(location)" }

    public var totalRows: Int { header.total ?? rows.count }
    public var cursorRow: MenuRow? { rows.first(where: \.isCursor) }

    /// 0-based position of the focused row in the whole list.
    public var cursorIndex: Int? {
        if let position = header.cursorPosition { return position - 1 }
        return rows.firstIndex(where: \.isCursor)
    }

    /// Identity of the focused row. Installers: "name | location". Purge: the full path.
    public var cursorKey: String? {
        guard let row = cursorRow else { return nil }
        switch kind {
        case .installer: return Self.installerKey(name: row.name, location: row.location)
        case .purge: return cursorPath
        }
    }

    public static func parse(_ text: String) -> MenuFrame? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let headerIndex = lines.lastIndex(where: { $0.contains(installerTitle) || $0.contains(purgeTitle) }) else { return nil }
        let headerLine = lines[headerIndex]
        let kind: MenuKind = headerLine.contains(installerTitle) ? .installer : .purge

        let header: MenuHeader
        switch kind {
        case .installer:
            guard let m = headerLine.firstMatch(of: #/Select Installers to Remove(?: \[(\d+)/(\d+)\])? , (.+?), (\d+) selected/#) else { return nil }
            header = MenuHeader(cursorPosition: m.1.flatMap { Int($0) }, total: m.2.flatMap { Int($0) },
                                selectedCount: Int(m.4) ?? 0, selectedSize: String(m.3))
        case .purge:
            guard let m = headerLine.firstMatch(of: #/Select Artifacts to Purge(?: \[(\d+)/(\d+)\])?/#),
                  headerIndex + 1 < lines.count,
                  let sub = lines[headerIndex + 1].firstMatch(of: #/^(.+?), (\d+) selected/#) else { return nil }
            header = MenuHeader(cursorPosition: m.1.flatMap { Int($0) }, total: m.2.flatMap { Int($0) },
                                selectedCount: Int(sub.2) ?? 0, selectedSize: String(sub.1))
        }

        var rows: [MenuRow] = []
        var cursorPath: String?
        var sawFooter = false
        for line in lines[(headerIndex + 1)...] {
            if let row = parseRow(line, kind: kind) {
                rows.append(row)
            } else if line.hasPrefix("Path:") {
                cursorPath = line.dropFirst("Path:".count).trimmingCharacters(in: .whitespaces)
            } else if line.contains("Quit") || line.hasSuffix("| Q") {
                sawFooter = true
            }
        }
        return MenuFrame(kind: kind, header: header, rows: rows, cursorPath: cursorPath, isComplete: sawFooter)
    }

    static let installerTitle = "Select Installers to Remove"
    static let purgeTitle = "Select Artifacts to Purge"

    private static func parseRow(_ line: String, kind: MenuKind) -> MenuRow? {
        var s = Substring(line)
        var isCursor = false
        if s.first == "➤" {
            isCursor = true
            s = s.dropFirst().drop(while: \.isWhitespace)
        }
        guard let box = s.first, box == "○" || box == "●" else { return nil }
        s = s.dropFirst().drop(while: \.isWhitespace)
        switch kind {
        case .installer:
            guard let m = s.wholeMatch(of: #/(.+?)\s+(\d[\d.,]*\s?[KMGT]?B|unknown)\s+\|\s+(.+)/#) else { return nil }
            return MenuRow(isCursor: isCursor, isSelected: box == "●", name: String(m.1), size: String(m.2), location: String(m.3))
        case .purge:
            if let marker = s.first, "─┌├└".contains(marker) { s = s.dropFirst().drop(while: \.isWhitespace) }
            guard let m = s.wholeMatch(of: #/(.+?)\s+(\d[\d.,]*\s?[KMGT]?B|unknown)\s+\|\s+(.+?)(?:\s+\|\s+(\S+))?/#) else { return nil }
            return MenuRow(isCursor: isCursor, isSelected: box == "●", name: String(m.3), size: String(m.2),
                           location: String(m.1), age: m.4.map(String.init))
        }
    }
}
