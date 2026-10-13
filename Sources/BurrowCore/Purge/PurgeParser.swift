import Foundation

public struct PurgeListing: Equatable, Sendable {
    public struct Found: Equatable, Sendable {
        /// Path as Mole prints it: "~/dev/app/node_modules", or "[cloud] ~/..." for cloud storage.
        public var path: String
        /// nil when Mole could not measure it ("unknown").
        public var bytes: Int64?
    }
    public struct Skipped: Equatable, Sendable {
        public var path: String
        public var isCloud: Bool
        public var reason: String
    }
    public var found: [Found] = []
    public var skipped: [Skipped] = []
    public var reportedTotalBytes: Int64?
    public var warnings: [String] = []
}

public enum PurgeParser {
    /// Parses the non-interactive `mo purge --dry-run` output (ANSI already stripped).
    public static func parseListing(_ output: String) -> PurgeListing {
        var listing = PurgeListing()
        for raw in MenuSession.logLines(output) {
            if raw.hasPrefix("✓ [DRY RUN] ") {
                let rest = String(raw.dropFirst("✓ [DRY RUN] ".count))
                guard let comma = rest.range(of: ", ", options: .backwards) else { continue }
                listing.found.append(.init(path: String(rest[..<comma.lowerBound]),
                                           bytes: ByteSize.parse(String(rest[comma.upperBound...]))))
            } else if raw.hasPrefix("◎ Skipped ") {
                var rest = String(raw.dropFirst("◎ Skipped ".count))
                let isCloud = rest.hasPrefix("[cloud] ")
                if isCloud { rest = String(rest.dropFirst("[cloud] ".count)) }
                var reason = ""
                if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
                    reason = String(rest[open.upperBound...].dropLast())
                    rest = String(rest[..<open.lowerBound])
                }
                listing.skipped.append(.init(path: rest, isCloud: isCloud, reason: reason))
            } else if let m = raw.firstMatch(of: #/Would free approximately: (\S+)/#) {
                listing.reportedTotalBytes = ByteSize.parse(String(m.1))
            } else if raw.hasPrefix("◎ Could not measure") || raw.hasPrefix("Could not measure") {
                listing.warnings.append(raw.hasPrefix("◎") ? String(raw.dropFirst(2)) : raw)
            }
        }
        return listing
    }

    /// Groups by artifact type (the last folder name: node_modules, .next, dist, .venv, target, __pycache__...).
    public static func scanResult(listing: PurgeListing, home: String, now: Date = .now) -> ScanResult {
        func item(path: String, bytes: Int64?, skip: PurgeListing.Skipped?) -> (type: String, item: ScanItem) {
            let display = path
            let plain = display.hasPrefix("[cloud] ") ? String(display.dropFirst(8)) : display
            let parts = plain.split(separator: "/").map(String.init)
            let type = parts.last ?? plain
            let project = parts.dropLast().suffix(2).joined(separator: "/")
            let expanded = plain.hasPrefix("~") ? home + plain.dropFirst() : plain
            let note: String? = skip.map { $0.isCloud ? "In cloud storage; Mole skips it" : "Skipped: \($0.reason)" }
            return (type, ScanItem(id: display, title: project.isEmpty ? plain : project, detail: display, bytes: bytes,
                                   paths: [expanded], selectable: skip == nil, selectedByDefault: skip == nil, note: note))
        }

        var byType: [String: [ScanItem]] = [:]
        for f in listing.found {
            let r = item(path: f.path, bytes: f.bytes, skip: nil)
            byType[r.type, default: []].append(r.item)
        }
        for s in listing.skipped {
            let r = item(path: s.isCloud ? "[cloud] \(s.path)" : s.path, bytes: nil, skip: s)
            byType[r.type, default: []].append(r.item)
        }
        let groups = byType.map { type, items in
            ScanGroup(id: type, title: type, items: items.sorted { ($0.bytes ?? -1, $1.id) > ($1.bytes ?? -1, $0.id) })
        }.sorted { ($0.totalBytes, $1.id) > ($1.totalBytes, $0.id) }

        var notes: [String] = listing.warnings
        let cloud = listing.skipped.filter(\.isCloud).count
        if cloud > 0 { notes.append("\(cloud) in cloud storage \(cloud == 1 ? "was" : "were") skipped.") }
        let other = listing.skipped.count - cloud
        if other > 0 { notes.append("\(other) skipped by Mole.") }
        return ScanResult(kind: .purge, groups: groups, reportedTotalBytes: listing.reportedTotalBytes, notes: notes, scannedAt: now)
    }

    /// "Estimated space freed: 1.20GB | Items: 3 | Free: ..." plus any "◎ Skipped ..." lines.
    public static func summarize(log: String, exitCode: Int32) -> RunResult {
        var freed: Int64?
        var count: Int?
        var problems: [String] = []
        for line in MenuSession.logLines(log) {
            if let m = line.firstMatch(of: #/(?:Estimated space freed|Would free approximately): (\S+)/#) {
                freed = ByteSize.parse(String(m.1))
                if let items = line.firstMatch(of: #/Items: (\d+)/#) { count = Int(items.1) }
            } else if line.hasPrefix("◎") {
                problems.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("No artifacts were removed") {
                count = 0
            }
        }
        return RunResult(freedBytes: freed, itemCount: count, problems: problems, exitCode: exitCode, log: log)
    }

    /// Checks the "Selected paths:" list and the "Remove N artifacts" prompt against the request.
    static func checkConfirm(screen: String, wanted: [String]) -> String? {
        let lines = screen.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? "" }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Selected paths:" }),
              let prompt = lines.compactMap({ $0.firstMatch(of: #/Remove (\d+) artifacts?, /#) }).last,
              let count = Int(prompt.1) else { return "no confirm prompt" }
        var paths: [String] = []
        for line in lines[(start + 1)...] {
            guard line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            paths.append(line.trimmingCharacters(in: .whitespaces))
        }
        guard count == wanted.count else { return "\(count) artifacts" }
        guard Set(paths) == Set(wanted), paths.count == wanted.count else {
            return "different folders than selected: \(paths.sorted().joined(separator: "; "))"
        }
        return nil
    }
}
