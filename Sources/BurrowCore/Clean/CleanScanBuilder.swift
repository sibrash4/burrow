import Foundation

/// Turns Mole's dry-run text and clean-list.txt into the rows the UI shows.
public enum CleanScanBuilder {
    static let idPrefix = "clean:"
    static let commandPrefix = "clean:cmd:"
    static let infoPrefix = "clean:info:"
    static let emptyPrefix = "clean:empty:"
    static let trashID = "clean:.Trash"

    public static func build(dryRun: CleanDryRun, list: CleanList, home: String, now: Date = .now) -> ScanResult {
        var accumulators: [String: Accumulator] = [:]
        var order: [String] = []

        for section in list.sections {
            for entry in section.entries {
                let owner = CleanOwnerResolver.resolve(path: entry.countedUnder ?? entry.path, home: home)
                if accumulators[owner.key] == nil {
                    accumulators[owner.key] = Accumulator(owner: owner, group: section.name)
                    order.append(owner.key)
                }
                accumulators[owner.key]?.add(entry)
            }
        }

        var itemsByGroup: [String: [ScanItem]] = [:]
        var emptiesByGroup: [String: [Accumulator]] = [:]
        for key in order {
            guard let acc = accumulators[key] else { continue }
            if acc.isEmpty {
                emptiesByGroup[acc.group, default: []].append(acc)
            } else {
                itemsByGroup[acc.group, default: []].append(item(from: acc, home: home))
            }
        }
        for (group, empties) in emptiesByGroup {
            itemsByGroup[group, default: []].append(emptyItem(group: group, empties: empties))
        }

        let knownPaths = Set(list.allPaths)
        for category in dryRun.categories {
            for row in category.rows where row.kind == .wouldClean || row.kind == .wouldCleanup {
                guard row.bytes == nil, row.count == nil else { continue }
                if let item = commandItem(row: row, home: home, knownPaths: knownPaths) {
                    itemsByGroup[category.name, default: []].append(item)
                }
            }
            for info in category.infos {
                itemsByGroup[category.name, default: []].append(infoItem(info, category: category.name))
            }
        }

        var groupNames = dryRun.categories.map(\.name)
        for section in list.sections where !groupNames.contains(section.name) { groupNames.append(section.name) }

        var groups: [ScanGroup] = groupNames.compactMap { name in
            guard let items = itemsByGroup[name], !items.isEmpty else { return nil }
            return ScanGroup(id: idPrefix + "group:" + name, title: name, items: sorted(items))
        }
        disambiguateTitles(in: &groups)

        return ScanResult(
            kind: .clean,
            groups: groups,
            reportedTotalBytes: dryRun.potentialBytes ?? list.summaryBytes,
            notes: notes(from: dryRun),
            scannedAt: now
        )
    }

    // MARK: Items

    private struct Accumulator {
        var owner: CleanOwner
        var group: String
        var bytes: Int64 = 0
        var count = 0
        var hasUnknownSize = false
        var paths: [String] = []

        init(owner: CleanOwner, group: String) {
            self.owner = owner
            self.group = group
        }

        mutating func add(_ entry: CleanList.Entry) {
            if !paths.contains(entry.path) { paths.append(entry.path) }
            guard entry.countedUnder == nil else { return }
            count += entry.itemCount
            if let b = entry.bytes { bytes += b } else { hasUnknownSize = true }
        }

        var isEmpty: Bool { bytes == 0 && !hasUnknownSize && !owner.alwaysCleaned && !owner.isTrash }
    }

    private static func item(from acc: Accumulator, home: String) -> ScanItem {
        let owner = acc.owner
        return ScanItem(
            id: idPrefix + owner.key,
            title: title(for: owner),
            detail: displayPath(owner.root, home: home),
            bytes: acc.bytes == 0 && acc.hasUnknownSize ? nil : acc.bytes,
            count: acc.count,
            paths: acc.paths,
            selectable: !owner.alwaysCleaned,
            // Mole empties the whole Trash at run time, including items added after the scan, and not for the
            // Trash row alone. So it is only ever removed when the user ticks it.
            selectedByDefault: !owner.isTrash,
            note: note(for: owner, pathCount: acc.paths.count)
        )
    }

    private static func note(for owner: CleanOwner, pathCount: Int) -> String? {
        if owner.alwaysCleaned { return "Always cleaned by Mole" }
        if owner.isTrash { return "Empties the Trash permanently (\(pathCount) \(pathCount == 1 ? "item" : "items"))" }
        return nil
    }

    private static func emptyItem(group: String, empties: [Accumulator]) -> ScanItem {
        let paths = empties.flatMap(\.paths)
        return ScanItem(
            id: emptyPrefix + group,
            title: "Empty folders and files",
            detail: "\(paths.count) empty \(paths.count == 1 ? "item" : "items")",
            bytes: 0,
            count: paths.count,
            paths: paths
        )
    }

