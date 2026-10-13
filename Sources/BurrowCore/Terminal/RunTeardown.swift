import Foundation

/// Tracks engine runs until their teardown is finished: Mole has exited and any whitelist edit is restored.
///
/// Stopping a run cancels the consumer of its stream, and that returns at once, while the engine is still
/// killing Mole and putting files back. `begin` is called from `run(...)`, synchronously, so a stop that
/// follows always finds the run. `end` is called when the engine's own cleanup is done. The UI waits in
/// `waitUntilIdle` before it reports a stop, and the app waits there before it quits.
public final class RunTeardown: @unchecked Sendable {
    public static let shared = RunTeardown()

    private let lock = NSLock()
    private var active: [JobKind: Int] = [:]
    private var settled: [JobKind: RunResult] = [:]

    public init() {}

    /// Call synchronously when a run starts, before its work begins.
    public func begin(_ kind: JobKind) {
        lock.withLock {
            active[kind, default: 0] += 1
            settled[kind] = nil
        }
    }

    /// Call when the run has torn down. `result` is what the run got done before it ended, if anything.
    public func end(_ kind: JobKind, result: RunResult? = nil) {
        lock.withLock {
            let left = (active[kind] ?? 1) - 1
            active[kind] = left > 0 ? left : nil
            if let result { settled[kind] = result }
        }
    }

    public func isActive(_ kind: JobKind) -> Bool {
        lock.withLock { (active[kind] ?? 0) > 0 }
    }

    /// Returns once no run of `kind` is still tearing down, or after `timeout` seconds, or when the caller is cancelled.
    public func waitUntilIdle(_ kind: JobKind, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isActive(kind), Date() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
    }

    /// What the last run of `kind` got done, if it reported anything when it ended. Clears it.
    public func takeResult(_ kind: JobKind) -> RunResult? {
        lock.withLock { settled.removeValue(forKey: kind) }
    }
}

extension RunTeardown {
    /// True when an error means the user pressed Stop (or the run was cancelled), not that Mole failed.
    static func isStop(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case BurrowError.cancelled = error { return true }
        return false
    }
}

extension InteractiveSession {
    /// Sends SIGTERM (SIGKILL after a grace period) and waits for Mole to exit. The wait runs detached,
    /// so it still happens when the calling task has already been cancelled.
    public func terminateAndWait(seconds: TimeInterval = 4) async {
        terminate()
        let session = self
        _ = await Task.detached { try? await session.waitForExit(timeout: seconds) }.value
    }
}
