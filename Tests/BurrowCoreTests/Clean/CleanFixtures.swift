import Foundation
import XCTest
@testable import BurrowCore

enum CleanFixtures {
    static func text(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func scan(home: String = "/Users/test") throws -> ScanResult {
        let dry = CleanDryRunParser.parse(try text("clean_dryrun"))
        let list = CleanListParser.parse(try text("clean_list"))
        return CleanScanBuilder.build(dryRun: dry, list: list, home: home)
    }
}
