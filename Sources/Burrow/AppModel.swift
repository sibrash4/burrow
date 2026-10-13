import SwiftUI
import BurrowCore

enum MoleStatus: Equatable {
    /// The launch check is still running. The normal screens show meanwhile.
    case checking
    case ready
    case missing
    /// Found, but not the version Burrow was built for. Non-blocking.
    case versionMismatch(String)
}

extension MoleStatus {
    var isVersionMismatch: Bool {
        if case .versionMismatch = self { return true }
        return false
    }
}

enum Phase: Equatable {
    case idle, scanning, review, confirming, running
    /// Stop was pressed. The run is over only once Mole has exited and the engine has put everything back.
    case stopping
    case done, failed
}

struct Leftover: Identifiable, Hashable, Sendable {
    var path: String
    var bytes: Int64?
    var id: String { path }
}

struct JobState {
    var phase: Phase = .idle
    var scan: ScanResult?
    var selection: Set<ScanItem.ID> = []
    var status = ""
    var log: [String] = []
    /// Counts every line ever logged. The log is capped, so its own count stops growing; this one keeps going.
    var logRevision = 0
    /// nil when Mole gives no byte-level progress, which is the normal case: the bar is then indeterminate.
    var progress: Double?
    var result: RunResult?
    var errorText: String?
    /// Shown above the list when "Always keep" could not be saved.
    var keepError: String?
    var wasCancelled = false
}

@MainActor @Observable
final class AppModel {
    /// How long a stop may take to tear Mole down and restore files before the UI stops waiting.
    static let stopLimit: TimeInterval = 20

    var selectedKind: JobKind = .clean
    var moleStatus: MoleStatus
    /// One line shown in the sidebar footer, e.g. after crash recovery. nil when there is nothing to say.
    var startupNotice: String?
    private(set) var states: [JobKind: JobState] = [:]
    /// True from the first scan of Scan All until the last one has finished or been cancelled. Scan only.
    private(set) var isScanningAll = false

