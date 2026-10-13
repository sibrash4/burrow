import Foundation

public enum CleanJobError: Error, LocalizedError, Sendable, Equatable {
    /// Mole asked for a password. Burrow never types one, so the run was stopped.
    case passwordRequested

    public var errorDescription: String? {
        switch self {
        case .passwordRequested: "Mole asked for an admin password, so Burrow stopped the clean. Admin-only items aren't supported yet."
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

    /// Mole reads these on every run. `MOLE_TEST_NO_AUTH` makes every sudo request fail without
    /// prompting (lib/core/sudo.sh), so the preview and the real run cover the same user-level items.
    static let environment = ["NO_COLOR": "1", "MOLE_TEST_NO_AUTH": "1"]

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

    public func alwaysKeep(_ item: ScanItem) throws { try keeps.add(keepPatterns(for: item)) }

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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await execute(selection: selection, scan: scan) { continuation.yield($0) }
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
        guard !unticked.isEmpty else { return try await runClean(emit: emit) }

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
            try await verify(unticked: unticked, kept: scan.allItems.filter { selection.contains($0.id) }, emit: emit)
            outcome = .success(try await runClean(emit: emit))
        } catch {
            outcome = .failure(error)
        }

        var restoreFailure: Error?
        do { try transaction.restore() } catch { restoreFailure = error }

        switch outcome {
        case .success(var result):
            if let restoreFailure {
                result.problems.append("Burrow couldn't put your Mole whitelist back (\(restoreFailure.localizedDescription)). It will retry the next time it opens.")
            }
            return result
        case .failure(let error):
            throw error
        }
    }

    /// What goes into the whitelist for an unticked row: the exact paths Mole listed.
    func whitelistPatterns(for item: ScanItem) -> [String] {
        // Mole checks the Trash folder itself, not the items inside it.
        if item.id == CleanScanBuilder.trashID { return [home + "/.Trash"] }
        return item.paths
    }

    // MARK: Verify

    private func verify(unticked: [ScanItem], kept: [ScanItem], emit: @escaping @Sendable (JobEvent) -> Void) async throws {
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

        // Mole also keeps the parent folder of anything whitelisted, so a ticked row can be spared too.
        let remaining = list.allPaths
        let spared = kept.filter { !$0.paths.isEmpty && $0.paths.allSatisfy { !remaining.contains($0) } && !$0.id.hasPrefix(CleanScanBuilder.commandPrefix) }
        if !spared.isEmpty {
            emit(.line("Mole will also keep: " + spared.map(\.title).joined(separator: ", ")))
        }
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
                        try session.send(TerminalKey.space)
                    case .firstTimeSetup:
                        try session.send(TerminalKey.enter)
                    case .password:
                        throw CleanJobError.passwordRequested
                    }
                }
                if Date() > deadline { throw BurrowError.timeout("mo clean") }
            }
        } catch {
            session.terminate()
            throw error
        }

        if drainSeconds > 0 { try await Task.sleep(nanoseconds: UInt64(drainSeconds * 1_000_000_000)) }
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

    static func status(from line: String) -> String? {
        guard let section = line.trimmingCharacters(in: .whitespaces).strip(prefix: "➤ ") else { return nil }
        if section.contains("need sudo") || section.hasSuffix(":") { return nil }
        return "Cleaning \(section)"
    }
}
