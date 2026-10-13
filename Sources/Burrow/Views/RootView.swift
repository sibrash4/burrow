import SwiftUI
import AppKit
import BurrowCore

struct RootView: View {
    var initialFocus: ScanItem.ID? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            if model.moleStatus == .missing {
                MoleMissingView()
            } else {
                JobView(kind: model.selectedKind, initialFocus: initialFocus)
                    .id(model.selectedKind)
            }
        }
        .frame(minWidth: 940, minHeight: 600)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(JobKind.allCases, selection: $model.selectedKind) { kind in
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(RowType.primary)
                    Text(kind.subtitle)
                        .font(RowType.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if let size = model.sidebarSize(kind) {
                    Text(size).font(RowType.secondary).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 3)
            .tag(kind)
            .accessibilityElement(children: .combine)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if case .versionMismatch(let version) = model.moleStatus {
                Label(BurrowError.unsupportedMoleVersion(version).errorDescription ?? "", systemImage: "info.circle")
                    .font(RowType.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}

struct MoleMissingView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false
    private let command = "brew install mole"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Burrow needs Mole").font(.title2.weight(.semibold))
            Text("Burrow is a window onto Mole, the command-line cleaner. Install it with Homebrew, then check again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Text(command)
                    .font(RowType.primary.monospaced())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Check again") { model.recheckMole() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Burrow")
    }
}
