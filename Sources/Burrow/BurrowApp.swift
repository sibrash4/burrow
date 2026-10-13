import SwiftUI
import AppKit
import BurrowCore

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            MainActor.assumeIsolated { SnapshotRunner.run(directory: dir) }
            return
        }
        BurrowApp.main()
    }
}

struct BurrowApp: App {
    @State private var model = AppModel(
        jobs: MockData.jobs(),
        previewLeftovers: { item in
            try await Task.sleep(for: .milliseconds(350))
            return MockData.leftovers(for: item)
        }
    )

    var body: some Scene {
        Window("Burrow", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { model.rescanSelected() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
