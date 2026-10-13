import Foundation

public struct MoleVersion: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the first line of `mo --version`, e.g. "Mole version 1.59.1".
    public init?(parsing output: String) {
        guard let match = output.firstMatch(of: #/(?i)version\s+v?(\d+)\.(\d+)(?:\.(\d+))?/#),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        self.init(major: major, minor: minor, patch: match.3.flatMap { Int($0) } ?? 0)
    }

    /// Burrow is built against Mole 1.59.x.
    public var isSupported: Bool { major == 1 && minor == 59 }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct MoleInstall: Equatable, Sendable {
    public let url: URL
    /// nil when `mo --version` could not be read or parsed.
    public let version: MoleVersion?

    /// False for any version other than 1.59.x, and when the version is unknown. A warning, never a block.
    public var isSupported: Bool { version?.isSupported ?? false }
}

public struct MoleLocator: Sendable {
    public static let defaultCandidates = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo"]

    private let candidates: [String]
    private let searchPATH: Bool

    public init(candidates: [String] = MoleLocator.defaultCandidates, searchPATH: Bool = true) {
        self.candidates = candidates
        self.searchPATH = searchPATH
    }

    /// Finds `mo`: Homebrew locations first, then `which mo`. Throws `BurrowError.moleNotFound`.
    public func locate() throws -> URL {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if searchPATH,
           let found = Self.capture("/usr/bin/env", ["which", "mo"], timeout: 5),
           found.status == 0 {
            let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw BurrowError.moleNotFound
    }

    /// Reads `mo --version`. Returns nil if it can't be run or parsed.
    public func version(of mo: URL) -> MoleVersion? {
        guard let result = Self.capture(mo.path, ["--version"], timeout: 15), result.status == 0 else { return nil }
        return MoleVersion(parsing: ANSI.strip(result.output))
    }

    public func detect() throws -> MoleInstall {
        let url = try locate()
        return MoleInstall(url: url, version: version(of: url))
    }

    private static func capture(_ executable: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ProcessEnvironment.make(overrides: ["NO_COLOR": "1"])
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let reader = DispatchQueue(label: "burrow.locator.read")
        nonisolated(unsafe) var data = Data()
        let drained = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = drained.wait(timeout: .now() + 2)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
