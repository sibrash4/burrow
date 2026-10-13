import SwiftUI
import BurrowCore

enum MoleStatus: Equatable {
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
    case idle, scanning, review, confirming, running, done, failed
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
    var result: RunResult?
    var errorText: String?
    var wasCancelled = false
}

@MainActor @Observable
final class AppModel {
    var selectedKind: JobKind = .clean
    var moleStatus: MoleStatus
    /// One line shown in the sidebar footer, e.g. after crash recovery. nil when there is nothing to say.
    var startupNotice: String?
    private(set) var states: [JobKind: JobState] = [:]

    @ObservationIgnored private var jobs: [JobKind: MoleJob]
    @ObservationIgnored private var tasks: [JobKind: Task<Void, Never>] = [:]
    @ObservationIgnored private let alwaysKeepHandler: (ScanItem) async -> Void
    @ObservationIgnored private let leftoversHandler: (ScanItem) async throws -> [Leftover]
    @ObservationIgnored private let locateMole: () async -> MoleStatus

    private let maxLogLines = 2000

    init(
        jobs: [JobKind: MoleJob],
        moleStatus: MoleStatus = .ready,
        alwaysKeep: @escaping (ScanItem) async -> Void = { _ in },
        previewLeftovers: @escaping (ScanItem) async throws -> [Leftover] = { _ in [] },
        locateMole: @escaping () async -> MoleStatus = { .ready }
    ) {
        self.jobs = jobs
        self.moleStatus = moleStatus
        self.alwaysKeepHandler = alwaysKeep
        self.leftoversHandler = previewLeftovers
        self.locateMole = locateMole
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

    func selectAll(_ kind: JobKind) { setSelected(selectableItems(kind).map(\.id), true, in: kind) }
    func selectNone(_ kind: JobKind) { setSelected(selectableItems(kind).map(\.id), false, in: kind) }

    // MARK: Closures the integrator wires

    func alwaysKeep(_ item: ScanItem, in kind: JobKind) {
        setSelected([item.id], false, in: kind)
        // A whitelist entry only means something to `mo clean`.
        guard kind == .clean else { return }
        Task { await alwaysKeepHandler(item) }
    }

    func leftovers(for item: ScanItem) async throws -> [Leftover] {
        try await leftoversHandler(item)
    }

    func recheckMole() {
        Task { moleStatus = await locateMole() }
    }

    // MARK: Phase transitions

    func scan(_ kind: JobKind) {
        guard let job = jobs[kind] else { return }
        let phase = state(kind).phase
        guard phase != .scanning, phase != .running else { return }
        tasks[kind]?.cancel()
        var s = state(kind)
        s.phase = .scanning
        s.errorText = nil
        s.wasCancelled = false
        states[kind] = s
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
    }

    func rescanSelected() { scan(selectedKind) }

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
        }
        tasks[kind] = Task { [weak self] in
            do {
                var finished: RunResult?
                for try await event in job.run(selection: selection, from: scan) {
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
            $0.phase = .failed
            $0.wasCancelled = true
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
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        update(kind) {
            $0.phase = .failed
            $0.errorText = text
        }
    }

    private func appendLog(_ kind: JobKind, _ line: String) {
        update(kind) {
            $0.log.append(line)
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
