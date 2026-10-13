import Foundation
import XCTest
@testable import BurrowCore

func fixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
        XCTFail("Missing fixture \(name)", file: file, line: line)
        return ""
    }
    return try String(contentsOf: url, encoding: .utf8)
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeExecutable(_ script: String, in directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
