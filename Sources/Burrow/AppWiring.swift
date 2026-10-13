import Foundation
import BurrowCore

/// The one place that decides which engine backs each sidebar entry and how the app starts.
/// Real engines only here; `MockJob` is used for previews and snapshots, and for the one placeholder below.
enum AppWiring {
    /// Everything the app needs, built once at launch.
    @MainActor
    static func makeModel() -> AppModel {
        // 1. Crash recovery comes before anything else touches Mole: if a previous run died with the
        //    whitelist half-edited, put the user's own file back first.
        let recovery = recoverWhitelist()

        // 2. Is Mole there, and is it the version Burrow was built for?
        let locator = MoleLocator()
        let status = moleStatus(locator)

        // 3. Real jobs.
        let runner = ProcessRunner(locator: locator)
        let launcher = PTYLauncher(locator: locator)
        let clean = CleanJob(runner: runner, launcher: launcher)
        let uninstall = UninstallJob(runner: runner, launcher: launcher)
        let jobs: [JobKind: MoleJob] = [
            .clean: clean,
            .purge: PurgeJob(runner: runner, launcher: launcher),
            .installers: InstallerJob(launcher: launcher),
            .uninstall: uninstall,
            .aiLeftovers: aiLeftoversPlaceholder(),
        ]

        let model = AppModel(
            jobs: jobs,
            moleStatus: status,
            // "Always keep" is a Mole whitelist entry, so it only exists for Clean rows.
            alwaysKeep: { item in
                do { try clean.alwaysKeep(item) } catch { NSLog("Burrow: could not save always-keep for %@: %@", item.title, "\(error)") }
            },
            previewLeftovers: { item in
                try await uninstall.previewLeftovers(for: item).map(Leftover.init(previewLine:))
            },
            locateMole: { await Task.detached { moleStatus(MoleLocator()) }.value }
        )
        model.startupNotice = recovery
        return model
    }

    // MARK: Pieces

    /// Restores the whitelist from Burrow's backup if a previous clean was interrupted.
    /// Returns a message for the user only when something went wrong or something was restored.
    static func recoverWhitelist() -> String? {
        do {
            return try WhitelistTransaction.recoverIfNeeded()
                ? "Burrow restored your Mole whitelist after an interrupted clean."
                : nil
        } catch {
            NSLog("Burrow: whitelist recovery failed: %@", "\(error)")
            return "Burrow could not restore your Mole whitelist: \(error.localizedDescription)"
        }
    }

    /// .missing / .versionMismatch / .ready from `MoleLocator.detect()`.
    nonisolated static func moleStatus(_ locator: MoleLocator) -> MoleStatus {
        do {
            let install = try locator.detect()
            return install.isSupported ? .ready : .versionMismatch(install.version?.description ?? "unknown")
        } catch {
            return .missing
        }
    }

    // MARK: AI leftovers placeholder

    /// TODO(agent/ai): the AI leftovers engine lives on branch agent/ai and is not merged yet.
    /// Until it lands the sidebar entry is backed by a MockJob. Replace this function's body with the real
    /// job (and delete `SampleDataJob`) when agent/ai is merged. This is the only place that needs to change.
    static func aiLeftoversPlaceholder() -> MoleJob {
        SampleDataJob(base: MockJob(kind: .aiLeftovers))
    }
}

/// Wraps a MockJob so the sample rows are clearly labelled. The mock run only simulates; it touches no files.
struct SampleDataJob: MoleJob {
    var base: MockJob
    var kind: JobKind { base.kind }

    func scan() async throws -> ScanResult {
        var result = try await base.scan()
        result.notes.insert("Sample data. The AI leftovers engine isn't connected yet, so nothing here is real and nothing will be removed.", at: 0)
        return result
    }

    func run(selection: Set<ScanItem.ID>, from scan: ScanResult) -> AsyncThrowingStream<JobEvent, Error> {
        base.run(selection: selection, from: scan)
    }
}

extension Leftover {
    /// Maps a line from `UninstallJob.previewLeftovers`: "~/Library/Caches/org.herf.Flux, 135KB" or a bare path.
    init(previewLine line: String) {
        if let comma = line.range(of: ", ", options: .backwards), let bytes = ByteSize.parse(String(line[comma.upperBound...])) {
            self.init(path: String(line[..<comma.lowerBound]), bytes: bytes)
        } else {
            self.init(path: line, bytes: nil)
        }
    }
}
