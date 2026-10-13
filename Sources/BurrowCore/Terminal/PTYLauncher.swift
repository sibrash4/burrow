import Foundation

public struct PTYLauncher: InteractiveLaunching {
    private enum Source: Sendable {
        case fixed(URL)
        case locate(MoleLocator)
    }

    private let source: Source

    public init(locator: MoleLocator = MoleLocator()) {
        source = .locate(locator)
    }

    /// Launches `executable` instead of `mo`. Intended for tests.
    public init(executable: URL) {
        source = .fixed(executable)
    }

    public func launch(_ args: [String], environment: [String: String] = [:], columns: Int = 100, rows: Int = 30) throws -> InteractiveSession {
        let executable: URL
        switch source {
        case .fixed(let url): executable = url
        case .locate(let locator): executable = try locator.locate()
        }
        return try PTYSession.start(executable: executable, args: args, environment: environment, columns: columns, rows: rows)
    }
}
