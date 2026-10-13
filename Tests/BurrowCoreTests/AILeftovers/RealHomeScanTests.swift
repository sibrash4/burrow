import Foundation
import XCTest
@testable import BurrowCore

/// One read-only scan of the real home folder. Runs only when BURROW_REAL_SCAN=1.
/// It never calls run(), and prints counts and sizes only, not paths.
final class AILeftoversRealHomeScanTests: XCTestCase {
    func testReadOnlyScanOfRealHome() async throws {
        guard ProcessInfo.processInfo.environment["BURROW_REAL_SCAN"] == "1" else {
            throw XCTSkip("Set BURROW_REAL_SCAN=1 to scan the real home folder (read-only).")
        }
        let job = AILeftoversJob()
        let scan = try await job.scan()
        print("REAL_SCAN notes: \(scan.notes.joined(separator: " | "))")
        for group in scan.groups {
            let selectable = group.items.filter(\.selectable).count
            let defaults = group.items.filter(\.selectedByDefault).count
            print("REAL_SCAN group=\(group.title) items=\(group.items.count) selectable=\(selectable) defaultTicked=\(defaults) bytes=\(ByteSize.format(group.totalBytes))")
            for item in group.items where !item.selectable {
                print("REAL_SCAN   unselectable reason=\(item.note ?? "-") bytes=\(ByteSize.format(item.bytes ?? 0))")
            }
        }
    }
}
