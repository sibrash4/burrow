import Foundation
import XCTest
@testable import BurrowCore

/// Answers every command with the same canned result.
struct CannedShell: ShellRunning {
    var result: ShellResult

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        result
    }
}

final class AILeftoversShellTests: XCTestCase {
    private func provider(exit: Int32, stdout: String) -> LsofCwdProvider {
        LsofCwdProvider(shell: CannedShell(result: ShellResult(exitCode: exit, stdout: stdout)))
    }

    func testLsofExitStatusOtherThanZeroOrOneIsNotReadAsNoProcesses() async throws {
        // 2 is a real lsof error; 15 is what a timed-out, terminated lsof returns with its partial output.
        for status: Int32 in [2, 15] {
            do {
                _ = try await provider(exit: status, stdout: "p1\nfcwd\nn/tmp\n").currentWorkingDirectories()
                XCTFail("lsof exit \(status) must not be read as a complete process list")
            } catch let error as ProcessListError {
                XCTAssertEqual(error, .lsofFailed(status))
            }
        }
    }

    func testLsofWithEmptyOutputIsNotReadAsNoProcesses() async throws {
        for status: Int32 in [0, 1] {
            do {
                _ = try await provider(exit: status, stdout: "").currentWorkingDirectories()
                XCTFail("empty lsof output with exit \(status) must not be read as a complete list")
            } catch let error as ProcessListError {
                XCTAssertEqual(error, .emptyOutput)
            }
        }
    }

    func testLsofExitOneWithAListIsAccepted() async throws {
        // lsof exits 1 when some processes were unreadable, but the list it printed is still complete.
        let cwds = try await provider(exit: 1, stdout: "p1\nfcwd\nn/nonexistent-burrow-test/a\n").currentWorkingDirectories()
        XCTAssertEqual(cwds, ["/nonexistent-burrow-test/a"])
    }

    func testProcessShellTimeoutReturnsPartialResultWithNonZeroStatus() async throws {
        let result = try await ProcessShell().run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testCancellingAProcessStopsIt() async throws {
        let started = Date()
        let task = Task { try await ProcessShell().run("/bin/sleep", ["30"], timeout: 60) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testProcessThatSurvivesSigtermDoesNotHangTheCaller() async throws {
        // The shell ignores SIGTERM and its child keeps the output pipe open, so only the hard deadline can end the call.
        let started = Date()
        let dir = try makeTempDirectory()
        let pidFile = dir.appendingPathComponent("sleeper.pid")
        // The sleeper outlives the shell (SIGKILL cannot reach it), so the test must end it itself.
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            _ = try await ProcessShell().run("/bin/sh", ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"], timeout: 0.5)
            XCTFail("expected the call to give up")
        } catch let error as ShellError {
            XCTAssertEqual(error, .hung("/bin/sh"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}
