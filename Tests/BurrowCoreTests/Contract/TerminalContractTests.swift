import XCTest
@testable import BurrowCore

/// Checks what the job engines assume about PTYSession and ProcessRunner against the real implementations.
/// Each test names the assumption it protects.
final class TerminalContractTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func launch(_ script: String, environment: [String: String] = [:]) throws -> InteractiveSession {
        try PTYLauncher(executable: shell).launch(["-c", script], environment: environment, columns: 100, rows: 30)
    }

    // MARK: waitForExit(timeout:) times out without killing

    func testWaitForExitTimeoutThrowsTimeoutAndLeavesTheProcessRunning() async throws {
        let session = try launch(#"read x; echo "got $x""#)
        defer { session.terminate() }

        for _ in 0..<3 {
            do {
                _ = try await session.waitForExit(timeout: 0.15)
                XCTFail("the process is waiting for input, it can't have exited")
            } catch BurrowError.timeout {
            } catch {
                XCTFail("expected timeout, got \(error)")
            }
        }
        // Still alive and still answering: polling did not terminate it.
        try session.send("hello\r")
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(session.transcript().contains("got hello"), session.transcript())
    }

    // MARK: transcript() includes the line still being typed (prompts end without a newline)

    func testTranscriptIncludesAPromptThatHasNoNewline() async throws {
        let session = try launch(#"printf 'System caches need sudo. Enter continue, Space skip: '; read x"#)
        defer { session.terminate() }
        try await waitUntil { session.transcript().contains("Space skip:") }
        XCTAssertEqual(session.transcript().trimmingCharacters(in: .whitespaces), "System caches need sudo. Enter continue, Space skip:")
        // And the clean prompt detector, which only reads the transcript, sees it.
        XCTAssertEqual(CleanPrompt.detect(inTail: "\n➤ " + session.transcript()), .systemCaches)
    }

    func testTranscriptKeepsEarlierLinesAndTheOpenOne() async throws {
        let session = try launch(#"printf 'one\ntwo\nthree?'; read x"#)
        defer { session.terminate() }
        try await waitUntil { session.transcript().contains("three?") }
        XCTAssertEqual(session.transcript(), "one\ntwo\nthree?")
    }

    // MARK: environment merges into the parent environment

    func testLaunchEnvironmentMergesIntoTheParentEnvironment() async throws {
        setenv("BURROW_CONTRACT_PARENT", "from-parent", 1)
        defer { unsetenv("BURROW_CONTRACT_PARENT") }
        let session = try launch(#"echo "parent=$BURROW_CONTRACT_PARENT extra=$EXTRA home=$HOME""#, environment: ["EXTRA": "1"])
        _ = try await session.waitForExit(timeout: 5)
        let transcript = session.transcript()
        XCTAssertTrue(transcript.contains("parent=from-parent"), transcript)
        XCTAssertTrue(transcript.contains("extra=1"), transcript)
        XCTAssertFalse(transcript.contains("home= "), "HOME survives: \(transcript)")
    }

    func testRunEnvironmentMergesIntoTheBaseEnvironment() async throws {
        let runner = ProcessRunner(executable: shell, baseEnvironment: ["BURROW_CONTRACT_BASE": "from-base", "PATH": "/usr/bin:/bin"])
        let result = try await runner.run(["-c", #"echo "base=$BURROW_CONTRACT_BASE extra=$EXTRA""#], environment: ["EXTRA": "2"])
        XCTAssertTrue(result.output.contains("base=from-base extra=2"), result.output)
    }

    // MARK: Mole's test hooks never reach a real run

    func testMoleTestHooksAreStrippedFromTheInheritedEnvironment() async throws {
        setenv("MOLE_TEST_NO_AUTH", "1", 1)
        setenv("MOLE_TEST_MODE", "1", 1)
        defer { unsetenv("MOLE_TEST_NO_AUTH"); unsetenv("MOLE_TEST_MODE") }
        let session = try launch(#"echo "auth=[$MOLE_TEST_NO_AUTH] mode=[$MOLE_TEST_MODE]""#)
        _ = try await session.waitForExit(timeout: 5)
        XCTAssertTrue(session.transcript().contains("auth=[] mode=[]"), session.transcript())
    }

    func testMoleTestHooksPassedByACallerAreStrippedToo() async throws {
        let session = try launch(#"echo "auth=[$MOLE_TEST_NO_AUTH]""#, environment: ["MOLE_TEST_NO_AUTH": "1"])
        _ = try await session.waitForExit(timeout: 5)
        XCTAssertTrue(session.transcript().contains("auth=[]"), session.transcript())

        let runner = ProcessRunner(executable: shell, baseEnvironment: ["MOLE_TEST_NO_AUTH": "1", "PATH": "/usr/bin:/bin"])
        let result = try await runner.run(["-c", #"echo "auth=[$MOLE_TEST_NO_AUTH] mode=[$MOLE_TEST_MODE]""#], environment: ["MOLE_TEST_MODE": "1"])
        XCTAssertTrue(result.output.contains("auth=[] mode=[]"), result.output)
    }

    // MARK: waitForFrame / send after the process is gone

    func testWaitForFrameThrowsProcessFailedWithTheExitCodeEvenForCleanExit() async throws {
        let session = try launch("echo finished")
        do {
            _ = try await session.waitForFrame(timeout: 10) { $0.contains("never appears") }
            XCTFail("expected processFailed")
        } catch BurrowError.processFailed(let code, let output) {
            XCTAssertEqual(code, 0, "a clean exit is still reported as processFailed with code 0; callers decide what that means")
            XCTAssertTrue(output.contains("finished"))
        }
    }

    func testWaitForFrameStillReturnsWhenThePredicateHoldsOnTheLastFrame() async throws {
        let session = try launch("echo last words")
        let frame = try await session.waitForFrame(timeout: 10) { $0.contains("last words") }
        XCTAssertTrue(frame.contains("last words"))
    }

    func testSendAfterExitThrowsProcessFailedWithTheExitCode() async throws {
        let session = try launch("exit 4")
        _ = try await session.waitForExit(timeout: 5)
        XCTAssertThrowsError(try session.send("y")) { error in
            guard case BurrowError.processFailed(let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 4)
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