    private static func commandItem(row: CleanDryRun.Row, home: String, knownPaths: Set<String>) -> ScanItem? {
        let id = commandPrefix + row.label.lowercased()
        guard let patterns = CleanToolCaches.patterns(forLabel: row.label, home: home) else {
            return ScanItem(
                id: id, title: row.label, detail: "Runs the tool's own cleanup command", paths: [],
                selectable: false, selectedByDefault: true, note: "Always cleaned by Mole"
            )
        }
        // The same folder is already a row (Homebrew): keep one switch for it.
        let folders = Set(patterns.map { $0.hasSuffix("/*") ? String($0.dropLast(2)) : $0 })
        if !folders.isDisjoint(with: knownPaths) { return nil }
        return ScanItem(id: id, title: row.label, detail: "Runs the tool's own cleanup command", paths: patterns)
    }

    private static func infoItem(_ info: CleanDryRun.Info, category: String) -> ScanItem {
        ScanItem(
            id: infoPrefix + category + ":" + info.label.lowercased(),
            title: info.label,
            detail: info.detail,
            bytes: info.bytes,
            paths: [],
            selectable: false,
            selectedByDefault: false,
            note: "For review only; mo clean does not remove this"
        )
    }

    /// Two rows can read alike ("Claude cache" under Caches and under Application Support).
    /// Add the folder name to those so the list stays unambiguous.
    private static func disambiguateTitles(in groups: inout [ScanGroup]) {
        var counts: [String: Int] = [:]
        for item in groups.flatMap(\.items) { counts[item.title, default: 0] += 1 }
        for g in groups.indices {
            for i in groups[g].items.indices {
                let item = groups[g].items[i]
                guard counts[item.title, default: 0] > 1, !item.id.hasPrefix(emptyPrefix),
                      let folder = item.detail?.split(separator: "/").last else { continue }
                groups[g].items[i].title = "\(item.title) (\(folder))"
            }
        }
    }

    private static func sorted(_ items: [ScanItem]) -> [ScanItem] {
        items.sorted { a, b in
            if a.id.hasPrefix(emptyPrefix) != b.id.hasPrefix(emptyPrefix) { return !a.id.hasPrefix(emptyPrefix) }
            if (a.bytes ?? -1) != (b.bytes ?? -1) { return (a.bytes ?? -1) > (b.bytes ?? -1) }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: Titles and notes

    private static func title(for owner: CleanOwner) -> String {
        if owner.fixedTitle { return owner.name }
        let suffix: String
        switch owner.kind {
        case .cache: suffix = "cache"
        case .logs: suffix = "logs"
        case .temp: suffix = "temp files"
        case .plain: return owner.name
        }
        let lowered = owner.name.lowercased()
        if lowered.hasSuffix(suffix) || (suffix == "cache" && lowered.contains("cache")) { return owner.name }
        return owner.name + " " + suffix
    }

    private static func displayPath(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(prefix + "/") ? "~" + path.dropFirst(prefix.count) : path
    }

    private static func notes(from dryRun: CleanDryRun) -> [String] {
        var notes: [String] = []
        for note in dryRun.notes + dryRun.categories.flatMap(\.warnings) {
            if note.hasPrefix("System caches need sudo") {
                notes.append("System caches need admin access and are skipped.")
            } else {
                notes.append(note)
            }
        }
        if dryRun.potentialIsPartial {
            notes.append("Some items could not be sized, so the total is a minimum.")
        }
        return notes
    }
}

/// Cleanups Mole runs with the tool's own command, so there are no paths in clean-list.txt.
/// Each default folder below is what Mole checks against the whitelist before running the command
/// (`clean_tool_cache` in lib/clean/dev.sh and lib/clean/brew.sh).
enum CleanToolCaches {
    static func patterns(forLabel label: String, home: String) -> [String]? {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        switch label.lowercased() {
        case "npm cache": return ["\(h)/.npm/_cacache/*"]
        case "pip cache": return ["\(h)/Library/Caches/pip/*"]
        case "uv cache": return ["\(h)/.cache/uv/*"]
        case "corepack cache": return ["\(h)/.cache/node/corepack/*"]
        case "github cli cache": return ["\(h)/.cache/gh"]
        case "bun cache": return ["\(h)/.bun/install/cache/*"]
        case "mise cache": return ["\(h)/Library/Caches/mise/*"]
        case "pnpm cache": return ["\(h)/Library/pnpm/store/*"]
        case "conda index/tarball/log caches": return ["\(h)/.conda/pkgs"]
        case "homebrew": return ["\(h)/Library/Caches/Homebrew"]
        case "nix garbage collection": return ["/nix/store"]
        default: return nil
        }
    }
}
