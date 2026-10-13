// The AI leftovers job. The only job in Burrow that removes files itself, so it is strict:
// - everything is moved to the Trash with FileManager.trashItem, git-ignored files inside worktrees included,
// - a worktree folder is trashed whole, then `git worktree prune` drops git's record of it,
// - every rule is re-checked right before each item is removed; anything that no longer qualifies is skipped and reported.

import Foundation

public struct AILeftoversJob: MoleJob {
    public let kind: JobKind = .aiLeftovers
    public let config: AILeftoversConfig
    public let shell: ShellRunning
    public let cwds: ProcessCwdProviding
    public let trasher: Trashing
    public let worktrees: WorktreePruning

    public init(
        config: AILeftoversConfig = AILeftoversConfig(),
        shell: ShellRunning = ProcessShell(),
        cwds: ProcessCwdProviding? = nil,
        trasher: Trashing = SystemTrasher(),
        worktrees: WorktreePruning? = nil
    ) {
        self.config = config
        self.shell = shell
        self.cwds = cwds ?? LsofCwdProvider(shell: shell)
        self.trasher = trasher
        self.worktrees = worktrees ?? GitWorktreePruner(shell: shell)
    }

    static let worktreeGroupID = "agent-worktrees"

    // MARK: Scan (read-only)

    public func scan() async throws -> ScanResult {
        // If running processes cannot be read, nothing can be proven safe: show everything, select nothing.
        let cwdList: [String]
        var cwdsKnown = true
        do {
            cwdList = try await cwds.currentWorkingDirectories()
        } catch {
            cwdList = []
            cwdsKnown = false
        }
        let gate = SafetyGate(config: config, cwds: cwdList)

        var groups: [ScanGroup] = []
        if let g = await WorktreeScanner(config: config, shell: shell).scanGroup(cwds: cwdList) { groups.append(g) }
        if let g = ClaudeScanner.scanGroup(config: config, gate: gate) { groups.append(g) }
        if let g = CodexScanner.scanGroup(config: config, gate: gate) { groups.append(g) }
        if let g = ModelCacheScanner.scanGroup(config: config, gate: gate) { groups.append(g) }

        if !cwdsKnown {
            groups = groups.map { group in
                var g = group
                g.items = g.items.map { item in
                    var i = item
                    i.selectable = false
                    i.selectedByDefault = false
                    i.note = "Could not check running processes"
                    return i
                }
                return g
            }
        }

        var notes = ["Nothing is deleted. Ticked files and worktrees go to the Trash, git-ignored files inside worktrees included."]
        if !cwdsKnown {
            notes.append("Could not check which folders are in use, so nothing can be selected.")
        }
        return ScanResult(kind: .aiLeftovers, groups: groups, notes: notes)
    }

