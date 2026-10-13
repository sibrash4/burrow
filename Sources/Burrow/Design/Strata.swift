import SwiftUI
import AppKit
import BurrowCore

/// Text colours that clear WCAG on Burrow's grounds. The system secondary label measures about 3.5:1 on light
/// grey, so secondary and dimmed text use these instead: 4.5:1 or better in light and dark.
enum Ink {
    static let secondary = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(red: 0.62, green: 0.62, blue: 0.65, alpha: 1)
                    : NSColor(red: 0.36, green: 0.36, blue: 0.39, alpha: 1)
    })
}

/// The four earth hues. They identify categories and nothing else.
enum StrataHue: Int, CaseIterable {
    case clay, ochre, moss, slate

    func color(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let dark = scheme == .dark
        let base: (Double, Double, Double)
        switch self {
        case .clay: base = dark ? (0.80, 0.52, 0.40) : (0.69, 0.38, 0.27)
        // Light ochre is darker than the first pass so it clears 3:1 on white and on the window grey.
        case .ochre: base = dark ? (0.85, 0.69, 0.33) : (0.58, 0.44, 0.08)
        case .moss: base = dark ? (0.58, 0.70, 0.45) : (0.40, 0.50, 0.28)
        case .slate: base = dark ? (0.55, 0.66, 0.78) : (0.33, 0.43, 0.54)
        }
        guard contrast == .increased else { return Color(red: base.0, green: base.1, blue: base.2) }
        // Pull away from the background: darker on light, lighter on dark.
        let t = dark ? 0.25 : -0.25
        func shift(_ v: Double) -> Double { t > 0 ? v + (1 - v) * t : v * (1 + t) }
        return Color(red: shift(base.0), green: shift(base.1), blue: shift(base.2))
    }

    /// Hue for the nth category. After four, the cycle repeats lighter.
    static func hue(at index: Int) -> (hue: StrataHue, lap: Int) {
        (allCases[index % allCases.count], index / allCases.count)
    }
}

/// Two sizes for rows. Everything else in the app uses system styles.
enum RowType {
    static let primary = Font.body
    static let secondary = Font.subheadline
}

extension JobKind {
    /// Opt-in lists default to unticked, so an unticked row means "not chosen", not "kept". Those rows dim
    /// without a strike or a "Kept" label.
    var isOptIn: Bool { self == .uninstall || self == .aiLeftovers }

    func actionTitle(bytes: Int64, count: Int) -> String {
        switch self {
        case .uninstall: return count == 1 ? "Uninstall 1 app" : "Uninstall \(count) apps"
        case .clean, .purge, .installers, .aiLeftovers:
            let verb = self == .clean ? "Clean" : self == .purge ? "Purge" : "Remove"
            if bytes > 0 { return "\(verb) \(ByteSize.format(bytes))" }
            return count == 1 ? "\(verb) 1 item" : "\(verb) \(count) items"
        }
    }

    var emptyTitle: String {
        switch self {
        case .clean: "Nothing to clean"
        case .purge: "No build folders found"
        case .installers: "No installers found"
        case .uninstall: "No apps found"
        case .aiLeftovers: "No old agent leftovers"
        }
    }

    var emptyMessage: String {
        switch self {
        case .clean: "Mole found no caches or logs worth removing."
        case .purge: "No node_modules, dist or similar folders turned up in your projects."
        case .installers: "There are no leftover .dmg, .pkg or .zip files in your usual folders."
        case .uninstall: "Mole didn't list any apps it can remove."
        case .aiLeftovers: "No agent worktrees, transcripts or model caches older than 30 days turned up."
        }
    }

    /// Plain-words consequence shown in the confirm sheet. Says what really happens to each kind of row.
    func consequence(trashIncluded: Bool = false) -> String {
        switch self {
        case .clean:
            trashIncluded ? "Caches and logs are deleted. The Trash is emptied permanently." : "Caches and logs are deleted."
        case .purge: "Build folders are deleted and can be rebuilt."
        case .installers: "Installer files are deleted."
        case .uninstall: "Apps go to the Trash. Running apps are quit first."
        case .aiLeftovers: "Ticked worktrees, transcripts and model caches go to the Trash. Worktrees include their git-ignored files."
        }
    }

    var noun: (one: String, many: String) {
        switch self {
        case .uninstall: ("app", "apps")
        case .clean, .purge, .installers, .aiLeftovers: ("item", "items")
        }
    }
}

func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
