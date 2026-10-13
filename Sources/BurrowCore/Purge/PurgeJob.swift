import Foundation

/// `mo purge`: previews build artifacts with `--dry-run`, removes the ticked ones through Mole's own menu.
public struct PurgeJob: MoleJob {
    public let kind = JobKind.purge
    private let runner: CommandRunning
    private let launcher: InteractiveLaunching
    private let driver: MoleMenuDriver
    private let home: String
    /// What `run` launches. Tests swap in `--dry-run` for live checks; the app always uses the default.
    var runArguments = ["purge"]

    public init(runner: CommandRunning, launcher: InteractiveLaunching,
                driver: MoleMenuDriver = MoleMenuDriver(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.launcher = launcher
        self.driver = driver
        self.home = home
    }

    /// Runs `mo purge --dry-run`. Mole exits 1 when it skipped something, so the exit code alone is not an error.
    /// Artifacts changed in the last week are left out by Mole itself.
    public func scan() async throws -> ScanResult {
        let (code, output) = try await runner.run(["purge", "--dry-run"], environment: [:])
        let listing = PurgeParser.parseListing(output)
        let sawSomething = !listing.found.isEmpty || !listing.skipped.isEmpty
        if code != 0 && !sawSomething && !output.contains("No artifacts found") {
            throw BurrowError.processFailed(exitCode: code, output: output)
        }
        return PurgeParser.scanResult(listing: listing, home: home)
    }

    /// Item ids are the paths Mole prints on the menu's "Path:" line, which the driver reads for each row.
    public func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        let wanted = scan.allItems.filter { $0.selectable && selection.contains($0.id) }.map(\.id)
        let spec = MenuRunSpec(
            args: runArguments, label: "Removing build folders",
            checkConfirm: { PurgeParser.checkConfirm(screen: $0, wanted: wanted) },
            summarize: { PurgeParser.summarize(log: $0, exitCode: $1) })
        return MenuJobRun.stream(kind: kind, spec: spec, wanted: wanted, launcher: launcher, driver: driver,
                                 idleResult: RunResult(itemCount: 0, exitCode: 0, log: ""))
    }
}
