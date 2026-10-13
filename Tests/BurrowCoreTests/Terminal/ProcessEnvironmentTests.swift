import XCTest
@testable import BurrowCore

final class ProcessEnvironmentTests: XCTestCase {
    /// Switches a shell or launchd session might export. Each one changes what a real `mo` run does.
    private let inheritedMoleSwitches = [
        "MOLE_DELETE_MODE": "permanent",
        "MOLE_DRY_RUN": "1",
        "MOLE_PURGE_YES": "1",
        "MOLE_PRESELECTED_INDICES": "0,1,2",
        "MOLE_TEST_NO_AUTH": "1",
        "MOLE_TEST_MODE": "1",
        "MOLE_SKIP_MAIN": "1",
        "MOLE_USER_HOME": "/tmp/elsewhere",
    ]

    func testEveryInheritedMoleVariableIsDropped() {
        var base = inheritedMoleSwitches
        base["HOME"] = "/Users/test"
        base["PATH"] = "/usr/bin:/bin"
        let env = ProcessEnvironment.make(base: base)

        XCTAssertEqual(env.keys.filter { $0.hasPrefix("MOLE_") }, [])
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertNotNil(env["PATH"])
    }

    func testJobOverridesCannotSmuggleAMoleVariableIn() {
        let env = ProcessEnvironment.make(base: [:], overrides: ["NO_COLOR": "1", "MOLE_DELETE_MODE": "permanent"])

        XCTAssertEqual(env["NO_COLOR"], "1")
        XCTAssertNil(env["MOLE_DELETE_MODE"])
    }
}
