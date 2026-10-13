import Foundation

public enum CleanJobError: Error, LocalizedError, Sendable, Equatable {
    /// Mole asked for a password. Burrow never types one, so the run was stopped.
    case passwordRequested
    /// The row has no whitelist entry, so it can't be kept for good.
    case cannotKeep(String)
    /// The run failed and the whitelist could not be put back either. `restore` says why.
    case failedWhitelistRestore(run: String, restore: String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequested: "Mole asked for an admin password, so Burrow stopped the clean. Admin-only items aren't supported yet."
        case .cannotKeep(let title): "Burrow can't keep \"\(title)\" for good: there is no Mole whitelist entry for it."
        case .failedWhitelistRestore(let run, let restore): "\(run) Burrow couldn't put your Mole whitelist back. \(restore)"
        }
    }
}

/// `mo clean`: preview with `--dry-run`, then run with the unticked items protected for this run only.
///
/// Mole has no "clean only these" option, so unticked items are appended to its whitelist in a
/// transaction. Before the real run Burrow previews again and checks that every unticked path has
/// dropped out of Mole's list; if any is still there, nothing is cleaned.
public struct CleanJob: MoleJob {
    public let kind = JobKind.clean

    private let runner: CommandRunning
    private let launcher: InteractiveLaunching
    private let cleanListURL: URL
    private let whitelistURL: URL
    private let backupURL: URL
    private let home: String
    private let pollSeconds: TimeInterval
    private let drainSeconds: TimeInterval
    private let maxRunSeconds: TimeInterval

    /// Only NO_COLOR. Burrow never sets Mole's MOLE_TEST_* hooks: they are Mole's internal test switches and
    /// change more than sudo (colour detection, app-running probes, app quit). Mole's own admin prompt is
    /// answered instead: "System caches need sudo. Enter continue, Space skip:" gets Space (see `runClean`).
    static let environment = ["NO_COLOR": "1"]

