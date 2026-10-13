import XCTest
@testable import BurrowCore

final class PTYSessionTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func launch(_ script: String, columns: Int = 100, rows: Int = 30) throws -> InteractiveSession {
        try PTYLauncher(executable: shell).launch(["-c", script], environment: [:], columns: columns, rows: rows)
    }

    func testPromptAnswerRoundTrip() async throws {
        let session = try launch(#"printf "\033[2J\033[HQ? "; read x; echo "got $x""#)
        let frame = try await session.waitForFrame(timeout: 5) { $0.contains("Q?") }
        XCTAssertEqual(frame, "Q?")
        try session.send("y\r")
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(session.transcript().contains("got y"), session.transcript())
        XCTAssertEqual(session.currentFrame(), "Q? y\ngot y")
    }

    func testReadsFromDevTTY() async throws {
        let session = try launch("read x < /dev/tty; echo $x")
        try await Task.sleep(nanoseconds: 200_000_000)
        try session.send("hello\r")
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(session.transcript().contains("hello"))
    }

    func testPtyIsControllingTerminal() async throws {
        let session = try launch("ps -o tty= -p $$; [ -r /dev/tty ] && echo has-ctty")
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(session.transcript().contains("has-ctty"), session.transcript())
    }

    func testWindowSizeAndTerm() async throws {
        let session = try launch(#"stty size; echo "TERM=$TERM""#, columns: 91, rows: 27)
        _ = try await session.waitForExit(timeout: 5)
        let transcript = session.transcript()
        XCTAssertTrue(transcript.contains("27 91"), transcript)
        XCTAssertTrue(transcript.contains("TERM=xterm-256color"), transcript)
    }

    func testExitCode() async throws {
        let session = try launch("exit 7")
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 7)
    }

    func testFrameFollowsPartialRedrawLikeMolesMenus() async throws {
        let script = #"stty -echo; printf "\033[2J\033[HTitle 0 selected\r\n  [ ] one\r\n  [ ] two\r\n"; read x; printf "\033[2;1H\033[2K> [x] one\033[5;1H\033[2K1 selected"; read y"#
        let session = try launch(script)
        _ = try await session.waitForFrame(timeout: 5) { $0.contains("[ ] two") }
        try session.send("a\r")
        let frame = try await session.waitForFrame(timeout: 5) { $0.contains("1 selected") }
        XCTAssertEqual(frame, "Title 0 selected\n> [x] one\n  [ ] two\n\n1 selected")
        try session.send("b\r")
        _ = try await session.waitForExit(timeout: 5)
    }

    func testWaitForFrameTimesOut() async throws {
        let session = try launch("sleep 30")
        defer { session.terminate() }
        do {
            _ = try await session.waitForFrame(timeout: 0.3) { $0.contains("never") }
            XCTFail("expected timeout")
        } catch BurrowError.timeout {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testWaitForFrameFailsFastWhenProcessEnds() async throws {
        let session = try launch("echo bye; exit 2")
        do {
            _ = try await session.waitForFrame(timeout: 10) { $0.contains("never") }
            XCTFail("expected failure")
        } catch BurrowError.processFailed(let code, let output) {
            XCTAssertEqual(code, 2)
            XCTAssertTrue(output.contains("bye"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testWaitForExitTimesOut() async throws {
        let session = try launch("sleep 30")
        defer { session.terminate() }
        do {
            _ = try await session.waitForExit(timeout: 0.3)
            XCTFail("expected timeout")
        } catch BurrowError.timeout {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testLinesStreamYieldsStrippedLines() async throws {
        let session = try launch(#"printf '\033[1mfirst\033[0m\nsecond\npartial'"#)
        var received: [String] = []
        for await line in session.lines { received.append(line) }
        XCTAssertEqual(received, ["first", "second", "partial"])
    }

    func testTerminateStopsProcess() async throws {
        let session = try launch("sleep 30")
        let started = Date()
        session.terminate()
        let code = try await session.waitForExit(timeout: 5)
        XCTAssertEqual(code, 128 + SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testTerminateKillsProcessThatIgnoresSIGTERM() async throws {
        let session = try launch(#"trap '' TERM; echo ready; while :; do sleep 1; done"#)
        _ = try await session.waitForFrame(timeout: 5) { $0.contains("ready") }
        session.terminate()
        let code = try await session.waitForExit(timeout: 6)
        XCTAssertEqual(code, 128 + SIGKILL)
    }

    func testSendAfterExitThrows() async throws {
        let session = try launch("true")
        _ = try await session.waitForExit(timeout: 5)
        XCTAssertThrowsError(try session.send("x"))
    }

    func testUTF8SplitAcrossReadsIsIntact() {
        let bytes = Array("a●".utf8)
        XCTAssertEqual(PTYSession.completeUTF8Length(bytes), bytes.count)
        XCTAssertEqual(PTYSession.completeUTF8Length(Array(bytes.dropLast())), 1)
        XCTAssertEqual(PTYSession.completeUTF8Length(Array(bytes.dropLast(2))), 1)
        XCTAssertEqual(PTYSession.completeUTF8Length([]), 0)
    }

    func testUnicodeOutputAndArrowKeys() async throws {
        let session = try launch(#"printf '\342\227\213 item\r\n'; IFS= read -r -n 3 k; printf '%s' "$k" | od -c | head -1"#)
        _ = try await session.waitForFrame(timeout: 5) { $0.contains("○ item") }
        try session.send(TerminalKey.down)
        _ = try await session.waitForExit(timeout: 5)
        XCTAssertTrue(session.transcript().contains("033"), session.transcript())
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try PTYLauncher(executable: URL(fileURLWithPath: "/nonexistent/mo")).launch([], environment: [:], columns: 80, rows: 24)) {
            guard case BurrowError.moleNotFound = $0 else { return XCTFail("\($0)") }
        }
    }

    func testLocatorBackedLauncherThrowsWhenMoleMissing() {
        let launcher = PTYLauncher(locator: MoleLocator(candidates: ["/nonexistent/mo"], searchPATH: false))
        XCTAssertThrowsError(try launcher.launch([], environment: [:], columns: 80, rows: 24)) {
            guard case BurrowError.moleNotFound = $0 else { return XCTFail("\($0)") }
        }
    }
}
