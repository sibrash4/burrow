import SwiftUI
import BurrowCore

struct ItemRow: View {
    var item: ScanItem
    var groupIndex: Int
    var isOn: Bool
    var isExpanded: Bool
    var onToggle: () -> Void
    var onExpand: () -> Void

    private var kept: Bool { item.selectable && !isOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                checkbox
                StrataSwatch(index: groupIndex, filled: item.selectable && isOn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(RowType.primary)
                        .foregroundStyle(item.selectable && isOn ? .primary : .secondary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(RowType.secondary)
                            .foregroundStyle(.secondary)
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
                .accessibilityValue(isOn ? "Selected" : "Kept")
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
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 84, alignment: .trailing)
    }

    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(item.bytes.map(ByteSize.format) ?? "\u{2014}")
                .font(RowType.primary)
                .monospacedDigit()
                .strikethrough(kept)
                .foregroundStyle(item.selectable && isOn ? .primary : .secondary)
            if kept {
                Text("Kept")
                    .font(RowType.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sizeSpoken)
    }

    private var sizeSpoken: String {
        let size = item.bytes.map(ByteSize.format) ?? "size not reported"
        return kept ? "\(size), kept" : size
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
            .foregroundStyle(.secondary)
            .help(isExpanded ? "Hide paths" : "Show paths")
            .accessibilityLabel(isExpanded ? "Hide paths" : "Show paths")
        }
    }

    private var pathList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.paths.prefix(8), id: \.self) { path in
                Text(path)
                    .font(RowType.secondary.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.paths.count > 8 {
                Text("and \(item.paths.count - 8) more")
                    .font(RowType.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 28)
    }
}
