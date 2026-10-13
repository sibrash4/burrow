import XCTest
@testable import BurrowCore

/// A capture pipe's write end must never reach a process Burrow did not hand it to. If one does, that process keeps the
/// pipe open for its whole life, and a reader that waits for end-of-file waits for that process (a full `swift test`
/// once spent 900 s in a 1-second test this way).
final class FileDescriptorInheritanceTests: XCTestCase {
    private var directory: URL!
    private var leaked: Int32 = -1
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        directory = try makeTempDirectory()
        // A descriptor that is NOT close-on-exec: stands in for any fd that a careless caller left inheritable.
        // Numbered 100 or higher so it cannot be confused with the few descriptors `ls` opens for itself.
        let base = Foundation.open("/dev/null", O_RDONLY)
        leaked = fcntl(base, F_DUPFD, 100)
        close(base)
        XCTAssertGreaterThanOrEqual(leaked, 100)
        XCTAssertFalse(FileDescriptors.isCloexec(leaked))
    }

    override func tearDownWithError() throws {
        if leaked >= 0 { close(leaked) }
        for process in spawned where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for pid in recordedPIDs() { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func recordedPIDs() -> [pid_t] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pid" }.compactMap {
            (try? String(contentsOf: $0, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// Descriptor numbers a child can see, from `ls /dev/fd` run in the child itself.
    private func descriptors(in output: String) -> Set<Int32> {
        Set(output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
    }

    private func assertOnlyStdio(_ output: String, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let seen = descriptors(in: output)
        XCTAssertTrue(seen.isSuperset(of: [0, 1, 2]), "\(path): \(seen)", file: file, line: line)
        XCTAssertFalse(seen.contains(leaked), "\(path): child inherited fd \(leaked): \(seen)", file: file, line: line)
        // Only 0...2 plus the couple `ls` opens itself, all low-numbered. Anything from the test process would sit at 3 or above in
        // its own numbering, and the xctest process has dozens open.
        XCTAssertTrue(seen.allSatisfy { $0 < 8 }, "\(path): child inherited extra descriptors: \(seen.sorted())", file: file, line: line)
    }

    // MARK: Descriptors Burrow creates

    func testPipeEndsAreCloseOnExecFromCreation() throws {
        let (read, write) = try FileDescriptors.makeCloexecPipe()
        defer { close(read); close(write) }
        XCTAssertTrue(FileDescriptors.isCloexec(read))
        XCTAssertTrue(FileDescriptors.isCloexec(write))
    }

    func testOpenedDescriptorsAreCloseOnExec() {
        let fd = FileDescriptors.open("/dev/null", O_RDONLY)
        defer { close(fd) }
        XCTAssertTrue(FileDescriptors.isCloexec(fd))
    }

    // MARK: Every spawn path starts the child with stdio only

    func testProcessRunnerChildInheritsOnlyStdio() async throws {
        let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/ls"))
            .run(["/dev/fd"], environment: [:])
        assertOnlyStdio(result.output, "ProcessRunner")
    }

    func testProcessShellChildInheritsOnlyStdio() async throws {
        // Foundation.Process, used by ProcessShell and MoleLocator.
        let result = try await ProcessShell().run("/bin/ls", ["/dev/fd"], timeout: 20)
        assertOnlyStdio(result.stdout, "ProcessShell (Foundation.Process)")
    }

    func testPTYChildInheritsOnlyStdio() async throws {
        let session = try PTYLauncher(executable: URL(fileURLWithPath: "/bin/ls"))
            .launch(["/dev/fd"], environment: [:], columns: 80, rows: 24)
        _ = try await session.waitForExit(timeout: 20)
        assertOnlyStdio(session.transcript(), "PTYSession")
    }

    // MARK: A process that does hold the pipe cannot hold the call

    /// The leader exits at once, but a helper it started keeps the output pipe open for 60 s (the same situation as a
    /// process that inherited the write end by accident). The call must return what the leader printed after the
    /// grace period instead of waiting for the helper.
    func testHelperHoldingThePipeDoesNotHoldTheCall() async throws {
        let pidFile = directory.appendingPathComponent("helper.pid")
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), eofGrace: 0.5)
        let started = Date()
        let result = try await runner.run(["-c", "sleep 60 & echo $! > '\(pidFile.path)'; echo leader-done"], environment: [:])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "leader-done\n")
        XCTAssertLessThan(elapsed, 15, "run waited for a helper that holds the pipe")
        let helper = try XCTUnwrap(recordedPIDs().first)
        XCTAssertEqual(kill(helper, 0), 0, "the helper must still be running, or this test proves nothing")
    }

    func testDefaultGraceIsShort() async throws {
        let pidFile = directory.appendingPathComponent("helper.pid")
        let started = Date()
        let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
            .run(["-c", "sleep 60 & echo $! > '\(pidFile.path)'; echo ok"], environment: [:])
        XCTAssertEqual(result.output, "ok\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    /// Output the leader wrote before exiting is kept when the grace period ends the wait.
    func testOutputIsKeptWhenTheGracePeriodEndsTheWait() async throws {
        let pidFile = directory.appendingPathComponent("helper.pid")
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), eofGrace: 0.5)
        let script = "sleep 60 & echo $! > '\(pidFile.path)'; head -c 200000 /dev/zero | tr '\\0' 'a'; echo; echo tail"
        let result = try await runner.run(["-c", script], environment: [:])
        XCTAssertEqual(result.output.utf8.count, 200_000 + 1 + 5)
        XCTAssertTrue(result.output.hasSuffix("\ntail\n"))
    }

    func testExitCodeSurvivesTheGracePeriod() async throws {
        let pidFile = directory.appendingPathComponent("helper.pid")
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), eofGrace: 0.5)
        let result = try await runner.run(["-c", "sleep 60 & echo $! > '\(pidFile.path)'; exit 7"], environment: [:])
        XCTAssertEqual(result.exitCode, 7)
    }

    // MARK: The original suspicion: processes spawned elsewhere while a run is draining

    /// Foundation.Process children started on other threads while runs are in flight must not pick up the runs' pipes.
    /// If they did, the runs would wait for these 60 s sleepers (the grace period is turned off by making it huge).
    func testProcessesSpawnedConcurrentlyDoNotHoldRunsOpen() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), eofGrace: 600)
        let started = Date()

        let sleepers: [Process] = (0..<12).map { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        let spawner = Task.detached {
            for process in sleepers {
                try? process.run()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { for process in sleepers where process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<24 {
                group.addTask { try await runner.run(["-c", "echo run\(index)"], environment: [:]).output }
            }
            var outputs = Set<String>()
            for try await output in group { outputs.insert(output) }
            XCTAssertEqual(outputs.count, 24)
        }
        await spawner.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "a run waited for a process spawned elsewhere")
    }
}
