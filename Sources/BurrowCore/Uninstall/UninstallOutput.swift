import Foundation

public enum UninstallError: Error, LocalizedError, Sendable, Equatable {
    case nothingSelected
    /// The item can't be picked safely (same name as another app, or a name Mole would read as a flag).
    case notSelectable(String)
    case appNotFound(String)
    /// Mole asked for an administrator password. Burrow never types one.
    case adminRequired([String])
    case previewUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .nothingSelected:
            "No apps are selected."
        case .notSelectable(let name):
            "\(name) can't be removed from Burrow because Mole couldn't tell it apart from another app."
        case .appNotFound(let name):
            "Mole couldn't find \(name) any more."
        case .adminRequired(let names):
            "\(names.joined(separator: ", ")) needs administrator rights, which Burrow can't enter. Mole was stopped. Anything it had already finished stays removed. Remove this app with 'mo uninstall' in Terminal."
        case .previewUnavailable(let why):
            "Mole didn't show a file list (\(why))."
        }
    }
}

/// Reads the text Mole prints during `mo uninstall`. Works on ANSI-stripped or raw text.
public enum UninstallOutput {
    public static let matchedMarker = "Matched "
    public static let proceedPrompt = "Proceed with uninstallation?"
    public static let confirmPrompt = "Enter confirm, ESC cancel"
    public static let noMatchMarker = "No matching applications found"

    /// Phrases Mole prints when it asks for an administrator password (lib/core/sudo.sh).
    public static let adminMarkers = ["Admin required", "Enter your credentials", "Password:", "Touch ID or password"]

    /// Mole stopped before it reached the confirm prompt.
    public static let abortMarkers = [
        "requires the official", "cannot be removed safely", "nothing was removed", "Aborted.", "Admin access denied",
    ]

