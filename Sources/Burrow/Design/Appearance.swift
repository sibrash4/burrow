import SwiftUI
import AppKit

/// The user's appearance choice. System follows macOS; Light and Dark pin the whole app.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil hands the choice back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Sets NSApp.appearance from the stored choice on appear and on every change, so NSColor
    /// providers, sheets and window chrome follow it.
    func appliesAppearance() -> some View {
        modifier(AppearanceSync())
    }
}

private struct AppearanceSync: ViewModifier {
    @AppStorage("appearance") private var stored = AppearanceMode.system

    func body(content: Content) -> some View {
        content
            .onAppear { NSApp.appearance = stored.nsAppearance }
            .onChange(of: stored) { _, mode in NSApp.appearance = mode.nsAppearance }
    }
}
