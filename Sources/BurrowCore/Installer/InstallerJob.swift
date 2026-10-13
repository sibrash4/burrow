import Foundation

/// `mo installer`: lists leftover .dmg/.pkg/.zip files and removes the ticked ones through Mole's own menu.
public struct InstallerJob: MoleJob {
    public let kind = JobKind.installers
    private let launcher: InteractiveLaunching
    private let driver: MoleMenuDriver
    /// What `run` launches. Tests swap in `--dry-run` for live checks; the app always uses the default.
    var runArguments = ["installer"]

    public init(launcher: InteractiveLaunching, driver: MoleMenuDriver = MoleMenuDriver()) {
        self.launcher = launcher
        self.driver = driver
    }

    /// Mole's "Great! No installer files to clean". Not "No installer files": the dry-run banner already
    /// says "No installer files will be removed", which would match at once and hide the whole list.
    static let nothingFoundMarker = "No installer files to clean"

    /// Opens `mo installer --dry-run` in a PTY, reads every page of the menu, then quits with q.
    /// Mole prints only the first page when it has no terminal, so a PTY is needed for the full list.
    public func scan() async throws -> ScanResult {
        let session = try launcher.launch(["installer", "--dry-run"], environment: MenuSession.environment,
                                          columns: MenuSession.columns, rows: MenuSession.rows)
        defer { session.terminate() }

        let seen = try await MenuSession.transcriptWait(session, timeout: 120) {
            $0.contains(MenuFrame.installerTitle) || $0.contains(Self.nothingFoundMarker)
        }
        if !seen.contains(MenuFrame.installerTitle) {
            return ScanResult(kind: .installers, groups: [])
        }
        do {
            let entries = try await driver.readAllRows(in: session)
            driver.quit(session)
            _ = try? await session.waitForExit(timeout: 5)
            return InstallerParser.scanResult(entries: entries)
        } catch {
            driver.quit(session)
            throw error
        }
    }

    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        let items = scan.allItems.filter { $0.selectable && selection.contains($0.id) }
        let spec = MenuRunSpec(
            args: runArguments, label: "Removing installers",
            checkConfirm: { InstallerParser.checkConfirm(screen: $0, wanted: items) },
            summarize: { InstallerParser.summarize(log: $0, exitCode: $1) })
        return MenuJobRun.stream(spec: spec, wanted: items.map(\.id), launcher: launcher, driver: driver,
                                 idleResult: RunResult(itemCount: 0, exitCode: 0, log: ""))
    }
}
