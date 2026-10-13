import Foundation

/// Which app or folder owns a path in clean-list.txt. Paths with the same owner become one row.
struct CleanOwner: Equatable {
    enum Kind: Equatable { case cache, logs, temp, plain }

    /// Stable id part, also encodes the folder: home-relative ("Library/Logs/Zoom|logs") or absolute.
    var key: String
    var name: String
    var kind: Kind
    /// `name` is already the full title; no "cache"/"logs" suffix is added.
    var fixedTitle = false
    /// Mole removes this with a command that ignores the whitelist.
    var alwaysCleaned = false
    /// Absolute folder the owner stands for (display and "always keep").
    var root: String
    /// Whitelist globs used for "always keep"; defaults to `root`.
    var keepPatterns: [String]?

    var isTrash: Bool { key == ".Trash" }
}

enum CleanOwnerResolver {
    static func resolve(path: String, home: String) -> CleanOwner {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let underHome = path.hasPrefix(homePrefix)
        let comps = (underHome ? String(path.dropFirst(homePrefix.count)) : path)
            .split(separator: "/").map(String.init)
        let base = underHome ? homePrefix : "/"

        func make(_ count: Int, _ name: String, _ kind: CleanOwner.Kind, fixed: Bool = false, suffixKind: Bool = false) -> CleanOwner {
            let prefix = comps.prefix(count).joined(separator: "/")
            let root = base + prefix
            var key = underHome ? prefix : "/" + prefix
            if suffixKind { key += "|\(kindLabel(kind))" }
            return CleanOwner(key: key, name: name, kind: kind, fixedTitle: fixed, root: root)
        }

        func restKind(from index: Int) -> CleanOwner.Kind {
            kind(of: Array(comps.dropFirst(index)))
        }

        guard let first = comps.first else {
            return CleanOwner(key: path, name: FriendlyName.make(path), kind: .plain, root: path)
        }

        if underHome, first == ".Trash" { return make(1, "Trash", .plain, fixed: true) }

        if let i = comps.firstIndex(of: ".next"), i >= 1 {
            return make(i + 1, "Next.js build cache (\(comps[i - 1]))", .cache, fixed: true)
        }
        if let i = comps.firstIndex(of: "__pycache__"), i >= 1 {
            return make(i + 1, "Python bytecode cache (\(comps[i - 1]))", .cache, fixed: true)
        }
        if let i = comps.lastIndex(of: "ModuleCache"), i >= 1, comps[i - 1] == "clang" {
            return make(i + 1, "Clang module cache", .cache, fixed: true)
        }

        if underHome, first == "Library", comps.count >= 2 {
            let area = comps[1]
            switch area {
            case "Caches" where comps.count >= 3:
                return make(3, FriendlyName.make(comps[2]), .cache, suffixKind: true)
            case "Logs" where comps.count >= 3:
                if comps[2] == "DiagnosticReports" { return make(3, "Crash and diagnostic reports", .plain, fixed: true) }
                return make(3, FriendlyName.make(comps[2]), .logs, suffixKind: true)
            case "Application Support" where comps.count >= 3:
                if let i = comps.firstIndex(of: "Service Worker"), i >= 4 {
                    let browser = FriendlyName.make(comps[i - 2])
                    var owner = make(i - 1, "\(browser) service worker cache", .cache, fixed: true)
                    owner.key = "sw:" + owner.key
                    owner.keepPatterns = [owner.root + "/*/Service Worker/CacheStorage/*"]
                    return owner
                }
                return make(3, FriendlyName.make(comps[2]), restKind(from: 3), suffixKind: true)
            case "Containers" where comps.count >= 3, "Group Containers" where comps.count >= 3:
                return make(3, FriendlyName.make(comps[2]), restKind(from: 3), suffixKind: true)
            case "Developer" where comps.count >= 4:
                if comps[2] == "Xcode", comps[3] == "DerivedData" { return make(4, "Xcode DerivedData", .plain, fixed: true) }
                if comps[2] == "CoreSimulator", comps[3] == "Devices" {
                    var owner = make(4, "Unavailable Xcode simulators", .plain, fixed: true)
                    owner.alwaysCleaned = true
                    return owner
                }
                return make(3, FriendlyName.make(comps[2]), restKind(from: 3), suffixKind: true)
            default:
                return make(2, FriendlyName.make(area), restKind(from: 2), suffixKind: true)
            }
        }

        if underHome, first.hasPrefix("."), first.count > 1 {
            return make(1, FriendlyName.make(String(first.dropFirst())), restKind(from: 1), suffixKind: true)
        }

        let parentCount = max(1, comps.count - 1)
        return make(parentCount, FriendlyName.make(comps[parentCount - 1]), .plain)
    }

