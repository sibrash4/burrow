import SwiftUI
import BurrowCore

struct RunningView: View {
    var status: String
    var log: [String]
    var logRevision: Int
    /// nil: Mole gives no byte-level progress, so the bar is indeterminate.
    var progress: Double?
    var stopping: Bool
    var onStop: () -> Void
    @State private var showLog = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(status.isEmpty ? "Working" : status).font(.title3)
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            DisclosureGroup("Details", isExpanded: $showLog) {
                LogView(lines: log, revision: logRevision).frame(height: 260)
            }
            HStack {
                Spacer()
                Button(stopping ? "Stopping\u{2026}" : "Stop", action: onStop)
                    .keyboardShortcut(.cancelAction)
                    .disabled(stopping)
            }
        }
        .frame(maxWidth: 560)
        .padding(32)
    }
}

struct LogView: View {
    var lines: [String]
    /// Scrolls to the newest line whenever this changes. Pass a counter that keeps growing: `lines.count`
    /// stops changing once the log is capped.
    var revision = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(RowType.secondary.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onChange(of: revision) { proxy.scrollTo("end") }
        }
        .accessibilityLabel("Live log")
    }
}

struct DoneView: View {
    var kind: JobKind
    var result: RunResult?
    var onAgain: () -> Void
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).foregroundStyle(.secondary)
            }
            if let problems = result?.problems, !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(problems.count == 1 ? "1 thing was skipped" : "\(problems.count) things were skipped")
                        .font(RowType.primary.weight(.semibold))
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).font(RowType.secondary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let log = result?.log, !log.isEmpty {
                DisclosureGroup("Details", isExpanded: $showLog) {
                    LogView(lines: log.components(separatedBy: "\n")).frame(height: 200)
                }
            }
            Button("Scan again", action: onAgain)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(32)
    }

    private var title: String {
        let freed = result?.freedBytes.map(ByteSize.format)
        switch kind {
        case .uninstall:
            if let n = result?.itemCount { return "\(plural(n, "app", "apps")) moved to the Trash" }
            return "Moved to the Trash"
        default:
            return freed.map { "\($0) freed" } ?? "Done"
        }
    }

    private var detail: String {
        switch kind {
        case .uninstall:
            if let freed = result?.freedBytes { return "\(ByteSize.format(freed)) will be freed when you empty the Trash." }
            return "Empty the Trash to free the space."
        default:
            if let n = result?.itemCount { return "\(plural(n, "item", "items")) removed." }
            return "Mole finished without errors."
        }
    }
}

struct FailedView: View {
    var text: String
    var cancelled: Bool
    /// What the run got done before it stopped or failed, when Mole reported it.
    var result: RunResult?
    var onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(cancelled ? "Stopped" : "Couldn't finish", systemImage: "exclamationmark.circle")
        } description: {
            VStack(spacing: 6) {
                Text(text)
                if let freed = result?.freedBytes, freed > 0 {
                    Text(cancelled
                         ? "\(ByteSize.format(freed)) was freed before you stopped. Anything Mole had not reached is still there."
                         : "\(ByteSize.format(freed)) was freed before Mole stopped.")
                        .monospacedDigit()
                }
            }
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
