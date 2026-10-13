// Test support: a throwaway home folder, real git repos inside it, a fake lsof, and a fake Trash.
// Nothing here touches the real home folder or the real Trash.

import Foundation
import XCTest
@testable import BurrowCore

/// Sends `lsof` to a canned answer and everything else (git) to the real process runner.
struct RoutingShell: ShellRunning {
    var lsofOutput: String = ""
    var lsofExit: Int32 = 0

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        if executable == ExternalTools.lsof {
            return ShellResult(exitCode: lsofExit, stdout: lsofOutput)
        }
        return try await ProcessShell().run(executable, arguments, timeout: timeout)
    }
}

/// Moves files into a folder inside the test temp dir instead of the real Trash.
final class FakeTrasher: Trashing, @unchecked Sendable {
    let folder: URL
    private(set) var trashed: [String] = []

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws -> URL? {
        let dest = folder.appendingPathComponent("\(trashed.count)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        trashed.append(url.path)
        return dest
    }
}

enum Fixture {
    /// Creates a unique temp home, with symlinks resolved so paths match what git and lsof report.
    static func makeHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath(3) gives the same spelling FileManager reports (/private/var, not /var).
        guard let resolved = realpath(base.path, nil) else { return base }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sets the modification date of every file and folder under `root` (and `root` itself).
    static func backdate(_ root: URL, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for case let url as URL in enumerator {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// Runs git in a directory with a fixed identity. Fails the test on a non-zero exit.
    @discardableResult
    static func git(_ args: [String], in dir: URL) async throws -> String {
        let full = ["-C", dir.path, "-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false"] + args
        let result = try await ProcessShell().run(ExternalTools.git, full, timeout: 60)
        guard result.exitCode == 0 else {
            throw FixtureError.git(args.joined(separator: " "), result.stderr)
        }
        return result.stdout
    }

    /// A main repo with one commit on `main`, placed at `<home>/dev/Repo`.
    static func makeRepo(home: URL) async throws -> URL {
        let repo = home.appendingPathComponent("dev/Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: repo)
        try write("hello\n", to: repo.appendingPathComponent("README.md"))
        try await git(["add", "README.md"], in: repo)
        try await git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    /// Adds a linked worktree on a new branch at the current HEAD of `repo`.
    static func addWorktree(repo: URL, at path: URL, branch: String) async throws {
        try await git(["worktree", "add", "-q", "-b", branch, path.path], in: repo)
    }

    /// Commits a new file inside a worktree, so its HEAD is ahead of main.
    static func commitIn(_ worktree: URL, file: String) async throws {
        try write("work\n", to: worktree.appendingPathComponent(file))
        try await git(["add", file], in: worktree)
        try await git(["commit", "-q", "-m", "work in \(file)"], in: worktree)
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case git(String, String)

    var description: String {
        switch self {
        case .git(let args, let err): "git \(args) failed: \(err)"
        }
    }
}
