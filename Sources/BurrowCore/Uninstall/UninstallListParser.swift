import Foundation

/// One installed app as reported by `mo uninstall --list`.
public struct UninstallApp: Hashable, Sendable {
    public var name: String
    public var bundleId: String?
    /// "App", "Homebrew", ...
    public var source: String
    public var uninstallName: String
    public var path: String
    /// Mole's own size text, e.g. "1.20GB". Empty when Mole printed nothing useful.
    public var sizeText: String
    /// nil when Mole did not report a size ("--", "N/A", "Unknown").
    public var bytes: Int64?

    public init(
        name: String, bundleId: String?, source: String, uninstallName: String,
        path: String, sizeText: String, bytes: Int64?
    ) {
        self.name = name; self.bundleId = bundleId; self.source = source
        self.uninstallName = uninstallName; self.path = path; self.sizeText = sizeText; self.bytes = bytes
    }
}

public enum UninstallListParser {
    private struct Row: Decodable {
        var name: String
        var bundle_id: String?
        var source: String?
        var uninstall_name: String?
        var path: String
        var size: String?
    }

    /// Parses the JSON array printed by `mo uninstall --list`. Tolerates stray text before or after the array.
    public static func parse(_ text: String) throws -> [UninstallApp] {
        guard let json = extractArray(from: text), let data = json.data(using: .utf8) else {
            throw BurrowError.parseFailed("uninstall list")
        }
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw BurrowError.parseFailed("uninstall list")
        }
        return rows.map { row in
            let size = (row.size ?? "").trimmingCharacters(in: .whitespaces)
            let bundle = (row.bundle_id ?? "").trimmingCharacters(in: .whitespaces)
            return UninstallApp(
                name: row.name,
                bundleId: isRealBundleId(bundle) ? bundle : nil,
                source: row.source ?? "App",
                uninstallName: row.uninstall_name ?? row.name,
                path: row.path,
                sizeText: size,
                bytes: ByteSize.parse(size)
            )
        }
    }

    private static func isRealBundleId(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased() != "unknown"
    }

    private static func extractArray(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { $0.hasPrefix("[") }),
              let last = lines.lastIndex(where: { $0.hasSuffix("]") }),
              last >= first
        else { return nil }
        return lines[first...last].joined(separator: "\n")
    }
}
