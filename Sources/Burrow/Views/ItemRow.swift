import SwiftUI
import BurrowCore

struct ItemRow: View {
    var item: ScanItem
    /// Opt-in lists: an unticked row is "not chosen", so it dims without a strike or a "Kept" label.
    var optIn: Bool
    var isOn: Bool
    var isExpanded: Bool
    var onToggle: () -> Void
    var onExpand: () -> Void

    /// Unticked and selectable: dimmed in every list.
    private var dimmed: Bool { item.selectable && !isOn }
    /// Clean-style lists only: an unticked row is "kept", shown with a strike and a label.
    private var kept: Bool { dimmed && !optIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                checkbox
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(RowType.primary)
                        .foregroundStyle(dimmed ? Ink.secondary : .primary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(RowType.secondary)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                trailingInfo
                sizeColumn
                disclosure
            }
            if isExpanded { pathList }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var checkbox: some View {
        if item.selectable {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(item.title)
                .accessibilityValue(isOn ? "Selected" : (optIn ? "Not selected" : "Kept"))
        } else {
            Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var trailingInfo: some View {
        Group {
            if !item.selectable, let note = item.note {
                Text(note)
            } else if let count = item.count, item.selectable {
                Text(count == 1 ? "1 item" : "\(count) items")
            } else {
                Text("")
            }
        }
        .font(RowType.secondary)
        .foregroundStyle(Ink.secondary)
        .lineLimit(1)
        .frame(width: 84, alignment: .trailing)
    }

    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(item.bytes.map(ByteSize.format) ?? "\u{2014}")
                .font(RowType.primary)
                .monospacedDigit()
                .strikethrough(kept)
                .foregroundStyle(dimmed ? Ink.secondary : .primary)
            if kept {
                Text("Kept")
                    .font(RowType.secondary)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: 76, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sizeSpoken)
    }

    private var sizeSpoken: String {
        let size = item.bytes.map(ByteSize.format) ?? "size not reported"
        if kept { return "\(size), kept" }
        return dimmed ? "\(size), not selected" : size
    }

    @ViewBuilder private var disclosure: some View {
        if item.paths.isEmpty {
            Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
        } else {
            Button(action: onExpand) {
                Image(systemName: "chevron.right")
                    .font(RowType.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Ink.secondary)
            .help(isExpanded ? "Hide paths" : "Show paths")
            .accessibilityLabel(isExpanded ? "Hide paths" : "Show paths")
        }
    }

    private var pathList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.paths.prefix(8), id: \.self) { path in
                Text(path)
                    .font(RowType.secondary.monospaced())
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.paths.count > 8 {
                Text("and \(item.paths.count - 8) more")
                    .font(RowType.secondary)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 28)
    }
}
