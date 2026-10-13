// The AI leftovers job. The only job in Burrow that removes files itself, so it is strict:
// - git worktrees are removed with `git worktree remove` (never --force),
// - everything else is moved to the Trash with FileManager.trashItem,
// - every rule is re-checked right before each item is removed; anything that no longer qualifies is skipped and reported.

import Foundation

public struct AILeftoversJob: MoleJob {
    public let kind: JobKind = .aiLeftovers
    public let config: AILeftoversConfig
    public let shell: ShellRunning
    public let cwds: ProcessCwdProviding
    public let trasher: Trashing
    public let worktrees: WorktreeRemoving

    public init(
        config: AILeftoversConfig = AILeftoversConfig(),
        shell: ShellRunning = ProcessShell(),
        cwds: ProcessCwdProviding? = nil,
        trasher: Trashing = SystemTrasher(),
        worktrees: WorktreeRemoving? = nil
    ) {
        self.config = config
        self.shell = shell
        self.cwds = cwds ?? LsofCwdProvider(shell: shell)
        self.trasher = trasher
        self.worktrees = worktrees ?? GitWorktreeRemover(shell: shell)
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

        var notes = ["Nothing is deleted. Ticked files go to the Trash; git worktrees are removed with git."]
        if !cwdsKnown {
            notes.append("Could not check which folders are in use, so nothing can be selected.")
        }
        return ScanResult(kind: .aiLeftovers, groups: groups, notes: notes)
    }

    // MARK: Run (removes only what is ticked and still qualifies)

    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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

        for group in scan.groups {
            for item in group.items where selection.contains(item.id) {
                try Task.checkCancellation()

                guard item.selectable else {
                    problems.append("\(item.title): not removable (\(item.note ?? "not selectable")).")
                    continue
                }

                if group.id == Self.worktreeGroupID {
                    await removeWorktree(item, scanner: worktreeScanner, liveCwds: liveCwds,
                                         freed: &freed, removed: &removedItems, problems: &problems, line: line, emit: emit)
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
        emit(.status("Removing worktree \(item.title)"))
        do {
            let result = try await worktrees.removeWorktree(mainRepo: main, worktreePath: path)
            if result.exitCode == 0 {
                freed += assessment.bytes
                removed += 1
                line("Removed worktree \(path)")
            } else {
                let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                problems.append("git refused to remove \(item.title): \(why.isEmpty ? "exit \(result.exitCode)" : why)")
            }
        } catch {
            problems.append("Could not remove \(item.title): \(error.localizedDescription)")
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
