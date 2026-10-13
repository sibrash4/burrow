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

/// Quitting while Mole is running: Cmd+Q cancels the run and waits for the whitelist to be restored first.
@MainActor
final class BurrowAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveRun else { return .terminateNow }
        Task { @MainActor in
            await model.stopAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(BurrowAppDelegate.self) private var appDelegate
    @State private var model = AppWiring.makeModel()

    var body: some Scene {
        Window("Burrow", id: "main") {
            RootView()
                .environment(model)
                .task {
                    appDelegate.model = model
                    await model.checkMole()
                }
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
