// Model caches: Hugging Face hub models (removable, one row per model) and Ollama / LM Studio model folders
// (information only: the owning app removes them, so Burrow shows the size and the command to use).

import Foundation

public enum ModelCacheScanner {
    public static func scanGroup(config: AILeftoversConfig, gate: SafetyGate) -> ScanGroup? {
        var items = huggingFaceItems(config: config, gate: gate)
        if let ollama = infoItem(
            id: "ollama-models", title: "Ollama models", dir: config.url(".ollama/models"),
            note: "Remove with: ollama rm <model>"
        ) { items.append(ollama) }
        if let lm = infoItem(
            id: "lmstudio-models", title: "LM Studio models", dir: config.url(".lmstudio/models"),
            note: "Remove in LM Studio"
        ) { items.append(lm) }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "model-caches", title: "Model caches", items: items)
    }

    /// One row per `models--*` folder in the Hugging Face hub cache.
    static func huggingFaceItems(config: AILeftoversConfig, gate: SafetyGate) -> [ScanItem] {
        let hub = config.url(".cache/huggingface/hub")
        let children = (try? FileManager.default.contentsOfDirectory(at: hub, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var items: [ScanItem] = []
        for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.lastPathComponent.hasPrefix("models--") {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let path = PathCheck.normalized(dir.path)
            let stats = FolderStats.measure(dir)
            let reason: String?
            if gate.blockReason(for: path) != nil {
                reason = gate.blockReason(for: path)
            } else if gate.ageBlockReason(for: path) != nil {
                reason = gate.ageBlockReason(for: path)
            } else {
                reason = nil
            }
            let lastUsed = lastAccess(dir).map { " · last used \(dateText($0))" } ?? ""
            let title = modelName(forFolder: dir.lastPathComponent)
            items.append(ScanItem(
                id: "hf:\(dir.lastPathComponent)",
                title: title,
                detail: dir.path + lastUsed,
                bytes: stats.bytes,
                paths: [path],
                selectable: reason == nil,
                selectedByDefault: false,
                note: reason ?? "May be used by an app on this Mac"
            ))
        }
        return items
    }

    /// Information-only row for a folder owned by another app. Never selectable.
    static func infoItem(id: String, title: String, dir: URL, note: String) -> ScanItem? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return ScanItem(
            id: id, title: title, detail: dir.path, bytes: FolderStats.measure(dir).bytes,
            paths: [], selectable: false, selectedByDefault: false, note: note
        )
    }

    /// "models--org--name" → "org/name".
    public static func modelName(forFolder folder: String) -> String {
        let trimmed = folder.hasPrefix("models--") ? String(folder.dropFirst("models--".count)) : folder
        return trimmed.replacingOccurrences(of: "--", with: "/")
    }

    /// Newest content access date under `root`, when the file system reports one.
    static func lastAccess(_ root: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return nil
        }
        var newest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let date = values.contentAccessDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
