// Claude Code leftovers: old transcripts (per project), old file-history and shell-snapshot entries.

import Foundation

public enum ClaudeScanner {
    public static func scanGroup(config: AILeftoversConfig, gate: SafetyGate) -> ScanGroup? {
        var items: [ScanItem] = []
        items += transcriptItems(config: config, gate: gate)
        if let item = entryItem(
            id: "claude-file-history", title: "Claude Code file history",
            dir: config.url(".claude/file-history"), config: config, gate: gate
        ) { items.append(item) }
        if let item = entryItem(
            id: "claude-shell-snapshots", title: "Claude Code shell snapshots",
            dir: config.url(".claude/shell-snapshots"), config: config, gate: gate
        ) { items.append(item) }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "claude-code", title: "Claude Code", items: items)
    }

    /// One row per project folder under ~/.claude/projects, covering its old .jsonl transcripts.
    static func transcriptItems(config: AILeftoversConfig, gate: SafetyGate) -> [ScanItem] {
        let fm = FileManager.default
        let projectsDir = config.url(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var items: [ScanItem] = []
        for project in projects.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey], options: [.skipsHiddenFiles])) ?? []
            var paths: [String] = []
            var bytes: Int64 = 0
            for file in files where file.pathExtension == "jsonl" {
                let path = PathCheck.normalized(file.path)
                // Re-use the gate for the path rules; the age rule is applied here per file.
                guard gate.blockReason(for: path) == nil, gate.ageBlockReason(for: path) == nil else { continue }
                paths.append(path)
                bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            guard !paths.isEmpty else { continue }
            // An open session keeps its whole project folder, so the row is shown but cannot be ticked.
            let inUse = projectInUseReason(folder: project.path, cwds: gate.cwds, now: config.now)
            items.append(ScanItem(
                id: "claude-transcripts:\(project.lastPathComponent)",
                title: "Transcripts: \(displayPath(forProjectFolder: project.lastPathComponent, config: config))",
                detail: project.path,
                bytes: bytes,
                count: paths.count,
                paths: paths,
                selectable: inUse == nil,
                selectedByDefault: false,
                note: inUse ?? "Needed for claude --resume"
            ))
        }
        return items
    }

    /// Why a Claude project folder must not be trashed right now, or nil. A running process whose cwd is the
    /// project folder or inside it, or any transcript written in the last 24 hours, means it may be open.
    static func projectInUseReason(folder: String, cwds: [String], now: Date) -> String? {
        let folderKey = encodedKey(URL(fileURLWithPath: folder).lastPathComponent)
        let inUse = cwds.contains { cwd in
            let key = encodedKey(cwd)
            return key == folderKey || key.hasPrefix(folderKey + "-")
        }
        if inUse { return "In use by a running process" }

        let since = now.addingTimeInterval(-24 * 60 * 60)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let changedToday = files.contains { file in
            guard file.pathExtension == "jsonl",
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return modified > since
        }
        return changedToday ? "Changed in the last 24 hours, so it may be open" : nil
    }

    /// Claude Code names a project folder after its path with every symbol turned into "-". That name cannot be
    /// decoded reliably (folder names contain "-"), so the cwd is encoded the same way and compared instead.
    static func encodedKey(_ path: String) -> String {
        // ASCII letters and digits only, as Claude does: a non-ASCII letter in a folder name also becomes "-".
        String(path.unicodeScalars.map { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) ? Character(scalar) : "-"
        })
    }

    /// One row covering the old entries directly inside `dir`. nil when there are none.
    static func entryItem(id: String, title: String, dir: URL, config: AILeftoversConfig, gate: SafetyGate) -> ScanItem? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var paths: [String] = []
        var bytes: Int64 = 0
        for entry in entries {
            let path = PathCheck.normalized(entry.path)
            guard gate.blockReason(for: path) == nil, gate.ageBlockReason(for: path) == nil else { continue }
            paths.append(path)
            bytes += FolderStats.measure(entry).bytes
        }
        guard !paths.isEmpty else { return nil }
        return ScanItem(
            id: id, title: title, detail: dir.path, bytes: bytes, count: paths.count,
            paths: paths, selectable: true, selectedByDefault: true
        )
    }

    /// Turns "-Users-x-dev-Foo" into "~/dev/Foo" when the folder belongs to this home, otherwise a best-effort decode.
    public static func displayPath(forProjectFolder folder: String, config: AILeftoversConfig) -> String {
        let encodedHome = PathCheck.normalized(config.home.path).replacingOccurrences(of: "/", with: "-")
        if folder == encodedHome {
            return "~"
        }
        if folder.hasPrefix(encodedHome + "-") {
            let rest = folder.dropFirst(encodedHome.count + 1).replacingOccurrences(of: "-", with: "/")
            return "~/" + rest
        }
        return "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/")
    }
}
