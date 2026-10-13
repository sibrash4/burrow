import XCTest
@testable import BurrowCore

final class MoleLocatorTests: XCTestCase {
    func testParsesVersionOutput() throws {
        let version = try XCTUnwrap(MoleVersion(parsing: "\nMole version 1.59.1\nmacOS: 26.7.1\nArchitecture: arm64\n"))
        XCTAssertEqual(version, MoleVersion(major: 1, minor: 59, patch: 1))
        XCTAssertEqual(version.description, "1.59.1")
        XCTAssertTrue(version.isSupported)
    }

    func testSupportIsMajorMinor() throws {
        XCTAssertTrue(try XCTUnwrap(MoleVersion(parsing: "Mole version 1.59.9")).isSupported)
        XCTAssertTrue(try XCTUnwrap(MoleVersion(parsing: "Mole version 1.59")).isSupported)
        XCTAssertFalse(try XCTUnwrap(MoleVersion(parsing: "Mole version 1.60.0")).isSupported)
        XCTAssertFalse(try XCTUnwrap(MoleVersion(parsing: "Mole version 2.59.0")).isSupported)
    }

    func testUnparseableVersion() {
        XCTAssertNil(MoleVersion(parsing: "command not found"))
        XCTAssertNil(MoleVersion(parsing: ""))
    }

    func testLocatesFirstExecutableCandidate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try writeExecutable("#!/bin/sh\necho 'Mole version 1.59.1'\n", in: dir, name: "mo")
        let locator = MoleLocator(candidates: ["/nonexistent/mo", fake.path], searchPATH: false)
        XCTAssertEqual(try locator.locate().path, fake.path)
    }

    func testDetectReadsVersionFromExecutable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try writeExecutable("#!/bin/sh\n[ \"$1\" = --version ] && printf '\\033[1mMole version 1.58.0\\033[0m\\n'\n", in: dir, name: "mo")
        let install = try MoleLocator(candidates: [fake.path], searchPATH: false).detect()
        XCTAssertEqual(install.url.path, fake.path)
        XCTAssertEqual(install.version, MoleVersion(major: 1, minor: 58, patch: 0))
        XCTAssertFalse(install.isSupported)
    }

    func testUnreadableVersionDoesNotBlock() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try writeExecutable("#!/bin/sh\necho hello\n", in: dir, name: "mo")
        let install = try MoleLocator(candidates: [fake.path], searchPATH: false).detect()
        XCTAssertNil(install.version)
        XCTAssertFalse(install.isSupported)
    }

    func testNonExecutableCandidateIsSkipped() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("mo")
        try "not a program".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MoleLocator(candidates: [plain.path], searchPATH: false).locate()) {
            guard case BurrowError.moleNotFound = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingMoleThrows() {
        XCTAssertThrowsError(try MoleLocator(candidates: ["/nonexistent/mo"], searchPATH: false).locate()) {
            guard case BurrowError.moleNotFound = $0 else { return XCTFail("\($0)") }
        }
    }
}
