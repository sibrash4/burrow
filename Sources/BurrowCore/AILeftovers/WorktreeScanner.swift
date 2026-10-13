// Finds linked git worktrees under the usual code folders and decides whether each one is safe to remove.
// Read-only: only `git status`, `git log`, `git rev-parse`, `git for-each-ref`, `git symbolic-ref`.

import Foundation

public struct WorktreeAssessment: Sendable {
    public var path: String
    /// Main repository working directory, from the worktree's `.git` file.
    public var mainRepo: String?
    public var dirty: Bool
    /// True when some commit is not on an upstream, nor on any other branch. Also true when git could not tell.
    public var unpushed: Bool
    public var inUse: Bool
    public var inUseBy: String?
    public var bytes: Int64
    public var newestModified: Date?

    /// Reason this worktree must not be removed right now, or nil when it qualifies.
    public func blockReason(cutoff: Date) -> String? {
        if inUse { return inUseBy ?? "In use by a running process" }
        if dirty { return "Has uncommitted changes" }
        if unpushed { return "Commits not pushed or merged" }
        guard let newest = newestModified else { return "Could not read modification date" }
        if newest > cutoff { return "Changed recently (within the age threshold)" }
        return nil
    }
}

public struct WorktreeScanner: Sendable {
    public let config: AILeftoversConfig
    public let shell: ShellRunning

    /// Folders searched for linked worktrees, relative to home.
    public static let searchRoots = ["orca/workspaces", "dev", "Developer", "code", "src", "projects"]
    public static let maxDepth = 4
    public static let skipNames: Set<String> = ["node_modules", ".build"]

    public init(config: AILeftoversConfig, shell: ShellRunning = ProcessShell()) {
        self.config = config
        self.shell = shell
    }

    /// Paths of linked worktrees (directories whose `.git` is a file pointing at `worktrees/<name>`).
    public func findWorktrees() -> [String] {
        var found: [String] = []
        for root in Self.searchRoots {
            walk(config.url(root), depth: 0, into: &found)
        }
        return found.sorted()
    }

    private func walk(_ dir: URL, depth: Int, into found: inout [String]) {
        guard depth <= Self.maxDepth else { return }
        let fm = FileManager.default
        // List the real folder: the URL-based listing returns nothing for a symlinked folder (~/dev -> /Volumes/x/dev).
        // Found worktrees are then reported by real path, the same spelling lsof uses.
        let real = URL(fileURLWithPath: PathCheck.resolved(dir.path), isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(at: real, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for child in children {
            let name = child.lastPathComponent
            if Self.skipNames.contains(name) { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if Self.mainRepo(ofWorktree: child.path) != nil {
                found.append(child.path)
                continue
            }
            walk(child, depth: depth + 1, into: &found)
        }
    }

    /// Reads `gitdir: <main>/.git/worktrees/<name>` from a worktree's `.git` file and returns `<main>`.
    public static func mainRepo(ofWorktree path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") {
            gitdir = (path as NSString).appendingPathComponent(gitdir)
        }
        let parts = PathCheck.normalized(gitdir).split(separator: "/")
        // expect .../<main>/.git/worktrees/<name>
        guard parts.count >= 3, parts[parts.count - 2] == "worktrees", parts[parts.count - 3] == ".git" else { return nil }
        let mainParts = parts.dropLast(3)
        return "/" + mainParts.joined(separator: "/")
    }

    /// Full read-only assessment of one worktree.
    public func assess(_ path: String, cwds: [String]) async -> WorktreeAssessment {
        let normalized = PathCheck.normalized(path)
        let main = Self.mainRepo(ofWorktree: normalized)
        let stats = FolderStats.measure(URL(fileURLWithPath: normalized))

        let real = PathCheck.resolved(normalized)
        let usingCwd = cwds.first { PathCheck.isInside($0, real) }
        let dirty = await isDirty(normalized)
        let unpushed = await hasUnpushedCommits(normalized)

        return WorktreeAssessment(
            path: normalized,
            mainRepo: main,
            dirty: dirty,
            unpushed: unpushed,
            inUse: usingCwd != nil,
            inUseBy: usingCwd == nil ? nil : "In use by a running process",
            bytes: stats.bytes,
            newestModified: stats.newestModified
        )
    }

    /// True when `git status` shows changes or fails. Failure is treated as unsafe.
    /// Untracked files are always listed, even when the user's git config hides them.
    func isDirty(_ path: String) async -> Bool {
        let args = ["-C", path, "-c", "status.showUntrackedFiles=all", "status", "--porcelain"]
        guard let result = try? await shell.run(ExternalTools.git, args, timeout: 60) else { return true }
        return result.exitCode != 0 || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when HEAD has commits that are neither on the upstream nor on another branch.
    func hasUnpushedCommits(_ path: String) async -> Bool {
        // Upstream exists: unpushed = commits ahead of it.
        if let upstream = try? await shell.run(ExternalTools.git, ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 30),
           upstream.exitCode == 0 {
            guard let ahead = try? await shell.run(ExternalTools.git, ["-C", path, "log", "--oneline", "@{u}.."], timeout: 60) else { return true }
            return ahead.exitCode != 0 || !ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // No upstream: HEAD must be contained in some branch other than this worktree's own branch.
        let own = try? await shell.run(ExternalTools.git, ["-C", path, "symbolic-ref", "-q", "--short", "HEAD"], timeout: 30)
        let ownBranch = own?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let refs = try? await shell.run(
            ExternalTools.git,
            ["-C", path, "for-each-ref", "--contains", "HEAD", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
            timeout: 60
        ), refs.exitCode == 0 else { return true }
        let others = refs.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != ownBranch }
        return others.isEmpty
    }

    /// Scan result group for worktrees, or nil when there are none.
    public func scanGroup(cwds: [String]) async -> ScanGroup? {
        var items: [ScanItem] = []
        let cutoff = config.cutoff
        for path in findWorktrees() {
            let a = await assess(path, cwds: cwds)
            let reason = a.blockReason(cutoff: cutoff)
            let repoName = a.mainRepo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repo"
            let wtName = URL(fileURLWithPath: a.path).lastPathComponent
            items.append(ScanItem(
                id: a.path,
                title: "\(repoName) / \(wtName)",
                // git-ignored files (.env, .venv, local databases) are not checked, so say where they end up.
                detail: "\(a.path) · git-ignored files inside go to the Trash too",
                bytes: a.bytes,
                paths: [a.path],
                selectable: reason == nil,
                // Worktrees hold git-ignored data that no status check sees, so they are never ticked by default.
                selectedByDefault: false,
                note: reason
            ))
        }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "agent-worktrees", title: "Agent worktrees", items: items)
    }
}
