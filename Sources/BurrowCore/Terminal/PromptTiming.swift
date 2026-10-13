import Foundation

/// Mole flushes the terminal's input queue right after it prints a confirmation prompt
/// (`drain_pending_input`: a short sleep, then `tcflush`), so that a key typed during a slow scan can't
/// confirm something by accident. A key written in that instant is silently thrown away, and Mole then waits
/// for it forever. Seen live: `mo uninstall --dry-run Flux` sat at "Remove 1 app ... Enter confirm" for good
/// after Burrow pressed Enter within a few milliseconds of the prompt appearing.
///
/// So Burrow lets the screen go quiet before it answers a confirmation prompt. Resending a key instead would
/// be unsafe: a late first Enter plus a second Enter could confirm a screen Burrow never checked.
public enum PromptTiming {
    public static let defaultGrace: TimeInterval = 0.4

    /// Returns once the visible screen has not changed for `grace` seconds. Zero returns at once.
    static func waitUntilQuiet(_ session: InteractiveSession, grace: TimeInterval) async throws {
        guard grace > 0 else { return }
        var latest = session.currentFrame()
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < grace {
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { throw BurrowError.cancelled }
            let now = session.currentFrame()
            if now != latest { latest = now; quietSince = Date() }
        }
    }
}
