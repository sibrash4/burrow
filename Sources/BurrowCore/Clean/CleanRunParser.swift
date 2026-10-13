import Foundation

/// Reads the output of a real `mo clean`: the closing summary block and the prompts along the way.
public enum CleanRunParser {
    public struct Summary: Equatable, Sendable {
        /// "Cleanup complete", "Cleanup cancelled", ...
        public var heading: String?
        public var freedBytes: Int64?
        public var itemCount: Int?
        /// "At least 1.2GB" or "Partially measured": some sizes timed out.
        public var isPartial = false
        public var problems: [String] = []
    }

    public static func parse(_ transcript: String) -> Summary {
        var summary = Summary()
        for rawLine in TerminalText.lines(transcript) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Cleanup "), line.count < 40 {
                summary.heading = line
            } else if let rest = line.strip(prefix: "Tracked cleanup:") {
                parseTracked(rest, into: &summary)
            } else if line.hasPrefix("System was already clean") || line.hasPrefix("No additional space freed") {
                summary.freedBytes = summary.freedBytes ?? 0
            } else if let rest = line.strip(prefix: "◎ "), isProblem(rest) {
                summary.problems.append(rest)
            }
        }
        if let heading = summary.heading, heading != "Cleanup complete" {
            summary.problems.insert(heading, at: 0)
        }
        return summary
    }

    private static func parseTracked(_ text: String, into summary: inout Summary) {
        for field in text.components(separatedBy: " | ") {
            let value = field.trimmingCharacters(in: .whitespaces)
            if let items = value.strip(prefix: "Items cleaned:") {
                summary.itemCount = Int(items.trimmingCharacters(in: .whitespaces))
            } else if value.hasPrefix("Partially measured") {
                summary.isPartial = true
            } else if let rest = value.strip(prefix: "At least ") {
                summary.isPartial = true
                summary.freedBytes = ByteSize.parse(rest)
            } else {
                summary.freedBytes = ByteSize.parse(value)
            }
        }
    }

    /// "◎" lines are Mole's warnings, but a few are chatter rather than problems.
    private static func isProblem(_ text: String) -> Bool {
        !text.hasPrefix("Use --dry-run to preview") && !text.hasPrefix("Press Enter to continue")
    }
}

/// Questions `mo clean` can ask on a terminal. Verified in bin/clean.sh and lib/clean/caches.sh.
enum CleanPrompt: Equatable {
    /// "System caches need sudo. Enter continue, Space skip:" Answered with Space (skip).
    case systemCaches
    /// "First-time setup ... Press Enter to continue:" Only a macOS permission probe, Enter is safe.
    case firstTimeSetup
    /// A password or credentials request. Never answered.
    case password

    /// Looks at the last line of output, where a waiting prompt sits.
    static func detect(inTail transcript: String) -> CleanPrompt? {
        let tail = String(transcript.suffix(600))
        guard let last = TerminalText.lines(tail).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        if last.contains("Enter your credentials") || last.lowercased().hasSuffix("password:") { return .password }
        guard last.hasSuffix(":") else { return nil }
        if last.contains("System caches need sudo") && last.contains("Space skip") { return .systemCaches }
        if last.contains("Press Enter to continue:") { return .firstTimeSetup }
        return nil
    }
}
