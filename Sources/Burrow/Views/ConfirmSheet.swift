import SwiftUI
import BurrowCore

/// Says in plain words what is about to happen. Return confirms, Escape cancels.
struct ConfirmSheet: View {
    struct Line: Identifiable {
        var id: String
        var title: String
        var index: Int
        var count: Int
        var bytes: Int64
    }

    var kind: JobKind
    var lines: [Line]
    var count: Int
    var bytes: Int64
    var onCancel: () -> Void
    var onConfirm: () -> Void

    private let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.title3.weight(.semibold))
                Text(kind.consequence + " Anything you unticked stays where it is.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(lines.prefix(shown))) { line in
                    HStack(spacing: 10) {
                        StrataSwatch(index: line.index)
                        Text(line.title).font(RowType.primary).lineLimit(1)
                        Spacer()
                        Text(plural(line.count, kind.noun.one, kind.noun.many))
                            .font(RowType.secondary).foregroundStyle(.secondary)
                        Text(line.bytes > 0 ? ByteSize.format(line.bytes) : "\u{2014}")
                            .font(RowType.primary).monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
                if lines.count > shown {
                    Text("and \(lines.count - shown) more")
                        .font(RowType.secondary).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) {
                    Text(kind.actionTitle(bytes: bytes, count: count)).monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var headline: String {
        let what = plural(count, kind.noun.one, kind.noun.many)
        switch kind {
        case .uninstall: return "Move \(what) to the Trash?"
        default: return bytes > 0 ? "Remove \(what), \(ByteSize.format(bytes))?" : "Remove \(what)?"
        }
    }
}