    @ObservationIgnored private var jobs: [JobKind: MoleJob]
    @ObservationIgnored private var tasks: [JobKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanAllTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration: [JobKind: Int] = [:]
    @ObservationIgnored private let alwaysKeepHandler: (ScanItem) throws -> Void
    @ObservationIgnored private let leftoversHandler: (ScanItem) async throws -> [Leftover]
    @ObservationIgnored private let locateMole: () async -> MoleStatus
    @ObservationIgnored private let scanTimeout: Duration

    private let maxLogLines = 2000

    init(
        jobs: [JobKind: MoleJob],
        moleStatus: MoleStatus = .ready,
        alwaysKeep: @escaping (ScanItem) throws -> Void = { _ in },
        previewLeftovers: @escaping (ScanItem) async throws -> [Leftover] = { _ in [] },
        locateMole: @escaping () async -> MoleStatus = { .ready },
        scanTimeout: Duration = .seconds(300)
    ) {
        self.jobs = jobs
        self.moleStatus = moleStatus
        self.alwaysKeepHandler = alwaysKeep
        self.leftoversHandler = previewLeftovers
        self.locateMole = locateMole
        self.scanTimeout = scanTimeout
    }

    // MARK: Reading state

    func state(_ kind: JobKind) -> JobState { states[kind] ?? JobState() }

    func isSelected(_ id: ScanItem.ID, in kind: JobKind) -> Bool { state(kind).selection.contains(id) }

    /// Selectable rows only: these are the ones that can ever be removed.
    func selectableItems(_ kind: JobKind) -> [ScanItem] {
        (state(kind).scan?.allItems ?? []).filter(\.selectable)
    }

    func totalBytes(_ kind: JobKind) -> Int64 {
        selectableItems(kind).reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func selectedBytes(_ kind: JobKind) -> Int64 {
        let sel = state(kind).selection
        return selectableItems(kind).filter { sel.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func selectedCount(_ kind: JobKind) -> Int {
        let sel = state(kind).selection
        return selectableItems(kind).filter { sel.contains($0.id) }.count
    }

    func selectedBytes(of group: ScanGroup, in kind: JobKind) -> Int64 {
        let sel = state(kind).selection
        return group.items.filter { $0.selectable && sel.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func selectableBytes(of group: ScanGroup) -> Int64 {
        group.items.filter(\.selectable).reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// Size shown next to a sidebar entry once there is something to show.
    func sidebarSize(_ kind: JobKind) -> String? {
        let s = state(kind)
        guard let scan = s.scan, !scan.allItems.isEmpty, s.phase == .review || s.phase == .confirming else { return nil }
        if kind == .uninstall { return selectedCount(kind) == 0 ? nil : ByteSize.format(selectedBytes(kind)) }
        return ByteSize.format(selectedBytes(kind))
    }

    /// True while Mole may still be running, or a whitelist edit may still be open.
    var hasActiveRun: Bool {
        states.values.contains { $0.phase == .running || $0.phase == .stopping }
    }

    // MARK: Selection

    func setSelected(_ ids: [ScanItem.ID], _ on: Bool, in kind: JobKind) {
        var s = state(kind)
        let selectable = Set(selectableItems(kind).map(\.id))
        for id in ids where selectable.contains(id) {
            if on { s.selection.insert(id) } else { s.selection.remove(id) }
        }
        states[kind] = s
    }

    func toggle(_ id: ScanItem.ID, in kind: JobKind) {
        setSelected([id], !isSelected(id, in: kind), in: kind)
    }

    /// `within` is the rows the user can see (the search filter applies), nil for every row.
    func selectAll(_ kind: JobKind, within ids: [ScanItem.ID]? = nil) {
        setSelected(ids ?? selectableItems(kind).map(\.id), true, in: kind)
    }

    func selectNone(_ kind: JobKind, within ids: [ScanItem.ID]? = nil) {
        setSelected(ids ?? selectableItems(kind).map(\.id), false, in: kind)
    }

    // MARK: Closures the integrator wires

    /// Saves the row as kept, then unticks it. If the save fails the row stays ticked and the error is shown
    /// above the list: a failed save must never look like a kept item.
    func alwaysKeep(_ item: ScanItem, in kind: JobKind) {
        // A whitelist entry only means something to `mo clean`.
        if kind == .clean {
            do {
                try alwaysKeepHandler(item)
            } catch {
                update(kind) { $0.keepError = "Couldn't keep \(item.title): \(Self.message(for: error)). It is still ticked." }
                return
            }
        }
        update(kind) { $0.keepError = nil }
        setSelected([item.id], false, in: kind)
    }

    func leftovers(for item: ScanItem) async throws -> [Leftover] {
        try await leftoversHandler(item)
    }

    func recheckMole() {
        Task { await checkMole() }
    }

    /// Runs the Mole check off the main thread. Called at launch and from "Check again".
    func checkMole() async {
        moleStatus = await locateMole()
    }

    // MARK: Phase transitions

    func scan(_ kind: JobKind) {
        guard let job = jobs[kind] else { return }
        // Nothing starts while a run is going or stopping, or while the confirm sheet is up (Cmd+R reaches here too).
        switch state(kind).phase {
        case .scanning, .running, .stopping, .confirming: return
        case .idle, .review, .done, .failed: break
        }
        // A stopped run can outlive the UI's wait (see `cancelRun`). Until it has put the whitelist back, no scan.
        guard !RunTeardown.shared.isActive(kind) else {
            update(kind) {
                $0.phase = .failed
                $0.result = nil
                $0.wasCancelled = false
                $0.errorText = "Mole is still stopping. Wait a moment, then try again."
            }
            return
        }
        tasks[kind]?.cancel()
        var s = state(kind)
        s.phase = .scanning
        s.errorText = nil
        s.keepError = nil
        s.wasCancelled = false
        // A scan starts a new picture: whatever the last run freed is no longer this screen's story.
        s.result = nil
        states[kind] = s

        let generation = (scanGeneration[kind] ?? 0) + 1
        scanGeneration[kind] = generation
        tasks[kind] = Task { [weak self] in
            do {
                let result = try await job.scan()
                guard !Task.isCancelled else { return }
                self?.finishScan(kind, result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(kind, error)
            }
        }
        // A scan that never comes back would leave the screen spinning forever: give up after `scanTimeout`.
        let limit = scanTimeout
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, self.scanGeneration[kind] == generation, self.state(kind).phase == .scanning else { return }
            self.tasks[kind]?.cancel()
            self.fail(kind, BurrowError.timeout("mo \(kind.rawValue) --dry-run"))
        }
    }

    func cancelScan(_ kind: JobKind) {
        guard state(kind).phase == .scanning else { return }
        tasks[kind]?.cancel()
        update(kind) {
            $0.phase = .failed
            $0.wasCancelled = true
            $0.errorText = BurrowError.cancelled.errorDescription
        }
    }

    func rescanSelected() { scan(selectedKind) }

    /// Scans every screen at once. Preview only: nothing is confirmed or run.
    func scanAll() {
        guard !isScanningAll else { return }
        isScanningAll = true
        // Started now, not in the Task below, so the spinners show at once and a Stop right after has something to stop.
        for kind in JobKind.allCases { scan(kind) }
        // `scan` ignores a kind that is running, confirming or stopping. Its task then belongs to that run,
        // so only wait on the scans that actually started.
        let started = JobKind.allCases.filter { state($0).phase == .scanning }
        scanAllTask = Task { [weak self] in
            defer {
                self?.isScanningAll = false
                self?.scanAllTask = nil
            }
            for kind in started { await self?.tasks[kind]?.value }
        }
    }

    /// Cancels Scan All and every scan that is still running.
    func cancelScanAll() {
        scanAllTask?.cancel()
        for kind in JobKind.allCases where state(kind).phase == .scanning { cancelScan(kind) }
    }

    private func finishScan(_ kind: JobKind, _ result: ScanResult) {
        var s = state(kind)
        s.scan = result
        s.selection = kind == .uninstall ? [] : result.defaultSelection
        s.phase = .review
        states[kind] = s
    }

    func beginConfirm(_ kind: JobKind) {
        guard state(kind).phase == .review, selectedCount(kind) > 0 else { return }
        update(kind) { $0.phase = .confirming }
    }

    func cancelConfirm(_ kind: JobKind) {
        guard state(kind).phase == .confirming else { return }
        update(kind) { $0.phase = .review }
    }

    func confirmRun(_ kind: JobKind) {
        guard state(kind).phase == .confirming, let job = jobs[kind], let scan = state(kind).scan else { return }
        let selection = state(kind).selection
        update(kind) {
            $0.phase = .running
            $0.status = "Starting"
            $0.log = []
            $0.result = nil
            $0.errorText = nil
            $0.progress = nil
        }
        // Created here, not inside the task, so the engine has registered the run before any Stop can arrive.
        let events = job.run(selection: selection, from: scan)
        tasks[kind] = Task { [weak self] in
            do {
                var finished: RunResult?
                for try await event in events {
                    guard let self else { return }
                    switch event {
                    case .line(let line): self.appendLog(kind, line)
                    case .status(let text): self.update(kind) { $0.status = text }
                    case .finished(let result): finished = result
                    }
                }
                guard !Task.isCancelled else { return }
                self?.finishRun(kind, finished)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(kind, error)
            }
        }
    }

    func cancelRun(_ kind: JobKind) {
        guard state(kind).phase == .running else { return }
        tasks[kind]?.cancel()
        update(kind) {
            $0.phase = .stopping
            $0.status = "Stopping"
        }
        Task { [weak self] in
            await RunTeardown.shared.waitUntilIdle(kind, timeout: Self.stopLimit)
            self?.finishStop(kind)
        }
    }

    /// Quit path: stops every run that is still going, and returns once each one has torn down.
    /// Returns with every stopped run already settled, so the phase is no longer `.stopping` when it returns.
    func stopAllAndWait() async {
        cancelScanAll()
        for kind in JobKind.allCases where state(kind).phase == .running { cancelRun(kind) }
        for kind in JobKind.allCases where state(kind).phase == .stopping {
            await RunTeardown.shared.waitUntilIdle(kind, timeout: Self.stopLimit)
            finishStop(kind)
        }
    }

    private func finishStop(_ kind: JobKind) {
        guard state(kind).phase == .stopping else { return }
        // What the engine got done before it stopped, so the stopped screen can say what was already removed.
        let partial = RunTeardown.shared.takeResult(kind)
        update(kind) {
            $0.phase = .failed
            $0.wasCancelled = true
            $0.result = partial
            $0.errorText = BurrowError.cancelled.errorDescription
        }
    }

    private func finishRun(_ kind: JobKind, _ result: RunResult?) {
        guard let result else { return fail(kind, BurrowError.parseFailed("no result from Mole")) }
        if result.exitCode != 0 {
            update(kind) { $0.result = result }
            return fail(kind, BurrowError.processFailed(exitCode: result.exitCode, output: result.log))
        }
        update(kind) {
            $0.result = result
            $0.phase = .done
        }
    }

    private func fail(_ kind: JobKind, _ error: Error) {
        if case BurrowError.moleNotFound = error { moleStatus = .missing }
        update(kind) {
            $0.phase = .failed
            $0.errorText = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func appendLog(_ kind: JobKind, _ line: String) {
        update(kind) {
            $0.log.append(line)
            $0.logRevision += 1
            if $0.log.count > maxLogLines { $0.log.removeFirst($0.log.count - maxLogLines) }
        }
    }

    private func update(_ kind: JobKind, _ change: (inout JobState) -> Void) {
        var s = state(kind)
        change(&s)
        states[kind] = s
    }

    /// For previews and snapshots: put a job straight into a state.
    func preload(_ kind: JobKind, _ state: JobState) { states[kind] = state }
}