    public static func lines(_ text: String) -> [String] {
        stripANSI(text)
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isSpinner($0) }
    }

    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func isSpinner(_ line: String) -> Bool {
        guard let scalar = line.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }

    // MARK: First prompt: "Matched N app(s):"

    /// Display names from the "Matched N app(s):" list, in printed order. Empty if the list isn't there.
    public static func matchedNames(in text: String) -> [String] {
        let all = lines(text)
        guard let start = all.lastIndex(where: { $0.contains(matchedMarker) && $0.contains("app(s)") }) else { return [] }
        var names: [String] = []
        for line in all[(start + 1)...] {
            if line.hasPrefix("Proceed") { break }
            guard let entry = matchedEntry(line) else { continue }
            names.append(entry)
        }
        return names
    }

    /// "1. Name  5.8MB  |  Last: Today" -> "Name"
    private static func matchedEntry(_ line: String) -> String? {
        guard let bar = line.range(of: "  |  Last:") else { return nil }
        var left = String(line[..<bar.lowerBound])
        guard let dot = left.range(of: #"^\d+\. "#, options: .regularExpression) else { return nil }
        left.removeSubrange(dot)
        if let gap = left.range(of: "  ", options: .backwards) {
            left = String(left[..<gap.lowerBound])
        }
        let name = left.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: Second prompt: "Files to be removed:" + "Remove N app(s), SIZE  Enter confirm, ESC cancel:"

    public struct RemovalPlan: Equatable, Sendable {
        public var names: [String]
        /// The N in "Remove N app(s)".
        public var count: Int?
        /// Per app: the lines Mole lists under it (app bundle first, then leftovers), icons stripped.
        public var files: [String: [String]]
        /// Lines under the header that don't belong to an app, e.g. the Homebrew zap warning.
        public var notes: [String]
    }

    public static func removalPlan(in text: String) -> RemovalPlan {
        let all = lines(text)
        var plan = RemovalPlan(names: [], count: nil, files: [:], notes: [])
        guard let start = all.lastIndex(where: { $0.hasPrefix("Files to be removed") }) else { return plan }
        var current: String?
        for line in all[(start + 1)...] {
            if let count = removeCount(line) {
                plan.count = count
                break
            }
            if let name = headerName(line) {
                plan.names.append(name)
                plan.files[name] = []
                current = name
            } else if let current {
                plan.files[current, default: []].append(listing(line))
            } else {
                plan.notes.append(stripIcon(line))
            }
        }
        return plan
    }

    /// "◎ OpenLogi [Brew] , 51.8MB" -> "OpenLogi"
    private static func headerName(_ line: String) -> String? {
        guard line.hasPrefix("◎ "), !line.hasPrefix("◎ System:") else { return nil }
        guard let comma = line.range(of: " , ", options: .backwards) else { return nil }
        var name = String(line[line.index(line.startIndex, offsetBy: 2)..<comma.lowerBound])
        if name.hasSuffix(" [Brew]") { name.removeLast(" [Brew]".count) }
        return name.isEmpty ? nil : name
    }

    /// "➤ Remove 2 apps, 1.2GB  Enter confirm, ESC cancel:" -> 2
    private static func removeCount(_ line: String) -> Int? {
        guard line.contains(confirmPrompt),
              let match = line.range(of: #"Remove (\d+) apps?"#, options: .regularExpression)
        else { return nil }
        let digits = line[match].filter(\.isNumber)
        return Int(digits)
    }

    /// "✓ ~/Library/Foo , 4KB" -> "~/Library/Foo, 4KB"
    private static func listing(_ line: String) -> String {
        stripIcon(line).replacingOccurrences(of: " , ", with: ", ")
    }

    private static func stripIcon(_ line: String) -> String {
        for icon in ["✓ ", "◎ ", "⊙ ", "➤ ", "• ", "↳ "] where line.hasPrefix(icon) {
            return String(line.dropFirst(icon.count))
        }
        return line
    }

    // MARK: Final summary

    public struct Summary: Equatable, Sendable {
        public var apps: Int?
        public var freedBytes: Int64?
        public var problems: [String]
        public var found: Bool
    }

    /// Reads the "Uninstall complete" block: "Removed 1 app, freed 12.80GB: Name" plus failures and warnings.
    public static func summary(in text: String) -> Summary {
        let all = lines(text)
        var result = Summary(apps: nil, freedBytes: nil, problems: [], found: false)
        guard let heading = all.lastIndex(where: { isHeading($0) }) else { return result }
        result.found = true
        for line in all[(heading + 1)...] {
            if line.hasPrefix("====") { break }
            if let removed = removedLine(line) {
                result.apps = removed.apps
                result.freedBytes = removed.freed
            } else if line.hasPrefix("• Failed") || line.hasPrefix("⊙ ") || line.hasPrefix("↳ ") {
                result.problems.append(stripIcon(line))
            }
        }
        return result
    }

    private static func isHeading(_ line: String) -> Bool {
        ["Uninstall complete", "Uninstall incomplete", "Uninstall dry run complete"].contains(line)
    }

    private static func removedLine(_ line: String) -> (apps: Int, freed: Int64?)? {
        guard let head = line.range(of: #"^(Removed|Would remove) (\d+) apps?"#, options: .regularExpression) else { return nil }
        let apps = Int(line[head].filter(\.isNumber)) ?? 0
        var freed: Int64?
        if let tail = line.range(of: #"(freed|free) ([0-9.]+ ?[KMGT]?B)"#, options: .regularExpression) {
            let size = line[tail].split(separator: " ").last.map(String.init) ?? ""
            freed = ByteSize.parse(size)
        }
        return (apps, freed)
    }

    // MARK: Progress

    /// "Uninstalling Foo..." / "[1/2] Removing Foo (1.2GB)..." -> short status text; nil for other lines.
    public static func status(for line: String) -> String? {
        var text = line
        if let prefix = text.range(of: #"^\[\d+/\d+\] "#, options: .regularExpression) { text.removeSubrange(prefix) }
        for verb in ["Uninstalling ", "Removing ", "Cleaning files for ", "Cleaning system files for "] where text.hasPrefix(verb) {
            return text.hasSuffix("...") ? String(text.dropLast(3)) : text
        }
        return nil
    }
}
