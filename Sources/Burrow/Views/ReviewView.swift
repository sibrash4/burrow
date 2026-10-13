import SwiftUI
import AppKit
import BurrowCore

/// The grouped checklist, the strata bar on its right edge, and the footer.
struct ReviewView: View {
    var kind: JobKind
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var focused: ScanItem.ID?
    @State private var expanded: Set<ScanItem.ID> = []

    init(kind: JobKind, initialFocus: ScanItem.ID? = nil) {
        self.kind = kind
        _focused = State(initialValue: initialFocus)
    }

    private struct Section_: Identifiable {
        var index: Int
        var group: ScanGroup
        var items: [ScanItem]
        var id: String { group.id }
    }

    private var sections: [Section_] {
        let groups = model.state(kind).scan?.groups ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return groups.enumerated().compactMap { index, group in
            let items = query.isEmpty ? group.items : group.items.filter {
                $0.title.localizedCaseInsensitiveContains(query) || ($0.detail ?? "").localizedCaseInsensitiveContains(query)
            }
            return items.isEmpty ? nil : Section_(index: index, group: group, items: items)
        }
    }

    private var layers: [StrataLayer] {
        let groups = model.state(kind).scan?.groups ?? []
        return groups.enumerated().map { index, group in
            StrataLayer(id: group.id, title: group.title, bytes: model.selectedBytes(of: group, in: kind), index: index)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            notes
            HStack(spacing: 0) {
                listArea
                if kind == .uninstall {
                    Divider()
                    LeftoversPane(item: focusedItem)
                        .frame(width: 300)
                }
            }
            Divider()
            footer
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
    }

    private var focusedItem: ScanItem? {
        guard let focused else { return nil }
        return model.state(kind).scan?.allItems.first { $0.id == focused }
    }

    @ViewBuilder private var notes: some View {
        let notes = model.state(kind).scan?.notes ?? []
        if !notes.isEmpty {
            VStack(spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(RowType.secondary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
        }
    }

    @ViewBuilder private var listArea: some View {
        HStack(spacing: 0) {
            if sections.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                list
            }
            StrataBar(layers: layers, total: model.totalBytes(kind))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
        }
    }

    private var list: some View {
        List(selection: $focused) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        ItemRow(
                            item: item,
                            groupIndex: section.index,
                            isOn: model.isSelected(item.id, in: kind),
                            isExpanded: expanded.contains(item.id),
                            onToggle: { model.toggle(item.id, in: kind) },
                            onExpand: { toggleExpanded(item.id) }
                        )
                        .tag(item.id)
                        .contextMenu { menu(for: item) }
                    }
                } header: {
                    GroupHeader(
                        group: section.group,
                        index: section.index,
                        visible: section.items,
                        state: triState(section.items),
                        selectedBytes: model.selectedBytes(of: section.group, in: kind),
                        onToggle: { toggleGroup(section.items) }
                    )
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard let item = focusedItem, item.selectable else { return .ignored }
            model.toggle(item.id, in: kind)
            return .handled
        }
    }

    @ViewBuilder private func menu(for item: ScanItem) -> some View {
        if kind == .clean {
            Button("Always keep") { model.alwaysKeep(item, in: kind) }
                .disabled(!item.selectable)
        }
        Button("Reveal in Finder") { reveal(item) }
            .disabled(item.paths.isEmpty)
    }

    private func reveal(_ item: ScanItem) {
        let urls = item.paths.prefix(20).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func toggleExpanded(_ id: ScanItem.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func triState(_ items: [ScanItem]) -> TriState? {
        let selectable = items.filter(\.selectable)
        guard !selectable.isEmpty else { return nil }
        let on = selectable.filter { model.isSelected($0.id, in: kind) }.count
        return on == 0 ? .off : on == selectable.count ? .on : .mixed
    }

    private func toggleGroup(_ items: [ScanItem]) {
        let turnOn = triState(items) != .on
        model.setSelected(items.map(\.id), turnOn, in: kind)
    }

    private var footer: some View {
        let picked = model.selectedCount(kind)
        let all = model.selectableItems(kind).count
        return HStack(spacing: 12) {
            Text("\(ByteSize.format(model.selectedBytes(kind))) of \(ByteSize.format(model.totalBytes(kind))) selected")
                .font(RowType.primary)
                .monospacedDigit()
            Text("\(picked) of \(plural(all, kind.noun.one, kind.noun.many))")
                .font(RowType.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if kind != .uninstall {
                Button("Select all") { model.selectAll(kind) }.disabled(picked == all)
            }
            Button("Select none") { model.selectNone(kind) }.disabled(picked == 0)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct GroupHeader: View {
    var group: ScanGroup
    var index: Int
    var visible: [ScanItem]
    var state: TriState?
    var selectedBytes: Int64
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let state {
                TriStateCheckbox(value: state, label: group.title, action: onToggle)
                    .fixedSize()
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
            StrataSwatch(index: index)
            Text(group.title)
                .font(RowType.primary.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(sizeText)
                .font(RowType.primary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 4)
        .padding(.trailing, 26)
    }

    private var sizeText: String {
        let total = group.items.filter(\.selectable).reduce(0) { $0 + ($1.bytes ?? 0) }
        if selectedBytes == total { return ByteSize.format(total) }
        return "\(ByteSize.format(selectedBytes)) of \(ByteSize.format(total))"
    }
}
