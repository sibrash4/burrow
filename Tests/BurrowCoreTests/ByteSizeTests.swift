import XCTest
@testable import BurrowCore

final class ByteSizeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(ByteSize.parse("4KB"), 4_000)
        XCTAssertEqual(ByteSize.parse("98.3MB+"), 98_300_000)
        XCTAssertNil(ByteSize.parse("would clean"))
    }
}
