import Foundation

public struct UninstallTimeouts: Sendable {
    /// Mole scans every app before it prints the first prompt. This takes 15 to 30 seconds on a full Mac.
    public var firstPrompt: TimeInterval = 180
    /// From answering the first prompt to the "Enter confirm" prompt (measures every leftover file).
    public var preview: TimeInterval = 180
    /// From confirming to Mole exiting.
    public var removal: TimeInterval = 1800
    /// How often the removal phase checks for a password prompt.
    public var poll: TimeInterval = 0.2
    /// How long the confirm screen must be quiet before Enter is pressed. Mole flushes keys typed right after it.
    public var promptGrace: TimeInterval = PromptTiming.defaultGrace

    public init() {}
}

/// `mo uninstall`: list apps, preview leftovers, remove chosen apps (to the Trash; never --permanent).
public struct UninstallJob: MoleJob {
    public let kind = JobKind.uninstall

    private let runner: CommandRunning
    private let launcher: InteractiveLaunching
    private let timeouts: UninstallTimeouts
    private let environment = ["NO_COLOR": "1"]
    /// Extra flags for `run`, placed before the app names. Tests set `--dry-run` for live checks; the app never does.
    var extraRunArguments: [String] = []

    public init(runner: CommandRunning, launcher: InteractiveLaunching, timeouts: UninstallTimeouts = UninstallTimeouts()) {
        self.runner = runner; self.launcher = launcher; self.timeouts = timeouts
    }

    // MARK: Scan

    public func scan() async throws -> ScanResult {
        let (code, output) = try await runner.run(["uninstall", "--list"], environment: environment)
        guard code == 0 else { throw BurrowError.processFailed(exitCode: code, output: output) }
        let apps = try UninstallListParser.parse(output)
        return Self.makeResult(from: apps)
    }

    static func makeResult(from apps: [UninstallApp]) -> ScanResult {
        let items = makeItems(from: apps)
        var bySource: [String: [(UninstallApp, ScanItem)]] = [:]
        for pair in zip(apps, items) { bySource[pair.0.source, default: []].append(pair) }

        let groups = bySource.keys.sorted(by: sourceOrder).map { source in
            let sorted = bySource[source, default: []].sorted { left, right in
                switch (left.0.bytes, right.0.bytes) {
                case let (a?, b?) where a != b: return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return left.0.name.localizedCaseInsensitiveCompare(right.0.name) == .orderedAscending
                }
            }
            return ScanGroup(id: source.lowercased(), title: groupTitle(source), items: sorted.map(\.1))
        }

        // Mole quits a running app before it removes it. The user is not asked, so say so here.
        let notes = ["Running apps are quit before removal."]
        return ScanResult(kind: .uninstall, groups: groups, notes: notes)
    }

    /// Homebrew casks are removed by `brew uninstall --cask --zap`, which deletes their data for good and ignores
    /// MOLE_DELETE_MODE. Burrow never offers them; the user removes them in Terminal.
    static let homebrewNote = "Removed permanently by Homebrew (brew --zap) — uninstall in Terminal"

    private static func sourceOrder(_ a: String, _ b: String) -> Bool {
        let rank = ["App": 0, "Homebrew": 1]
        let (ra, rb) = (rank[a] ?? 2, rank[b] ?? 2)
        return ra != rb ? ra < rb : a < b
    }

    private static func groupTitle(_ source: String) -> String {
        switch source {
        case "App": "Applications"
        case "Homebrew": "Homebrew casks"
        default: source
        }
    }

    /// Mole picks apps by display name (or .app folder name), so two apps answering to one name can't be told apart.
    private static func makeItems(from apps: [UninstallApp]) -> [ScanItem] {
        var nameUse: [String: Int] = [:]
        for app in apps {
            for key in Set([app.name.lowercased(), folderName(app.path).lowercased()]) { nameUse[key, default: 0] += 1 }
        }
        var seenIds = Set<String>()
        return apps.map { app in
            var id = app.bundleId ?? app.path
            if !seenIds.insert(id).inserted { id = app.path; seenIds.insert(id) }
            var note: String?
            if app.source == "Homebrew" {
                note = homebrewNote
            } else if app.name.hasPrefix("-") {
                note = "Name starts with a dash; Mole would read it as an option"
            } else if nameUse[app.name.lowercased(), default: 0] > 1 {
                note = "Another app has the same name"
            }
            return ScanItem(
                id: id, title: app.name, detail: app.path, bytes: app.bytes, paths: [app.path],
                selectable: note == nil, selectedByDefault: false, note: note
            )
        }
    }