    static func kind(of rest: [String]) -> CleanOwner.Kind {
        let lowered = rest.map { $0.lowercased() }
        if lowered.contains(where: { $0 == "tmp" || $0 == "temp" || $0 == "temporaryitems" }) { return .temp }
        if lowered.contains(where: { $0.hasPrefix("log") || $0.hasPrefix("_log") || $0.hasSuffix("logs") || $0.hasSuffix(".log") }) { return .logs }
        return .cache
    }

    static func kindLabel(_ kind: CleanOwner.Kind) -> String {
        switch kind {
        case .cache: "cache"
        case .logs: "logs"
        case .temp: "temp"
        case .plain: "plain"
        }
    }
}

/// Turns folder names and bundle ids into short readable names.
enum FriendlyName {
    private static let overrides: [String: String] = [
        "google": "Google (Chrome)",
        "claude-3p": "Claude",
        "claude": "Claude",
        "com.anthropic.claudefordesktop": "Claude desktop",
        "com.mitchellh.ghostty": "Ghostty",
        "com.apple.helpd": "macOS Help",
        "com.apple.mediaanalysisd": "Media analysis",
        "com.apple.wallpaper.extension.aerials": "Wallpaper aerials",
        "com.apple.geod": "Geod",
        "com.apple.parsecd": "Parsecd",
        "org.swift.swiftpm": "Swift package manager",
        "coresimulator": "CoreSimulator",
        "zoom.us": "Zoom",
        "1password": "1Password",
        "com.microsoft.word": "Microsoft Word",
        "com.microsoft.excel": "Microsoft Excel",
        "com.apple.applemediaservices": "Apple Media Services",
        "com.apple.applemediaservicesui.utilityextension": "Apple Media Services",
        "suggestions": "Siri suggestions",
        "messages": "Messages previews",
        "homebrew": "Homebrew",
        "npm": "npm",
        "cargo": "Cargo",
        "zed": "Zed",
        "claude-cli-nodejs": "Claude CLI",
    ]

    private static let topLevelDomains: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "us", "uk", "de", "fr", "ai"]
    private static let noiseWords: Set<String> = [
        "sparkle", "shipit", "helper", "agent", "service", "mac", "macos", "app", "desktop", "installer",
        "updater", "extension", "sfl4", "plist", "mobile",
    ]
    private static let fileExtensions: Set<String> = ["json", "plist", "log", "ips", "txt", "db", "sqlite"]

    static func make(_ raw: String) -> String {
        var name = raw
        if let hit = overrides[name.lowercased()] { return hit }
        // Team id prefix of group containers: "ABCDE12345.com.example.app".
        if let dot = name.firstIndex(of: "."), name[..<dot].count == 10, name[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            name = String(name[name.index(after: dot)...])
            if let hit = overrides[name.lowercased()] { return hit }
        }
        // App group ids: "group.com.example.app".
        if name.hasPrefix("group."), name.count > 8 { name = String(name.dropFirst("group.".count)) }
        let pieces = name.split(separator: ".").map(String.init)
        if pieces.count >= 2, let ext = pieces.last?.lowercased(), fileExtensions.contains(ext) {
            name = pieces.dropLast().joined(separator: ".")
        } else if pieces.count >= 3, topLevelDomains.contains(pieces[0].lowercased()) {
            name = bundleName(Array(pieces.dropFirst()))
        }
        return titleCase(name)
    }

    /// "microsoft.Word" -> "Word"; "wisp.app.sparkle" -> "wisp".
    private static func bundleName(_ parts: [String]) -> String {
        let meaningful = parts.filter { part in
            !noiseWords.contains(part.lowercased()) && !looksLikeHash(part)
        }
        return meaningful.last ?? parts.last ?? ""
    }

    private static func looksLikeHash(_ part: String) -> Bool {
        part.count >= 10 && part.filter(\.isNumber).count >= 3
    }

    private static func titleCase(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        return words.map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