    public static var defaultCleanListURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole/clean-list.txt")
    }

    public init(
        runner: CommandRunning,
        launcher: InteractiveLaunching,
        cleanListURL: URL = CleanJob.defaultCleanListURL,
        whitelistURL: URL = WhitelistTransaction.defaultFileURL,
        backupURL: URL = WhitelistTransaction.defaultBackupURL,
        home: String = NSHomeDirectory(),
        pollSeconds: TimeInterval = 0.25,
        drainSeconds: TimeInterval = 0.3,
        maxRunSeconds: TimeInterval = 3600
    ) {
        self.runner = runner
        self.launcher = launcher
        self.cleanListURL = cleanListURL
        self.whitelistURL = whitelistURL
        self.backupURL = backupURL
        self.home = home
        self.pollSeconds = pollSeconds
        self.drainSeconds = drainSeconds
        self.maxRunSeconds = maxRunSeconds
    }

    // MARK: Always keep

    public var keeps: PersistentKeeps { PersistentKeeps(fileURL: whitelistURL, backupURL: backupURL, home: home) }

    /// Whitelist lines that keep this row for good. Folders, not single files, so new files stay protected.
    public func keepPatterns(for item: ScanItem) -> [String] {
        if item.id == CleanScanBuilder.trashID { return [home + "/.Trash"] }
        if item.id.hasPrefix(CleanScanBuilder.commandPrefix) || item.id.hasPrefix(CleanScanBuilder.emptyPrefix) { return item.paths }
        guard item.selectable, let first = item.paths.first else { return [] }
        let owner = CleanOwnerResolver.resolve(path: first, home: home)
        return owner.keepPatterns ?? [owner.root]
    }

    /// Writes the row to Burrow's "always keep" block. Throws instead of failing quietly, so the caller can
    /// tell the user and keep the row ticked.
    public func alwaysKeep(_ item: ScanItem) throws {
        let patterns = keepPatterns(for: item)
        guard !patterns.isEmpty else { throw CleanJobError.cannotKeep(item.title) }
        try keeps.add(patterns)
    }

    // MARK: Scan

    public func scan() async throws -> ScanResult {
        let started = Date()
        let (code, output) = try await runner.run(["clean", "--dry-run"], environment: Self.environment)
        guard code == 0 else { throw BurrowError.processFailed(exitCode: code, output: output) }
        let dryRun = CleanDryRunParser.parse(output)
        guard dryRun.heading != nil else { throw BurrowError.parseFailed("clean preview summary") }
        guard dryRun.completed else { throw BurrowError.parseFailed(dryRun.heading ?? "clean preview") }
        let list = try loadList(since: started, expectContent: dryRun.potentialBytes != nil)
        return CleanScanBuilder.build(dryRun: dryRun, list: list, home: home)
    }

    private func loadList(since started: Date, expectContent: Bool) throws -> CleanList {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cleanListURL.path) else {
            if expectContent { throw BurrowError.parseFailed("clean-list.txt is missing") }
            return CleanList()
        }
        if expectContent,
           let modified = try? fm.attributesOfItem(atPath: cleanListURL.path)[.modificationDate] as? Date,
           modified < started.addingTimeInterval(-2) {
            throw BurrowError.parseFailed("clean-list.txt is out of date")
        }
        guard let data = try? Data(contentsOf: cleanListURL), let text = String(data: data, encoding: .utf8) else {
            throw BurrowError.parseFailed("clean-list.txt can't be read")
        }
        return CleanListParser.parse(text)
    }

    // MARK: Run

    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        RunTeardown.shared.begin(kind)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var settled: RunResult?
                // Runs after the whitelist is back in place, so anyone waiting on teardown sees the final state.
                defer { RunTeardown.shared.end(kind, result: settled) }
                do {
                    let result = try await execute(selection: selection, scan: scan) { continuation.yield($0) }
                    settled = result
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BurrowError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func execute(selection: Set<ScanItem.ID>, scan: ScanResult, emit: @escaping @Sendable (JobEvent) -> Void) async throws -> RunResult {
        let unticked = scan.allItems.filter { $0.selectable && !selection.contains($0.id) }
        let kept = scan.allItems.filter { selection.contains($0.id) }

        // Every real run previews again first, even with nothing unticked: Mole's list must still be what was reviewed.
        guard !unticked.isEmpty else {
            emit(.status("Checking your selection"))
            try await verify(reviewed: scan, unticked: [], kept: kept, emit: emit)
            return try await runClean(emit: emit)
        }

        var patterns: [String] = []
        for item in unticked {
            let itemPatterns = whitelistPatterns(for: item)
            guard !itemPatterns.isEmpty else {
                throw BurrowError.selectionMismatch(expected: "\(item.title) kept", actual: "Burrow can't protect it")
            }
            patterns += itemPatterns
        }

        let transaction = WhitelistTransaction(fileURL: whitelistURL, backupURL: backupURL, home: home)
        try transaction.begin(extraPatterns: patterns)

        let outcome: Result<RunResult, Error>
        do {
            emit(.status("Checking your selection"))
            try await verify(reviewed: scan, unticked: unticked, kept: kept, emit: emit)
            // Mole reads the whitelist when it starts, so the protection must still be in the file at that moment.
            try transaction.confirmIntact(extraPatterns: patterns)
            outcome = .success(try await runClean(emit: emit))
        } catch {
            outcome = .failure(error)
        }

        var restoreProblem: String?
        do { try transaction.restore() } catch { restoreProblem = Self.restoreMessage(error, transaction: transaction) }

        switch outcome {
        case .success(var result):
            if let restoreProblem { result.problems.append("Burrow couldn't put your Mole whitelist back. \(restoreProblem)") }
            return result
        case .failure(let error):
            guard let restoreProblem else { throw error }
            throw CleanJobError.failedWhitelistRestore(run: error.localizedDescription, restore: restoreProblem)
        }
    }

    private static func restoreMessage(_ error: Error, transaction: WhitelistTransaction) -> String {
        transaction.isActive ? "\(error.localizedDescription) It will retry the next time it opens." : error.localizedDescription
    }

    /// What goes into the whitelist for an unticked row: its owner folder (so files Mole writes later stay
    /// protected) and the exact paths Mole listed.
    func whitelistPatterns(for item: ScanItem) -> [String] {
        // Mole checks the Trash folder itself, not the items inside it.
        if item.id == CleanScanBuilder.trashID { return [home + "/.Trash"] }
        return keepPatterns(for: item) + item.paths
    }

    // MARK: Verify

    private func verify(reviewed scan: ScanResult, unticked: [ScanItem], kept: [ScanItem], emit: @escaping @Sendable (JobEvent) -> Void) async throws {
        let started = Date()
        let (code, output) = try await runner.run(["clean", "--dry-run"], environment: Self.environment)
        guard code == 0 else { throw BurrowError.processFailed(exitCode: code, output: output) }
        let dryRun = CleanDryRunParser.parse(output)
        guard dryRun.completed else { throw BurrowError.parseFailed(dryRun.heading ?? "clean preview") }
        let list = try loadList(since: started, expectContent: true)

        let stillListed = Self.stillListed(unticked: unticked, in: list, dryRun: dryRun, home: home)
        if !stillListed.isEmpty {
            let shown = stillListed.prefix(3).joined(separator: ", ")
            throw BurrowError.selectionMismatch(
                expected: "\(unticked.count) unticked \(unticked.count == 1 ? "item" : "items") kept",
                actual: "\(stillListed.count) still listed (\(shown))"
            )
        }

        // Anything else Mole would clean must belong to a row the reviewed scan showed as ticked.
        let unreviewed = Self.unreviewed(in: list, dryRun: dryRun, scan: scan, unticked: unticked, home: home)
        if !unreviewed.isEmpty {
            let shown = unreviewed.prefix(3).joined(separator: ", ")
            throw BurrowError.selectionMismatch(
                expected: "only the items from this scan",
                actual: "\(unreviewed.count) \(unreviewed.count == 1 ? "item" : "items") outside it (\(shown)). Rescan and review again"
            )
        }

        // Mole also keeps the parent folder of anything whitelisted, so a ticked row can be spared too.
        let remaining = list.allPaths
        let spared = kept.filter { !$0.paths.isEmpty && $0.paths.allSatisfy { !remaining.contains($0) } && !$0.id.hasPrefix(CleanScanBuilder.commandPrefix) }
        if !spared.isEmpty {
            emit(.line("Mole will also keep: " + spared.map(\.title).joined(separator: ", ")))
        }
    }

    /// Paths and tool commands Mole would clean that the reviewed scan does not show as ticked. Flagged: a path under
    /// an unticked row, a path whose owner (folder) the scan never showed, and a command row the scan never listed.
    /// A new file under an owner the user ticked is not flagged here, except in the Trash (emptying it is permanent).
    static func unreviewed(in list: CleanList, dryRun: CleanDryRun, scan: ScanResult, unticked: [ScanItem], home: String) -> [String] {
        let untickedIDs = Set(unticked.map(\.id))
        var reviewedOwners = Set<String>()
        var untickedOwners = Set<String>()
        var reviewedPaths = Set<String>()
        var reviewedCommands = Set<String>()
        for item in scan.allItems {
            if item.id.hasPrefix(CleanScanBuilder.commandPrefix) { reviewedCommands.insert(item.id); continue }
            if item.id.hasPrefix(CleanScanBuilder.infoPrefix) { continue }
            reviewedPaths.formUnion(item.paths)
            var owners = Set(item.paths.map { CleanOwnerResolver.resolve(path: $0, home: home).key })
            if !item.id.hasPrefix(CleanScanBuilder.emptyPrefix) {
                owners.insert(String(item.id.dropFirst(CleanScanBuilder.idPrefix.count)))
            }
            if untickedIDs.contains(item.id) { untickedOwners.formUnion(owners) } else { reviewedOwners.formUnion(owners) }
        }

        var found: [String] = []
        for entry in list.allEntries {
            let counted = CleanOwnerResolver.resolve(path: entry.countedUnder ?? entry.path, home: home).key
            let own = CleanOwnerResolver.resolve(path: entry.path, home: home).key
            if untickedOwners.contains(counted) || untickedOwners.contains(own) {
                found.append(entry.path)
            } else if !(reviewedOwners.contains(counted) || reviewedOwners.contains(own) || reviewedPaths.contains(entry.path)) {
                found.append(entry.path)
            } else if CleanOwnerResolver.resolve(path: entry.path, home: home).isTrash, !reviewedPaths.contains(entry.path) {
                // Emptying the Trash is permanent: an item that arrived after the scan was never shown, even if the Trash row is ticked.
                found.append(entry.path)
            }
        }

        for row in dryRun.categories.flatMap(\.rows) where row.kind == .wouldClean || row.kind == .wouldCleanup {
            guard row.bytes == nil, row.count == nil else { continue }
            let id = CleanScanBuilder.commandPrefix + row.label.lowercased()
            if reviewedCommands.contains(id) { continue }
            // A tool whose folder is already a path row (Homebrew) is folded into that row, so it was reviewed.
            let folders = (CleanToolCaches.patterns(forLabel: row.label, home: home) ?? []).map { $0.hasSuffix("/*") ? String($0.dropLast(2)) : $0 }
            if folders.contains(where: { reviewedPaths.contains($0) }) { continue }
            found.append(row.label)
        }
        return found
    }

    /// Titles of unticked rows that Mole would still clean after the whitelist was extended.
    static func stillListed(unticked: [ScanItem], in list: CleanList, dryRun: CleanDryRun, home: String) -> [String] {
        let listed = list.allPaths
        let commandRows = dryRun.categories.flatMap(\.rows).filter { $0.kind == .wouldClean || $0.kind == .wouldCleanup }
        var leaks: [String] = []
        for item in unticked {
            let leaked: Bool
            if item.id == CleanScanBuilder.trashID {
                leaked = listed.contains { $0.hasPrefix(home + "/.Trash/") }
            } else if item.id.hasPrefix(CleanScanBuilder.commandPrefix) {
                leaked = commandRows.contains { $0.bytes == nil && $0.label.lowercased() == item.title.lowercased() }
            } else {
                leaked = item.paths.contains { listed.contains($0) }
            }
            if leaked { leaks.append(item.title) }
        }
        return leaks
    }

    // MARK: Real run

    private func runClean(emit: @escaping @Sendable (JobEvent) -> Void) async throws -> RunResult {
        emit(.status("Starting Mole"))
        let session = try launcher.launch(["clean"], environment: Self.environment, columns: 120, rows: 40)
        let linesTask = Task {
            for await line in session.lines {
                emit(.line(line))
                if let status = Self.status(from: line) { emit(.status(status)) }
            }
        }
        defer { linesTask.cancel() }

        var answered: [CleanPrompt] = []
        let deadline = Date().addingTimeInterval(maxRunSeconds)
        var exitCode: Int32?
        do {
            while exitCode == nil {
                try Task.checkCancellation()
                do {
                    exitCode = try await session.waitForExit(timeout: pollSeconds)
                } catch BurrowError.timeout {
                    // Still running.
                }
                guard exitCode == nil else { break }

                if let prompt = CleanPrompt.detect(inTail: session.transcript()), !answered.contains(prompt) {
                    answered.append(prompt)
                    switch prompt {
                    case .systemCaches:
                        emit(.line("System caches need admin access, skipping them."))
                        try answer(TerminalKey.space, on: session)
                    case .firstTimeSetup:
                        try answer(TerminalKey.enter, on: session)
                    case .password:
                        throw CleanJobError.passwordRequested
                    }
                }
                if Date() > deadline { throw BurrowError.timeout("mo clean") }
            }
        } catch is CancellationError {
            // Stop was pressed. Mole is stopped and waited for, and what it printed so far is reported.
            await session.terminateAndWait()
            return Self.partialResult(transcript: session.transcript())
        } catch {
            session.terminate()
            throw error
        }

        if drainSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(drainSeconds * 1_000_000_000)) }
        let transcript = session.transcript()
        let summary = CleanRunParser.parse(transcript)
        return RunResult(
            freedBytes: summary.freedBytes,
            itemCount: summary.itemCount,
            problems: summary.problems,
            exitCode: exitCode ?? -1,
            log: transcript
        )
    }

    /// A run that was stopped early: whatever summary Mole printed, plus a line saying it was stopped.
    static func partialResult(transcript: String) -> RunResult {
        let summary = CleanRunParser.parse(transcript)
        return RunResult(
            freedBytes: summary.freedBytes,
            itemCount: summary.itemCount,
            problems: summary.problems + ["Stopped before Mole finished."],
            exitCode: -1,
            log: transcript
        )
    }

    /// Sends one key. If Mole has already exited, `send` throws `processFailed`; that is not an error here,
    /// because the next poll of `waitForExit` returns the real exit code and decides whether the run was fine.
    private func answer(_ key: String, on session: InteractiveSession) throws {
        do { try session.send(key) } catch BurrowError.processFailed { }
    }

    static func status(from line: String) -> String? {
        guard let section = line.trimmingCharacters(in: .whitespaces).strip(prefix: "➤ ") else { return nil }
        if section.contains("need sudo") || section.hasSuffix(":") { return nil }
        return "Cleaning \(section)"
    }
}
