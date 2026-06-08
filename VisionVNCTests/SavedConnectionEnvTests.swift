import XCTest
@testable import VisionVNC

/// SSH environment parsing/validation on `SavedConnection`: the `KEY=VALUE`
/// line parser and the POSIX env-name validator that guards the shell
/// assignment built in `SSHTerminalManager`.
@MainActor
final class SavedConnectionEnvTests: XCTestCase {

    func testValidEnvNames() {
        XCTAssertTrue(SavedConnection.isValidEnvName("CLAUDE_CODE_OAUTH_TOKEN"))
        XCTAssertTrue(SavedConnection.isValidEnvName("_underscore"))
        XCTAssertTrue(SavedConnection.isValidEnvName("A1B2"))
    }

    func testInvalidEnvNames() {
        XCTAssertFalse(SavedConnection.isValidEnvName(""))
        XCTAssertFalse(SavedConnection.isValidEnvName("1LEADING"))  // leading digit
        XCTAssertFalse(SavedConnection.isValidEnvName("HAS SPACE"))
        XCTAssertFalse(SavedConnection.isValidEnvName("HAS=EQ"))
        XCTAssertFalse(SavedConnection.isValidEnvName("FÖÖ"))       // non-ASCII
    }

    func testEnvParsing() {
        let connection = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        connection.sshEnvVars = """
        FOO=bar
        # a comment line
        EMPTY=
        PATH=/usr/bin:/bin
        bad name=skipme
        =noName
        QUOTED=a=b=c
        """
        let env = connection.sshEnvironmentVariables()
        let dict = Dictionary(uniqueKeysWithValues: env.map { ($0.name, $0.value) })

        XCTAssertEqual(dict["FOO"], "bar")
        XCTAssertEqual(dict["EMPTY"], "")                 // empty value kept
        XCTAssertEqual(dict["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(dict["QUOTED"], "a=b=c")           // only the first '=' splits
        XCTAssertNil(dict["bad name"])                    // invalid name dropped
        XCTAssertFalse(env.contains { $0.name.isEmpty })  // "=noName" dropped
        XCTAssertFalse(env.contains { $0.name.hasPrefix("#") })  // comment dropped
    }

    func testEnvParsingDedupesLastWins() {
        let connection = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        connection.sshEnvVars = "A=1\nA=2"
        let env = connection.sshEnvironmentVariables()
        XCTAssertEqual(env.filter { $0.name == "A" }.count, 1)
        XCTAssertEqual(env.first { $0.name == "A" }?.value, "2")
    }
}
