// Safety seams for the AI leftovers job: in-use detection and the only two removal paths.
// Removal rules: git worktrees via `git worktree remove` (never --force), everything else via Trash.
// Nothing in this file calls removeItem or rm.

import Foundation

/// Reports the working directories of running processes.
public protocol ProcessCwdProviding: Sendable {
    /// Absolute paths that some running process has as its cwd.
    func currentWorkingDirectories() async throws -> [String]
}

/// Parses `lsof -a -d cwd -Fn` output (lines like `n/Users/x/dev/foo`).
public struct LsofCwdProvider: ProcessCwdProviding {
    public let shell: ShellRunning

    public init(shell: ShellRunning = ProcessShell()) {
        self.shell = shell
    }

    public func currentWorkingDirectories() async throws -> [String] {
        let result = try await shell.run(ExternalTools.lsof, ["-a", "-d", "cwd", "-Fn"], timeout: 20)
        return Self.parse(result.stdout)
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

/// Removes a linked worktree through git. Never forces: git refuses dirty or locked worktrees.
public protocol WorktreeRemoving: Sendable {
    func removeWorktree(mainRepo: String, worktreePath: String) async throws -> ShellResult
}

public struct GitWorktreeRemover: WorktreeRemoving {
    public let shell: ShellRunning

    public init(shell: ShellRunning = ProcessShell()) {
        self.shell = shell
    }

    public func removeWorktree(mainRepo: String, worktreePath: String) async throws -> ShellResult {
        // No --force, ever.
        try await shell.run(ExternalTools.git, ["-C", mainRepo, "worktree", "remove", worktreePath], timeout: 120)
    }
}

/// Path containment that respects component boundaries ("/a/b" is not inside "/a/bc").
public enum PathCheck {
    public static func isInside(_ path: String, _ root: String) -> Bool {
        let p = normalized(path)
        let r = normalized(root)
        return p == r || p.hasPrefix(r + "/")
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
