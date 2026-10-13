import SwiftUI
import BurrowCore

/// The four earth hues. They identify categories and nothing else.
enum StrataHue: Int, CaseIterable {
    case clay, ochre, moss, slate

    func color(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let dark = scheme == .dark
        let base: (Double, Double, Double)
        switch self {
        case .clay: base = dark ? (0.80, 0.52, 0.40) : (0.69, 0.38, 0.27)
        case .ochre: base = dark ? (0.85, 0.69, 0.33) : (0.74, 0.56, 0.18)
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
