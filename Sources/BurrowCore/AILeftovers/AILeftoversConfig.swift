// Injectable inputs for every AI leftovers scanner, so tests can run against a temp home.

import Foundation

public struct AILeftoversConfig: Sendable {
    /// Root that stands in for the user's home folder.
    public var home: URL
    /// Reference time for age checks.
    public var now: Date
    /// Anything modified more recently than this many days is never offered.
    public var thresholdDays: Int

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now, thresholdDays: Int = 30) {
        self.home = home
        self.now = now
        self.thresholdDays = thresholdDays
    }

    /// Items modified before this date are old enough to offer.
    public var cutoff: Date {
        now.addingTimeInterval(-Double(thresholdDays) * 24 * 60 * 60)
    }

    public func url(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }
}

/// Recursive size and newest-file date for a path, computed in one enumeration.
public struct FolderStats: Sendable {
    public var bytes: Int64
    public var newestModified: Date?

    public static func measure(_ root: URL) -> FolderStats {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var bytes: Int64 = 0
        var newest: Date?
        if let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]),
           values.isRegularFile == true {
            bytes = Int64(values.totalFileAllocatedSize ?? 0)
            newest = values.contentModificationDate
            return FolderStats(bytes: bytes, newestModified: newest)
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return FolderStats(bytes: 0, newestModified: nil)
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                bytes += Int64(values.totalFileAllocatedSize ?? 0)
                if let date = values.contentModificationDate, newest == nil || date > newest! {
                    newest = date
                }
            }
        }
        return FolderStats(bytes: bytes, newestModified: newest)
    }
}