    // MARK: Run (removes only what is ticked and still qualifies)

    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        RunTeardown.shared.begin(kind)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { RunTeardown.shared.end(kind) }
                do {
                    let result = try await execute(selection: selection, scan: scan, emit: { continuation.yield($0) })
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func execute(selection: Set<ScanItem.ID>, scan: ScanResult, emit: (JobEvent) -> Void) async throws -> RunResult {
        var log: [String] = []
        var problems: [String] = []
        var freed: Int64 = 0
        var removedItems = 0

        func line(_ text: String) {
            log.append(text)
            emit(.line(text))
        }

        // Fresh process list for this run. If it cannot be read, skip everything.
        let liveCwds: [String]?
        do {
            liveCwds = try await cwds.currentWorkingDirectories()
        } catch {
            liveCwds = nil
        }
        guard let liveCwds else {
            problems.append("Could not check running processes; nothing was removed.")
            return RunResult(freedBytes: 0, itemCount: 0, problems: problems, exitCode: 1, log: problems.joined(separator: "\n"))
        }
        let gate = SafetyGate(config: config, cwds: liveCwds)
        let worktreeScanner = WorktreeScanner(config: config, shell: shell)

        let known = Set(scan.allItems.map(\.id))
        for id in selection.sorted() where !known.contains(id) {
            problems.append("Unknown item \(id): skipped.")
        }

        stop: for group in scan.groups {
            for item in group.items where selection.contains(item.id) {
                // Cancelled: keep the totals of what already moved, and say where the run stopped.
                if Task.isCancelled {
                    problems.append("Stopped by you after \(removedItems) items. The rest were not touched.")
                    break stop
                }

                guard item.selectable else {
                    problems.append("\(item.title): not removable (\(item.note ?? "not selectable")).")
                    continue
                }

                if group.id == Self.worktreeGroupID {
                    await removeWorktree(item, scanner: worktreeScanner, liveCwds: liveCwds,
                                         freed: &freed, removed: &removedItems, problems: &problems, line: line, emit: emit)
                    continue
                }

                // A Claude project folder is offered only while no session is open in it. Re-check at run time.
                if item.id.hasPrefix("claude-transcripts:"), let folder = item.detail,
                   let reason = ClaudeScanner.projectInUseReason(folder: folder, cwds: liveCwds, now: config.now) {
                    problems.append("Skipped \(item.title): \(reason).")
                    continue
                }

                // Every other item: re-check each path, then move it to the Trash.
                var moved = 0
                var movedBytes: Int64 = 0
                for path in item.paths {
                    if let reason = gate.blockReason(for: path) ?? gate.ageBlockReason(for: path) {
                        problems.append("Skipped \(displayName(path)): \(reason).")
                        continue
                    }
                    let url = URL(fileURLWithPath: path)
                    let bytes = FolderStats.measure(url).bytes
                    do {
                        _ = try trasher.trash(url)
                        moved += 1
                        movedBytes += bytes
                    } catch {
                        problems.append("Could not move \(displayName(path)) to Trash: \(error.localizedDescription)")
                    }
                }
                if moved > 0 {
                    freed += movedBytes
                    removedItems += moved
                    let noun = nounFor(item)
                    let msg = "Moved \(moved) \(noun) to Trash (\(item.title))"
                    emit(.status("Moving \(noun) to Trash"))
                    line(msg)
                }
            }
        }

        return RunResult(freedBytes: freed, itemCount: removedItems, problems: problems, exitCode: 0, log: log.joined(separator: "\n"))
    }

    private func removeWorktree(
        _ item: ScanItem, scanner: WorktreeScanner, liveCwds: [String],
        freed: inout Int64, removed: inout Int, problems: inout [String],
        line: (String) -> Void, emit: (JobEvent) -> Void
    ) async {
        let path = item.paths.first ?? item.id
        let assessment = await scanner.assess(path, cwds: liveCwds)
        if let reason = assessment.blockReason(cutoff: config.cutoff) {
            problems.append("Skipped \(item.title): \(reason).")
            return
        }
        guard let main = assessment.mainRepo else {
            problems.append("Skipped \(item.title): could not find the main repository.")
            return
        }
        emit(.status("Moving worktree to Trash \(item.title)"))
        // The whole folder goes to the Trash, so git-ignored files stay recoverable. Git is only asked to forget it.
        do {
            _ = try trasher.trash(URL(fileURLWithPath: path))
        } catch {
            problems.append("Could not move \(item.title) to Trash: \(error.localizedDescription)")
            return
        }
        freed += assessment.bytes
        removed += 1
        line("Moved worktree to Trash \(path)")
        do {
            let pruned = try await worktrees.prune(mainRepo: main)
            if pruned.exitCode != 0 {
                let why = pruned.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                problems.append("Moved \(item.title) to Trash, but git could not forget it: \(why.isEmpty ? "exit \(pruned.exitCode)" : why)")
            }
        } catch {
            problems.append("Moved \(item.title) to Trash, but git could not forget it: \(error.localizedDescription)")
        }
    }

    private func nounFor(_ item: ScanItem) -> String {
        if item.id.hasPrefix("claude-transcripts:") { return "transcripts" }
        if item.id.hasPrefix("codex-sessions:") { return "session files" }
        return "items"
    }

    private func displayName(_ path: String) -> String {
        path.hasPrefix(PathCheck.normalized(config.home.path))
            ? "~" + path.dropFirst(PathCheck.normalized(config.home.path).count)
            : path
    }
}
