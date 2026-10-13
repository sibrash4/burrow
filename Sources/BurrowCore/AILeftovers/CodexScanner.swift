// Codex leftovers: old session files, one row per month. Also an information-only row for Codex runtimes,
// which Codex is using and which this job never touches.

import Foundation

public enum CodexScanner {
    public static func scanGroup(config: AILeftoversConfig, gate: SafetyGate) -> ScanGroup? {
        var items = sessionItems(config: config, gate: gate)
        if let runtime = runtimeInfoItem(config: config) {
            items.append(runtime)
        }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "codex", title: "Codex", items: items)
    }

    /// Files under sessions/YYYY/MM/DD/, grouped by YYYY/MM. Only files older than the threshold are offered.
    static func sessionItems(config: AILeftoversConfig, gate: SafetyGate) -> [ScanItem] {
        let fm = FileManager.default
        let sessions = config.url(".codex/sessions")
        var items: [ScanItem] = []
        for year in subdirectories(of: sessions) {
            for month in subdirectories(of: year) {
                var paths: [String] = []
                var bytes: Int64 = 0
                for day in subdirectories(of: month) {
                    let files = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    for file in files {
                        let path = PathCheck.normalized(file.path)
                        guard gate.blockReason(for: path) == nil, gate.ageBlockReason(for: path) == nil else { continue }
                        paths.append(path)
                        bytes += FolderStats.measure(file).bytes
                    }
                }
                guard !paths.isEmpty else { continue }
                let label = "\(year.lastPathComponent)-\(month.lastPathComponent)"
                items.append(ScanItem(
                    id: "codex-sessions:\(label)",
                    title: "Codex sessions \(label)",
                    detail: month.path,
                    bytes: bytes,
                    count: paths.count,
                    paths: paths,
                    selectable: true,
                    selectedByDefault: false,
                    note: "Needed to resume Codex sessions"
                ))
            }
        }
        return items
    }

    /// Information only: Codex is using this folder. Never selectable, never removed.
    static func runtimeInfoItem(config: AILeftoversConfig) -> ScanItem? {
        let dir = config.url(".cache/codex-runtimes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return ScanItem(
            id: "codex-runtimes",
            title: "Codex runtimes",
            detail: dir.path,
            bytes: FolderStats.measure(dir).bytes,
            paths: [],
            selectable: false,
            selectedByDefault: false,
            note: "In use by Codex"
        )
    }

    /// Sorted child directories whose names look like date parts (digits only).
    static func subdirectories(of dir: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { url in
                let name = url.lastPathComponent
                return !name.isEmpty && name.allSatisfy(\.isNumber)
                    && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
