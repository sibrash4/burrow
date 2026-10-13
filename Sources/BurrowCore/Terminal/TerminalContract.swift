// Contract for running Mole. Implemented by the Terminal module (ProcessRunner, PTYSession).
// Job engines depend only on these protocols so they can be tested with fakes.

import Foundation

public protocol CommandRunning: Sendable {
    /// Runs `mo <args>` non-interactively (stdin = /dev/null, NO_COLOR=1).
    /// Returns exit code and combined stdout+stderr with ANSI codes stripped.
    func run(_ args: [String], environment: [String: String]) async throws -> (exitCode: Int32, output: String)
}

/// A live `mo` process attached to a pseudo-terminal, for Mole's interactive menus and prompts.
public protocol InteractiveSession: AnyObject, Sendable {
    /// Writes raw bytes to the terminal, e.g. `TerminalKey.down`.
    func send(_ keys: String) throws
    /// Text of the most recently drawn screen frame (after the last clear/home), ANSI stripped, lines trimmed.
    func currentFrame() -> String
    /// Everything printed so far, ANSI stripped.
    func transcript() -> String
    /// Polls `currentFrame()` until `predicate` is true. Throws `BurrowError.timeout` otherwise.
    func waitForFrame(timeout: TimeInterval, _ predicate: @escaping @Sendable (String) -> Bool) async throws -> String
    /// Stripped output lines as they arrive, for the live log.
    var lines: AsyncStream<String> { get }
    /// Waits for the process to exit and returns its exit code.
    func waitForExit(timeout: TimeInterval) async throws -> Int32
    /// Sends SIGTERM, then SIGKILL after a grace period.
    func terminate()
}

public protocol InteractiveLaunching: Sendable {
    /// Starts `mo <args>` in a PTY of the given size.
    func launch(_ args: [String], environment: [String: String], columns: Int, rows: Int) throws -> InteractiveSession
}

public enum TerminalKey {
    public static let up = "\u{1B}[A"
    public static let down = "\u{1B}[B"
    public static let space = " "
    public static let enter = "\r"
    public static let quit = "q"
}
