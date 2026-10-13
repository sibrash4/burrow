import SwiftUI
import BurrowCore

/// One job's whole screen: toolbar plus whatever the job's current phase calls for.
struct JobView: View {
    var kind: JobKind
    var initialFocus: ScanItem.ID? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.state(kind)
        content(state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(kind.title)
            .navigationSubtitle(subtitle(state))
            .toolbar { toolbar(state) }
            .sheet(isPresented: Binding(
                get: { model.state(kind).phase == .confirming },
                set: { if !$0 { model.cancelConfirm(kind) } }
            )) {
                ConfirmSheet(
                    kind: kind,
                    lines: confirmLines(state),
                    count: model.selectedCount(kind),
                    bytes: model.selectedBytes(kind),
                    trashIncluded: state.selection.contains(CleanScanBuilder.trashID),
                    onCancel: { model.cancelConfirm(kind) },
                    onConfirm: { model.confirmRun(kind) }
                )
            }
    }

    @ViewBuilder private func content(_ state: JobState) -> some View {
        switch state.phase {
        case .idle:
            ContentUnavailableView {
                Label(kind.title, systemImage: kind.symbol)
            } description: {
                Text(kind.subtitle + ". Scanning only looks; nothing is removed until you confirm.")
            } actions: {
                Button("Scan") { model.scan(kind) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning").font(.title3)
                Text("Mole is looking. Nothing is removed during a scan.").foregroundStyle(.secondary)
                Button("Cancel") { model.cancelScan(kind) }
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 8)
            }
        case .review, .confirming:
            if let scan = state.scan, !scan.allItems.isEmpty {
                ReviewView(kind: kind, initialFocus: initialFocus)
            } else {
                ContentUnavailableView(kind.emptyTitle, systemImage: "checkmark.circle", description: Text(kind.emptyMessage))
            }
        case .running, .stopping:
            RunningView(status: state.status, log: state.log, logRevision: state.logRevision, progress: state.progress,
                        stopping: state.phase == .stopping, onStop: { model.cancelRun(kind) })
        case .done:
            DoneView(kind: kind, result: state.result, onAgain: { model.scan(kind) })
        case .failed:
            FailedView(text: state.errorText ?? "Something went wrong.", cancelled: state.wasCancelled,
                       result: state.result, onRetry: { model.scan(kind) })
        }
    }

    @ToolbarContentBuilder private func toolbar(_ state: JobState) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.scan(kind)
            } label: {
                Label(state.scan == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .help("Scan again (\u{2318}R)")
            .disabled(state.phase == .scanning || state.phase == .running || state.phase == .stopping || state.phase == .confirming)

            if state.phase == .review || state.phase == .confirming, !(state.scan?.allItems.isEmpty ?? true) {
                let count = model.selectedCount(kind)
                Button {
                    model.beginConfirm(kind)
                } label: {
                    Text(kind.actionTitle(bytes: model.selectedBytes(kind), count: count))
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
        }
    }

    private func subtitle(_ state: JobState) -> String {
        switch state.phase {
        case .review, .confirming:
            guard let scan = state.scan, !scan.allItems.isEmpty else { return "" }
            let time = scan.scannedAt.formatted(date: .omitted, time: .shortened)
            return "\(ByteSize.format(model.totalBytes(kind))) found \u{00B7} scanned \(time)"
        case .scanning: return "Scanning"
        case .running: return "Working"
        case .stopping: return "Stopping"
        default: return kind.subtitle
        }
    }

    private func confirmLines(_ state: JobState) -> [ConfirmSheet.Line] {
        guard let scan = state.scan else { return [] }
        return scan.groups.enumerated().compactMap { index, group in
            let picked = group.items.filter { $0.selectable && state.selection.contains($0.id) }
            guard !picked.isEmpty else { return nil }
            return ConfirmSheet.Line(id: group.id, title: group.title, index: index, count: picked.count,
                                     bytes: picked.reduce(0) { $0 + ($1.bytes ?? 0) })
        }
    }
}
