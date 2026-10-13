import SwiftUI
import BurrowCore

/// Uninstall only: what an app leaves behind, loaded on demand from the model.
struct LeftoversPane: View {
    var item: ScanItem?
    @Environment(AppModel.self) private var model
    @State private var leftovers: [Leftover]?
    @State private var failed = false

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 0) {
                    header(item)
                    Divider()
                    content
                }
            } else {
                ContentUnavailableView("Pick an app", systemImage: "app.dashed",
                                       description: Text("Select an app in the list to see the files it leaves behind."))
            }
        }
        .background(.background)
        .task(id: item?.id) { await load() }
    }

    private func header(_ item: ScanItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(RowType.primary.weight(.semibold)).lineLimit(2)
            if let path = item.paths.first {
                Text(path).font(RowType.secondary).foregroundStyle(Ink.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(path)
            }
            if let bytes = item.bytes {
                Text("App \(ByteSize.format(bytes))").font(RowType.secondary).foregroundStyle(Ink.secondary).monospacedDigit()
            }
        }
        // Top inset is tuned so the title's baseline sits on the list's group header baseline (the list header).
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if let item, !item.selectable {
            // Burrow doesn't remove this row, so Mole is never asked about it. Say why instead of "Couldn't list".
            ContentUnavailableView("Not removed by Burrow", systemImage: "nosign",
                                   description: Text(item.note ?? "Burrow can't remove this app safely."))
        } else if failed {
            ContentUnavailableView("Couldn't list leftovers", systemImage: "exclamationmark.circle")
        } else if let leftovers {
            if leftovers.isEmpty {
                ContentUnavailableView("No leftovers", systemImage: "checkmark.circle",
                                       description: Text("Mole found nothing else to remove with this app."))
            } else {
                List {
                    Section {
                        ForEach(leftovers) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((entry.path as NSString).lastPathComponent)
                                        .font(RowType.primary).lineLimit(1).truncationMode(.tail)
                                    Text(((entry.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                        .font(RowType.secondary).foregroundStyle(Ink.secondary)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                Spacer(minLength: 8)
                                Text(entry.bytes.map(ByteSize.format) ?? "\u{2014}")
                                    .font(RowType.primary).monospacedDigit()
                            }
                            // The full path is only ever a hover away, because the rows truncate.
                            .help(entry.path)
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Also removed with this app")
                            .font(RowType.secondary).foregroundStyle(Ink.secondary).textCase(nil)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        leftovers = nil
        failed = false
        guard let item, item.selectable else { return }
        do {
            let result = try await model.leftovers(for: item)
            guard !Task.isCancelled else { return }
            leftovers = result
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}
