// Safety seams for the AI leftovers job: in-use detection and the only two removal paths.
// Removal rules: everything goes to the Trash. A worktree folder is trashed whole, then git forgets it with
// `git worktree prune`. Nothing in this file calls removeItem or rm.

import Foundation

/// Reports the working directories of running processes.
public protocol ProcessCwdProviding: Sendable {
    /// Absolute paths that some running process has as its cwd.
    func currentWorkingDirectories() async throws -> [String]
}

/// The process list could not be read in full, so nothing can be proven unused.
public enum ProcessListError: Error, Equatable {
    case lsofFailed(Int32)
    case emptyOutput
}

/// Parses `lsof -a -d cwd -Fn` output (lines like `n/Users/x/dev/foo`).
public struct LsofCwdProvider: ProcessCwdProviding {
    public let shell: ShellRunning

    public init(shell: ShellRunning = ProcessShell()) {
        self.shell = shell
    }

    public func currentWorkingDirectories() async throws -> [String] {
        let result = try await shell.run(ExternalTools.lsof, ["-a", "-d", "cwd", "-Fn"], timeout: 20)
        // lsof exits 1 when it could not read some processes but still printed the list. Any other status,
        // including a kill after the timeout (which returns partial output), means the list is incomplete.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw ProcessListError.lsofFailed(result.exitCode)
        }
        let cwds = Self.parse(result.stdout)
        guard !cwds.isEmpty else { throw ProcessListError.emptyOutput }
        // Real paths, so a folder reached through a symlink still matches. Candidates are resolved the same way.
        return cwds.map(PathCheck.resolved)
    }

    public static func parse(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.hasPrefix("n") ? String(line.dropFirst()) : nil
        }
    }
}

/// Moves items to the Trash. The real implementation wraps FileManager.trashItem.
public protocol Trashing: Sendable {
    /// Moves `url` to the Trash and returns the resulting Trash URL (nil if unknown).
    func trash(_ url: URL) throws -> URL?
}

public struct SystemTrasher: Trashing {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// Drops git's record of linked worktrees whose folder is gone. Never removes a folder.
public protocol WorktreePruning: Sendable {
    func prune(mainRepo: String) async throws -> ShellResult
}

public struct GitWorktreePruner: WorktreePruning {
    public let shell: ShellRunning

    public init(shell: ShellRunning = ProcessShell()) {
        self.shell = shell
    }

    public func prune(mainRepo: String) async throws -> ShellResult {
        // Only after the worktree folder has been moved to the Trash: git then drops the stale record.
        try await shell.run(ExternalTools.git, ["-C", mainRepo, "worktree", "prune"], timeout: 120)
    }
}

/// Path containment that respects component boundaries ("/a/b" is not inside "/a/bc").
public enum PathCheck {
    public static func isInside(_ path: String, _ root: String) -> Bool {
        let p = normalized(path)
        let r = normalized(root)
        return p == r || p.hasPrefix(r + "/")
    }

    /// `normalized`, then with symlinks resolved when the path exists. Use on both sides of an in-use comparison:
    /// lsof reports real paths, but the scanners walk whatever spelling they were given.
    public static func resolved(_ path: String) -> String {
        let n = normalized(path)
        guard let real = realpath(n, nil) else { return n }
        defer { free(real) }
        return String(cString: real)
    }

    /// Collapses "//", "." and ".." and drops trailing "/". Unlike NSString.standardizingPath it never rewrites
    /// symlinked prefixes such as /private/var, so the spelling a caller passes in is the spelling compared against.
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
