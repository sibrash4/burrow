// One set of rules for "may this path be trashed?", used by the scanners and re-checked right before each removal.
// Anything that fails a rule is reported and skipped. Nothing here deletes.

import Foundation

public struct SafetyGate: Sendable {
    public let config: AILeftoversConfig
    /// Working directories of running processes, captured at scan time and refreshed before run.
    public let cwds: [String]

    public init(config: AILeftoversConfig, cwds: [String]) {
        self.config = config
        self.cwds = cwds
    }

    /// Folders the job may ever remove from, relative to home. Anything outside these is refused.
    public static let allowedRoots = [
        ".claude/projects",
        ".claude/file-history",
        ".claude/shell-snapshots",
        ".codex/sessions",
        ".cache/huggingface/hub",
    ]

    /// Paths that are never touched, even inside an allowed root.
    public static let protectedRoots = [
        ".codex/plugins",
        ".cache/codex-runtimes",
        ".claude/plugins",
    ]

    public static let protectedExtensions: Set<String> = ["sqlite", "sqlite3", "db", "sqlite-wal", "sqlite-shm"]
    public static let protectedNames: Set<String> = ["settings.json", "settings.local.json", "config.toml", "auth.json", "credentials", "credentials.json"]

    /// Returns why `path` must not be removed, or nil when the path passes every rule.
    public func blockReason(for path: String) -> String? {
        let p = PathCheck.normalized(path)
        let home = PathCheck.normalized(config.home.path)

        guard Self.allowedRoots.contains(where: { PathCheck.isInside(p, home + "/" + $0) }) else {
            return "Outside the folders this job may touch"
        }
        if Self.protectedRoots.contains(where: { PathCheck.isInside(p, home + "/" + $0) }) {
            return "Protected folder"
        }
        let url = URL(fileURLWithPath: p)
        let name = url.lastPathComponent.lowercased()
        if Self.protectedExtensions.contains(url.pathExtension.lowercased()) {
            return "Database file"
        }
        if Self.protectedNames.contains(name) || name.contains("auth") || name.contains("credential") {
            return "Config or credential file"
        }
        guard FileManager.default.fileExists(atPath: p) else {
            return "No longer exists"
        }
        if cwds.contains(where: { PathCheck.isInside($0, p) }) {
            return "In use by a running process"
        }
        return nil
    }

    /// Age rule for a single path: its newest modification must be older than the cutoff.
    public func ageBlockReason(for path: String) -> String? {
        let stats = FolderStats.measure(URL(fileURLWithPath: PathCheck.normalized(path)))
        guard let newest = stats.newestModified else { return "Could not read modification date" }
        return newest > config.cutoff ? "Changed recently (within the age threshold)" : nil
    }
}
