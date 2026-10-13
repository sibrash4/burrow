import Foundation

public enum InstallerParser {
    /// Builds the scan result from the menu rows Mole listed, grouped by location in menu order.
    public static func scanResult(entries: [MenuEntry], now: Date = .now) -> ScanResult {
        var keyCounts: [String: Int] = [:]
        for e in entries { keyCounts[e.key, default: 0] += 1 }

        var order: [String] = []
        var itemsByLocation: [String: [ScanItem]] = [:]
        for e in entries {
            let row = e.row
            let duplicate = (keyCounts[e.key] ?? 0) > 1
            // Mole's installer menu starts with nothing ticked, so Burrow does too.
            let item = ScanItem(
                id: e.key, title: row.name, detail: row.location, bytes: ByteSize.parse(row.size),
                selectable: !duplicate, selectedByDefault: false,
                note: duplicate ? "Another installer has the same name here" : nil)
            if itemsByLocation[row.location] == nil { order.append(row.location) }
            itemsByLocation[row.location, default: []].append(item)
        }
        let groups = order.map { ScanGroup(id: $0, title: $0, items: itemsByLocation[$0] ?? []) }
        return ScanResult(kind: .installers, groups: groups, scannedAt: now)
    }

    /// Reads the rows of one printed menu frame (ANSI already stripped). Shows only the first page.
    public static func entries(fromFrame text: String) -> [MenuEntry] {
        guard let frame = MenuFrame.parse(text), frame.kind == .installer else { return [] }
        return frame.rows.map { MenuEntry(key: MenuFrame.installerKey(name: $0.name, location: $0.location), row: $0) }
    }

    /// "Removed 3 installers, freed 12.50MB" and the failure lines after it.
    public static func summarize(log: String, exitCode: Int32) -> RunResult {
        var freed: Int64?
        var count: Int?
        var problems: [String] = []
        for line in MenuSession.logLines(log) {
            if let m = line.firstMatch(of: #/(?:Removed|Would remove) (\d+) installers?, (?:freed|free) ([\d.]+)MB/#) {
                count = Int(m.1)
                // Mole divides KiB by 1024 and prints "MB".
                freed = Double(m.2).map { Int64($0 * 1_048_576) }
            } else if line.hasPrefix("Failed to remove") || line.hasPrefix("◎") {
                problems.append(line.hasPrefix("◎") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line)
            }
        }
        return RunResult(freedBytes: freed, itemCount: count, problems: problems, exitCode: exitCode, log: log)
    }

    /// Checks the "Files to be removed" list and the "Delete N installers" prompt against the request.
    /// Returns nil when they agree, otherwise what Mole showed.
    static func checkConfirm(screen: String, wanted: [ScanItem]) -> String? {
        let lines = MenuSession.logLines(screen)
        guard let prompt = lines.compactMap({ $0.firstMatch(of: #/Delete (\d+) installers?, /#) }).last,
              let count = Int(prompt.1) else { return "no confirm prompt" }
        var sizes: [Int64] = []
        for line in lines {
            if let m = line.firstMatch(of: #/^✓ .+ , (\S+)$/#), let bytes = ByteSize.parse(String(m.1)) { sizes.append(bytes) }
        }
        guard count == wanted.count else { return "\(count) installers" }
        guard sizes.count == wanted.count, sizes.sorted() == wanted.compactMap(\.bytes).sorted() else {
            return "different files than selected"
        }
        return nil
    }
}