    private static func folderName(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    // MARK: Preview leftovers

    /// Runs `mo uninstall --dry-run <name>` and returns the files Mole would remove with the app, bundle excluded.
    /// Mole only lists leftovers after the first "y", so this answers "y" (safe: --dry-run changes nothing),
    /// then cancels the second prompt with "q".
    public func previewLeftovers(for item: ScanItem) async throws -> [String] {
        let name = try Self.argument(for: item)
        let args = Self.previewArguments(for: name)
        // This flow answers "y" to Mole's first prompt so that it lists the leftovers. That is only acceptable
        // because --dry-run is on the command line; without it "y" would start a real uninstall.
        precondition(args.contains("--dry-run"), "previewLeftovers must always run mo uninstall with --dry-run")
        let session = try launcher.launch(args, environment: environment, columns: 120, rows: 40)
        return try await withTaskCancellationHandler {
            defer { session.terminate() }
            let frame = try await Self.wait(session, timeouts.firstPrompt, [UninstallOutput.proceedPrompt, UninstallOutput.noMatchMarker])
            if frame.contains(UninstallOutput.noMatchMarker) { throw UninstallError.appNotFound(name) }
            try Self.requireMatched([name], in: session.transcript(), session: session, decline: "n\r")

            try Self.answer("y\r", on: session)
            let shown = try await Self.wait(session, timeouts.preview, [UninstallOutput.confirmPrompt] + UninstallOutput.abortMarkers)
            try? session.send(TerminalKey.quit)
            guard shown.contains(UninstallOutput.confirmPrompt) else {
                throw UninstallError.previewUnavailable(UninstallOutput.lines(shown).last ?? "no output")
            }
            // Parsed from the transcript, not the screen: a long file list scrolls off the top of the screen.
            let parsed = UninstallOutput.removalPlan(in: session.transcript())
            return Self.leftoverPaths(parsed.files[name] ?? [], bundle: item.paths.first)
        } onCancel: {
            session.terminate()
        }
    }

    // MARK: Run

    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        RunTeardown.shared.begin(kind)
        return AsyncThrowingStream { continuation in
            let holder = SessionHolder()
            let task = Task {
                var settled: RunResult?
                defer { RunTeardown.shared.end(kind, result: settled) }
                do {
                    try await execute(selection: selection, scan: scan, holder: holder, continuation: continuation)
                    continuation.finish()
                } catch {
                    if RunTeardown.isStop(error) {
                        // Mole is stopped and waited for; what it printed so far is kept for the stopped screen.
                        settled = await holder.stopAndReport()
                    } else {
                        holder.terminate()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    task.cancel()
                    holder.terminate()
                }
            }
        }
    }

    private func execute(
        selection: Set<ScanItem.ID>, scan: ScanResult, holder: SessionHolder,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async throws {
        let items = scan.allItems.filter { selection.contains($0.id) }
        guard !items.isEmpty else { throw UninstallError.nothingSelected }
        let names = try items.map { try Self.argument(for: $0) }

        let session = try launcher.launch(["uninstall"] + extraRunArguments + names, environment: environment, columns: 120, rows: 40)
        holder.set(session)
        let forwarder = Task { await Self.forward(session.lines, to: continuation) }
        defer { forwarder.cancel() }

        continuation.yield(.status("Checking \(names.count == 1 ? names[0] : "\(names.count) apps")"))
        let first = try await Self.wait(session, timeouts.firstPrompt, [UninstallOutput.proceedPrompt, UninstallOutput.noMatchMarker])
        if first.contains(UninstallOutput.noMatchMarker) { throw UninstallError.appNotFound(names.joined(separator: ", ")) }
        try Self.requireMatched(names, in: session.transcript(), session: session, decline: "n\r")

        try Self.answer("y\r", on: session)
        continuation.yield(.status("Measuring leftover files"))
        let shown = try await Self.wait(session, timeouts.preview, [UninstallOutput.confirmPrompt] + UninstallOutput.abortMarkers)
        guard shown.contains(UninstallOutput.confirmPrompt) else {
            throw UninstallError.previewUnavailable(UninstallOutput.lines(shown).last ?? "no output")
        }
        // Parsed from the transcript, not the screen: a long file list scrolls off the top of the screen.
        let parsed = UninstallOutput.removalPlan(in: session.transcript())
        guard parsed.count == names.count, Self.sameNames(parsed.names, names) else {
            try? session.send(TerminalKey.quit)
            throw BurrowError.selectionMismatch(
                expected: names.joined(separator: ", "),
                actual: parsed.names.isEmpty ? "nothing" : parsed.names.joined(separator: ", ")
            )
        }

        try await PromptTiming.waitUntilQuiet(session, grace: timeouts.promptGrace)
        let confirmedAt = session.transcript().count
        try session.send(TerminalKey.enter)
        continuation.yield(.status("Removing \(names.count == 1 ? names[0] : "\(names.count) apps")"))

        let exit = try await awaitExit(session, after: confirmedAt)
        if case .adminPrompt = exit {
            session.terminate()
            throw UninstallError.adminRequired(names)
        }
        guard case .exited(let code) = exit else { return }

        try? await Task.sleep(nanoseconds: 150_000_000)
        let log = session.transcript()
        let summary = UninstallOutput.summary(in: log)
        var problems = summary.problems
        if !summary.found { problems.append(code == 0 ? "Mole finished without a summary." : "Mole exited with code \(code).") }
        let result = RunResult(freedBytes: summary.freedBytes, itemCount: summary.apps, problems: problems, exitCode: code, log: log)
        continuation.yield(.finished(result))
    }

    private enum Exit { case exited(Int32), adminPrompt }

    private func awaitExit(_ session: InteractiveSession, after offset: Int) async throws -> Exit {
        let limit = timeouts.removal
        let poll = UInt64(timeouts.poll * 1_000_000_000)
        return try await withThrowingTaskGroup(of: Exit?.self) { group in
            group.addTask { .exited(try await session.waitForExit(timeout: limit)) }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: poll)
                    if Self.asksForPassword(session.transcript(), after: offset) { return .adminPrompt }
                }
                return nil
            }
            var outcome: Exit?
            while let next = try await group.next() {
                guard let next else { continue }
                outcome = next
                if case .adminPrompt = next { session.terminate() }
                group.cancelAll()
                break
            }
            return outcome ?? .adminPrompt
        }
    }

    // MARK: Helpers

    /// The arguments for the leftover preview. Always contains --dry-run.
    static func previewArguments(for name: String) -> [String] { ["uninstall", "--dry-run", name] }

    /// The paths Mole lists under an app, minus the app bundle. Mole prints notes above the bundle line
    /// ("Steam launcher only ..."), so the bundle is matched by its path, not by position, and notes are dropped.
    static func leftoverPaths(_ lines: [String], bundle: String?) -> [String] {
        let shownBundle = bundle.map { ($0 as NSString).abbreviatingWithTildeInPath }
        return lines.filter { line in
            // System-level files are listed as "System: <path>". Anything else that is not a path is a note.
            let path = line.hasPrefix("System: ") ? line.dropFirst("System: ".count) : line[...]
            guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }
            if let shownBundle, line == shownBundle || line.hasPrefix(shownBundle + ", ") { return false }
            return true
        }
    }

    /// Sends an answer. If Mole already exited, the following wait reports why, so a failed write is not the error.
    private static func answer(_ keys: String, on session: InteractiveSession) throws {
        do { try session.send(keys) } catch BurrowError.processFailed { }
    }

    static func asksForPassword(_ transcript: String, after offset: Int) -> Bool {
        guard transcript.count > offset else { return false }
        let tail = transcript.dropFirst(offset)
        return UninstallOutput.adminMarkers.contains { tail.contains($0) }
    }

    /// The argument Mole matches against. Display names match exactly; Homebrew cask tokens do not
    /// (Mole compares the display name and the .app folder name only), so the display name is used for both.
    private static func argument(for item: ScanItem) throws -> String {
        guard item.selectable, !item.title.hasPrefix("-"), !item.title.isEmpty else {
            throw UninstallError.notSelectable(item.title)
        }
        return item.title
    }

    private static func sameNames(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.sorted() == rhs.sorted()
    }

    private static func requireMatched(_ names: [String], in frame: String, session: InteractiveSession, decline: String) throws {
        let matched = UninstallOutput.matchedNames(in: frame)
        guard sameNames(matched, names) else {
            try? session.send(decline)
            throw BurrowError.selectionMismatch(
                expected: names.joined(separator: ", "),
                actual: matched.isEmpty ? "nothing" : matched.joined(separator: ", ")
            )
        }
    }

    /// Waits for one of `markers` on screen. If Mole exits first, a non-zero code stays `processFailed`; a clean
    /// exit (code 0) means Mole finished without asking anything, so nothing was removed and the user is told that.
    private static func wait(_ session: InteractiveSession, _ timeout: TimeInterval, _ markers: [String]) async throws -> String {
        do {
            return try await session.waitForFrame(timeout: timeout) { frame in markers.contains { frame.contains($0) } }
        } catch BurrowError.processFailed(let code, let output) where code == 0 {
            throw UninstallError.previewUnavailable(UninstallOutput.lines(output).last ?? "Mole finished without asking")
        }
    }

    private static func forward(_ lines: AsyncStream<String>, to continuation: AsyncThrowingStream<JobEvent, Error>.Continuation) async {
        for await raw in lines {
            for line in UninstallOutput.lines(raw) {
                continuation.yield(.line(line))
                if let status = UninstallOutput.status(for: line) { continuation.yield(.status(status)) }
            }
        }
    }
}

private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: InteractiveSession?

    func set(_ session: InteractiveSession) {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    func terminate() {
        lock.lock(); let current = session; lock.unlock()
        current?.terminate()
    }

    /// Stops Mole, waits for it to exit, and reports what it printed. nil if Mole was never started.
    func stopAndReport() async -> RunResult? {
        guard let current = lock.withLock({ session }) else { return nil }
        await current.terminateAndWait()
        let log = current.transcript()
        let summary = UninstallOutput.summary(in: log)
        return RunResult(freedBytes: summary.freedBytes, itemCount: summary.apps,
                         problems: summary.problems + ["Stopped before Mole finished."], exitCode: -1, log: log)
    }
}
