import SwiftUI
import AppKit
import BurrowCore

/// `Burrow --snapshot <dir>`: renders key states to PNG in light and dark, then exits.
@MainActor
enum SnapshotRunner {
    private static let size = CGSize(width: 1200, height: 760)

    struct Scenario {
        var name: String
        var make: @MainActor () -> AnyView
    }

    static func run(directory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        for dark in [false, true] {
            for scenario in scenarios() {
                let name = "\(scenario.name)-\(dark ? "dark" : "light").png"
                guard let png = render(scenario.make(), dark: dark) else {
                    FileHandle.standardError.write(Data("failed: \(name)\n".utf8))
                    continue
                }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }

    private static func render(_ view: AnyView, dark: Bool) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentViewController = host
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        // Alpha 0 keeps the window invisible while still letting AppKit lay everything out.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        spin(1.6)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        spin(0.2)
        guard let frame = window.contentView?.superview else { return nil }
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: Scenarios

    private static func model(_ status: MoleStatus = .ready) -> AppModel {
        AppModel(jobs: MockData.jobs(), moleStatus: status,
                 previewLeftovers: { MockData.leftovers(for: $0) })
    }

    private static func reviewState(_ scan: ScanResult, off: Set<ScanItem.ID> = []) -> JobState {
        var s = JobState()
        s.scan = scan
        s.selection = scan.defaultSelection.subtracting(off)
        s.phase = .review
        return s
    }

    private static func wrap(_ model: AppModel) -> AnyView {
        AnyView(RootView().environment(model))
    }

    private static let keptRows: Set<ScanItem.ID> = ["zed-npm", "chrome-sw", "wallpaper", "next"]

    static func scenarios() -> [Scenario] {
        [
            Scenario(name: "01-clean-review") {
                let m = model()
                m.preload(.clean, reviewState(MockData.clean, off: keptRows))
                m.preload(.purge, reviewState(MockData.purge))
                return wrap(m)
            },
            Scenario(name: "02-confirm") {
                let m = model()
                var s = reviewState(MockData.clean, off: keptRows)
                s.phase = .review
                m.preload(.clean, s)
                let lines = MockData.clean.groups.enumerated().compactMap { index, group -> ConfirmSheet.Line? in
                    let picked = group.items.filter { $0.selectable && s.selection.contains($0.id) }
                    guard !picked.isEmpty else { return nil }
                    return ConfirmSheet.Line(id: group.id, title: group.title, index: index, count: picked.count,
                                             bytes: picked.reduce(0) { $0 + ($1.bytes ?? 0) })
                }
                let count = lines.reduce(0) { $0 + $1.count }
                let bytes = lines.reduce(0) { $0 + $1.bytes }
                return AnyView(ZStack {
                    RootView().environment(m)
                    Color.black.opacity(0.28)
                    ConfirmSheet(kind: .clean, lines: lines, count: count, bytes: bytes, onCancel: {}, onConfirm: {})
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                })
            },
            Scenario(name: "03-running") {
                let m = model()
                var s = reviewState(MockData.clean)
                s.phase = .running
                s.status = "Cleaning Browsers"
                s.log = [
                    "Cleaning User essentials",
                    "  Removed User app cache  1.2 GB",
                    "  Removed User app logs  7 MB",
                    "Cleaning Browsers",
                    "  Removed Chrome cache  642.2 MB",
                ]
                m.preload(.clean, s)
                return wrap(m)
            },
            Scenario(name: "04-done") {
                let m = model()
                var s = reviewState(MockData.clean)
                s.phase = .done
                s.result = RunResult(freedBytes: 7_800_000_000, itemCount: 142,
                                     problems: ["Chrome Service Worker: 1 file was in use and was skipped."],
                                     exitCode: 0, log: "Cleaning Browsers\n  Removed Chrome cache  642.2 MB")
                m.preload(.clean, s)
                return wrap(m)
            },
            Scenario(name: "05-empty") {
                let m = model()
                m.preload(.clean, reviewState(ScanResult(kind: .clean, groups: [])))
                return wrap(m)
            },
            Scenario(name: "06-uninstall-review") {
                let m = model()
                m.selectedKind = .uninstall
                m.preload(.uninstall, reviewState(MockData.uninstall))
                m.setSelected(["com.apple.garageband10", "com.microsoft.onenote"], true, in: .uninstall)
                return AnyView(RootView(initialFocus: "com.apple.garageband10").environment(m))
            },
            Scenario(name: "07-mole-missing") {
                wrap(model(.missing))
            },
        ]
    }
}
