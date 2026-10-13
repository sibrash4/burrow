import XCTest
@testable import BurrowCore

final class ProcessRunnerTests: XCTestCase {
    private func sh() -> ProcessRunner { ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh")) }

    func testEchoOutputAndExitCode() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/echo"))
        let result = try await runner.run(["hello", "world"], environment: [:])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "hello world\n")
    }

    func testNonZeroExitIsReturnedNotThrown() async throws {
        let result = try await sh().run(["-c", "echo bad; exit 3"], environment: [:])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.output, "bad\n")
    }

    func testCombinesStdoutAndStderr() async throws {
        let result = try await sh().run(["-c", "echo out; echo err >&2"], environment: [:])
        XCTAssertEqual(Set(result.output.split(separator: "\n")), ["out", "err"])
    }

    func testStripsANSIFromOutput() async throws {
        let result = try await sh().run(["-c", #"printf '\033[1;32mok\033[0m\r\nline\r\n'"#], environment: [:])
        XCTAssertEqual(result.output, "ok\nline\n")
    }

    func testStdinIsDevNull() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/cat"))
        let result = try await runner.run([], environment: [:])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "")
    }

    func testEnvironmentAddsNoColorAndKeepsHome() async throws {
        let result = try await sh().run(["-c", #"echo "NO_COLOR=$NO_COLOR HOME=$HOME EXTRA=$EXTRA""#], environment: ["EXTRA": "1"])
        XCTAssertEqual(result.output, "NO_COLOR=1 HOME=\(NSHomeDirectory()) EXTRA=1\n")
    }

    func testPathIncludesHomebrewWhenParentPathIsMinimal() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let result = try await runner.run(["-c", "echo $PATH"], environment: [:])
        XCTAssertEqual(result.output, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await sh().run(["-c", "head -c 3000000 /dev/zero | tr '\\0' 'a'; echo; echo done"], environment: [:])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasSuffix("\ndone\n"))
        XCTAssertEqual(result.output.utf8.count, 3_000_000 + 1 + 5)
    }

    func testMissingExecutableThrowsMoleNotFound() async {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/nonexistent/mo"))
        do {
            _ = try await runner.run([], environment: [:])
            XCTFail("expected moleNotFound")
        } catch BurrowError.moleNotFound {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testLocatorBackedRunnerThrowsWhenMoleMissing() async {
        let runner = ProcessRunner(locator: MoleLocator(candidates: ["/nonexistent/mo"], searchPATH: false))
        do {
            _ = try await runner.run(["--version"])
            XCTFail("expected moleNotFound")
        } catch BurrowError.moleNotFound {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCancellationTerminatesProcess() async throws {
        let runner = sh()
        let started = Date()
        let task = Task { try await runner.run(["-c", "sleep 30"], environment: [:]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch BurrowError.cancelled {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// F20: cancel must signal the whole process group. A helper started by the shell used to survive cancellation,
    /// and it kept the output pipe open, so the cancelled run did not resume until that helper exited.
    func testCancellationKillsHelpersInTheProcessGroup() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("helper.pid")
        let runner = sh()
        let task = Task {
            try await runner.run(["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"], environment: [:])
        }

        var helper: pid_t = 0
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                helper = value
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThan(helper, 0, "helper pid was never written")

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch BurrowError.cancelled {
        } catch {
            XCTFail("\(error)")
        }
        // SIGTERM must reach the group at once. A helper that ignored it would only die at the 2 s SIGKILL.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "cancel should stop the group with SIGTERM, not SIGKILL")

        // The helper was in the cancelled group, so it must be gone. launchd reaps it, so allow a short wait.
        var gone = false
        for _ in 0..<120 {
            if kill(helper, 0) == -1 && errno == ESRCH { gone = true; break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(gone, "helper \(helper) survived cancellation")
    }

    /// A helper that leaves the process group (setsid) keeps the output pipe open. Cancelling must still resume
    /// the call promptly instead of waiting for that helper to exit (it sleeps 30 s).
    func testCancelResumesWhenAHelperEscapesTheGroup() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("escapee.pid")
        let runner = sh()
        let script = "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec \"sleep\", \"30\"' & echo $! > '\(pidFile.path)'; wait"
        let task = Task { try await runner.run(["-c", script], environment: [:]) }

        var escapee: pid_t = 0
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                escapee = value
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        defer { if escapee > 0 { kill(escapee, SIGKILL) } }
        XCTAssertGreaterThan(escapee, 0, "escapee pid was never written")

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch BurrowError.cancelled {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancelled run waited for a helper outside the group")
    }

    func testCancelledBeforeStartDoesNotRun() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let runner = sh()
        let task = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            return try await runner.run(["-c", "touch '\(marker.path)'"], environment: [:])
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
