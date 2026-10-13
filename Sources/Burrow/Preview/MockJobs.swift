import Foundation
import BurrowCore

/// Synthetic jobs for the UI shell. Sizes and names follow the real Mole fixtures.
struct MockJob: MoleJob {
    var kind: JobKind
    var scanDelay: Duration = .milliseconds(900)
    var stepDelay: Duration = .milliseconds(450)
    var failScan = false
    var empty = false

    func scan() async throws -> ScanResult {
        try await Task.sleep(for: scanDelay)
        if failScan { throw BurrowError.timeout("mo \(kind.rawValue) --dry-run") }
        if empty { return ScanResult(kind: kind, groups: [], notes: []) }
        return MockData.scan(kind)
    }

    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        let steps = scan.groups.compactMap { group -> (String, [ScanItem])? in
            let items = group.items.filter { selection.contains($0.id) }
            return items.isEmpty ? nil : (group.title, items)
        }
        let delay = stepDelay
        let kind = kind
        return AsyncThrowingStream { continuation in
            let task = Task {
                var freed: Int64 = 0
                var count = 0
                for (title, items) in steps {
                    continuation.yield(.status(kind == .uninstall ? "Removing \(title)" : "Cleaning \(title)"))
                    for item in items {
                        try await Task.sleep(for: delay)
                        freed += item.bytes ?? 0
                        count += item.count ?? 1
                        let size = item.bytes.map(ByteSize.format) ?? "done"
                        continuation.yield(.line("  \(kind == .uninstall ? "Moved to Trash" : "Removed") \(item.title)  \(size)"))
                    }
                }
                let problems = kind == .clean ? ["Chrome Service Worker: 1 file was in use and was skipped."] : []
                continuation.yield(.finished(RunResult(freedBytes: freed, itemCount: count, problems: problems, exitCode: 0, log: "")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum MockData {
    static func jobs(failScan: Bool = false) -> [JobKind: MoleJob] {
        Dictionary(uniqueKeysWithValues: JobKind.allCases.map { ($0, MockJob(kind: $0, failScan: failScan && $0 == .clean) as MoleJob) })
    }

    static func scan(_ kind: JobKind) -> ScanResult {
        switch kind {
        case .clean: clean
        case .purge: purge
        case .installers: installers
        case .uninstall: uninstall
        case .aiLeftovers: aiLeftovers
        }
    }

    static func leftovers(for item: ScanItem) -> [Leftover] {
        let name = item.title
        let id = item.id
        return [
            Leftover(path: "/Users/test/Library/Application Support/\(name)", bytes: 84_300_000),
            Leftover(path: "/Users/test/Library/Caches/\(id)", bytes: 31_200_000),
            Leftover(path: "/Users/test/Library/Preferences/\(id).plist", bytes: 12_000),
            Leftover(path: "/Users/test/Library/Saved Application State/\(id).savedState", bytes: 420_000),
            Leftover(path: "/Users/test/Library/Logs/\(name)", bytes: 1_800_000),
        ]
    }

    private static func item(_ id: String, _ title: String, _ detail: String? = nil, bytes: Int64? = nil, count: Int? = nil,
                             paths: [String] = [], selectable: Bool = true, defaultOn: Bool = true, note: String? = nil) -> ScanItem {
        ScanItem(id: id, title: title, detail: detail, bytes: bytes, count: count, paths: paths.isEmpty ? (detail.map { [$0] } ?? []) : paths,
                 selectable: selectable, selectedByDefault: defaultOn, note: note)
    }

    static let clean = ScanResult(
        kind: .clean,
        groups: [
            ScanGroup(id: "user", title: "User essentials", items: [
                item("user-cache", "User app cache", "~/Library/Caches", bytes: 1_200_000_000, count: 17,
                     paths: ["/Users/test/Library/Caches/Google", "/Users/test/Library/Caches/Homebrew", "/Users/test/Library/Caches/editor-updater", "/Users/test/Library/Caches/claude-cli-nodejs"]),
                item("user-logs", "User app logs", "~/Library/Logs", bytes: 7_000_000, count: 103),
                item("trash", "Trash", "~/.Trash", count: 58, defaultOn: false),
            ]),
            ScanGroup(id: "browsers", title: "Browsers", items: [
                item("chrome-cache", "Chrome cache", "~/Library/Caches/Google/Chrome", bytes: 642_200_000,
                     paths: ["/Users/test/Library/Caches/Google/Chrome/Default/Cache", "/Users/test/Library/Caches/Google/Chrome/Default/Code Cache"]),
                item("chrome-sw", "Chrome Service Worker", "~/Library/Application Support/Google/Chrome/Default", bytes: 1_040_000_000),
            ]),
            ScanGroup(id: "dev", title: "Developer tools", items: [
                item("xcode-dd", "Xcode DerivedData", "5 projects", bytes: 554_500_000, count: 5),
                item("zed-npm", "Zed npm cache", "~/Library/Caches/Zed", bytes: 293_500_000, count: 3),
                item("clang", "Clang module cache", "~/Library/Caches/clang", bytes: 220_400_000),
                item("next", "Next.js build cache", "4 items", bytes: 144_800_000, count: 4),
                item("cargo", "Rust cargo cache", "~/.cargo/registry/cache", bytes: 51_100_000),
                item("swiftpm", "Swift package manager library cache", nil, bytes: 5_500_000, count: 5),
                item("brew", "Homebrew cache", "~/Library/Caches/Homebrew", bytes: 4_100_000, count: 2),
                item("claude-logs", "Claude logs", "~/Library/Logs/Claude", bytes: 1_600_000, count: 9),
            ]),
            ScanGroup(id: "apps", title: "Apps and utilities", items: [
                item("slack", "Slack cache", "~/Library/Application Support/Slack/Cache", bytes: 18_300_000, count: 2),
                item("wallpaper", "Wallpaper aerials temp files", nil, bytes: 99_900_000, count: 2),
                item("system-caches", "System caches", "/Library/Caches", selectable: false, defaultOn: false, note: "Needs admin"),
            ]),
        ],
        reportedTotalBytes: 4_320_000_000,
        notes: ["System caches need admin access, so Mole skipped them. Everything else is shown below."]
    )

    static let purge = ScanResult(
        kind: .purge,
        groups: [
            ScanGroup(id: "tracker", title: "tracker-app", items: [
                item("t1", "client/node_modules", "~/dev/tracker-app/hc-dashboard/client", bytes: 54_300_000),
                item("t2", "server/node_modules", "~/dev/tracker-app/hc-dashboard/server", bytes: 4_200_000),
                item("t3", "client/dist", "~/dev/tracker-app/client", bytes: 250_000),
            ]),
            ScanGroup(id: "news", title: "newsletter-site", items: [
                item("n1", ".next", "~/dev/newsletter-site", bytes: 57_300_000),
                item("n2", "node_modules", "~/dev/newsletter-site", bytes: 612_000_000),
            ]),
            ScanGroup(id: "notes", title: "notes-tool", items: [
                item("v1", ".venv", "~/dev/notes-tool", bytes: 183_000_000),
                item("v2", "__pycache__", "~/dev/notes-tool/src", bytes: 1_200_000),
            ]),
        ],
        notes: ["Folders inside cloud storage were skipped."]
    )

    static let installers = ScanResult(
        kind: .installers,
        groups: [
            ScanGroup(id: "downloads", title: "Downloads", items: [
                item("i1", "Notes.dmg", "Downloads", bytes: 72_000_000, defaultOn: false),
                item("i2", "Bartender 7.dmg", "Downloads", bytes: 60_800_000, defaultOn: false),
                item("i3", "Bartender 6.dmg", "Downloads", bytes: 54_700_000, defaultOn: false),
                item("i4", "Ghostty.dmg", "Downloads", bytes: 33_800_000, defaultOn: false),
                item("i5", "BetterDisplay-v5.1.1.dmg", "Downloads", bytes: 29_200_000, defaultOn: false),
                item("i6", "Mole.dmg", "Downloads", bytes: 27_300_000, defaultOn: false),
                item("i7", "1Password.zip", "Downloads", bytes: 21_800_000, defaultOn: false),
                item("i8", "Flux.zip", "Downloads", bytes: 2_100_000, defaultOn: false),
            ]),
        ]
    )

    static let aiLeftovers = ScanResult(
        kind: .aiLeftovers,
        groups: [
            ScanGroup(id: "worktrees", title: "Agent worktrees", items: [
                item("wt1", "feature-search (agent worktree)", "~/dev/tracker-app-wt/search, last used 45 days ago", bytes: 410_000_000),
            ]),
            ScanGroup(id: "transcripts", title: "Transcripts", items: [
                item("tr1", "Claude Code transcripts", "~/.claude/projects, older than 30 days", bytes: 96_000_000, count: 212, defaultOn: false),
            ]),
            ScanGroup(id: "models", title: "Model caches", items: [
                item("m1", "Hugging Face models", "~/.cache/huggingface", bytes: 3_100_000_000, defaultOn: false),
            ]),
        ]
    )

    static let uninstall = ScanResult(
        kind: .uninstall,
        groups: [
            ScanGroup(id: "apps", title: "Applications", items: [
                item("com.microsoft.powerpoint", "Microsoft PowerPoint", "Last used 5 months ago", bytes: 2_380_000_000, paths: ["/Applications/Microsoft PowerPoint.app"], defaultOn: false),
                item("com.microsoft.onenote", "Microsoft OneNote", "Last used 8 months ago", bytes: 1_420_000_000, paths: ["/Applications/Microsoft OneNote.app"], defaultOn: false),
                item("com.apple.garageband10", "GarageBand", "Last used over a year ago", bytes: 1_200_000_000, paths: ["/Applications/GarageBand.app"], defaultOn: false),
                item("com.microsoft.teams2", "Microsoft Teams", "Last used 2 weeks ago", bytes: 1_170_000_000, paths: ["/Applications/Microsoft Teams.app"], defaultOn: false),
                item("com.logi.pluginservice", "LogiPluginService", "Last used 3 months ago", bytes: 363_000_000, paths: ["/Applications/Utilities/LogiPluginService.app"], defaultOn: false),
                item("com.googlecode.iterm2", "iTerm2", "Last used today", bytes: 184_500_000, paths: ["/Applications/iTerm.app"], defaultOn: false),
                item("com.apple.Notes", "Notes", "Last used yesterday", bytes: 171_800_000, paths: ["/Applications/Notes.app"], defaultOn: false),
                item("com.numi.app", "Numi", "Last used 6 days ago", bytes: 47_000_000, paths: ["/Applications/Numi.app"], defaultOn: false),
            ]),
        ]
    )
}
