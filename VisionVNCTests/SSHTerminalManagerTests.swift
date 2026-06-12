import XCTest
@testable import VisionVNC

/// Pure logic on `SSHTerminalManager`/`SSHSession`: the tmux launch-command
/// builders (Claude + persistent shell with tmux fallback) and the
/// auto-reconnect backoff helper.
@MainActor
final class SSHTerminalManagerTests: XCTestCase {

    // MARK: - claudeCommand

    func testClaudeCommandAttachesDetachingStaleClients() {
        let cmd = SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/Users/me/proj")
        XCTAssertTrue(cmd.hasPrefix("zsh -lic '"))
        XCTAssertTrue(cmd.contains("tmux new -A -d -s proj -c '\\''/Users/me/proj'\\'' claude"))
        // -d detaches stale clients from dropped connections so they can't
        // pin the tmux window at the old size.
        XCTAssertTrue(cmd.contains("exec tmux attach -d -t proj"))
    }

    func testClaudeCommandInjectsEnvironmentInline() {
        let cmd = SSHTerminalManager.claudeCommand(
            tmuxSession: "p", folder: "/p",
            environment: [(name: "TOK", value: "secret")]
        )
        XCTAssertTrue(cmd.contains("tmux set -gqa update-environment '\\''TOK'\\''"))
        XCTAssertTrue(cmd.contains("TOK='\\''secret'\\'' tmux new"))
    }

    // MARK: - persistentShellCommand

    func testPersistentShellCommandFallsBackWithoutTmux() {
        let cmd = SSHTerminalManager.persistentShellCommand(tmuxSession: "vnc-mac", launch: "")
        XCTAssertTrue(cmd.hasPrefix("zsh -lic '"))
        XCTAssertTrue(cmd.contains("if command -v tmux >/dev/null 2>&1; then"))
        // Empty launch: tmux runs its default shell (no trailing command word
        // before the `;`), the fallback execs a login shell.
        XCTAssertTrue(cmd.contains("tmux new -A -d -s vnc-mac; "))
        XCTAssertTrue(cmd.contains("else exec \"$SHELL\" -l; fi"))
        XCTAssertTrue(cmd.contains("exec tmux attach -d -t vnc-mac"))
    }

    func testPersistentShellCommandCarriesLaunchCommandToBothPaths() {
        let cmd = SSHTerminalManager.persistentShellCommand(tmuxSession: "vnc-x", launch: "htop")
        XCTAssertTrue(cmd.contains("tmux new -A -d -s vnc-x htop"))
        XCTAssertTrue(cmd.contains("else htop; fi"))
    }

    func testPersistentShellCommandEnvReachesFallback() {
        let cmd = SSHTerminalManager.persistentShellCommand(
            tmuxSession: "vnc-x", launch: "",
            environment: [(name: "FOO", value: "bar")]
        )
        XCTAssertTrue(cmd.contains("FOO='\\''bar'\\'' tmux new"))
        XCTAssertTrue(cmd.contains("else FOO='\\''bar'\\'' exec \"$SHELL\" -l; fi"))
    }

    // MARK: - Retry backoff

    func testNextRetryDelayDoublesAndCaps() {
        XCTAssertEqual(SSHSession.nextRetryDelay(2), 4)
        XCTAssertEqual(SSHSession.nextRetryDelay(4), 8)
        XCTAssertEqual(SSHSession.nextRetryDelay(16), 30)  // capped
        XCTAssertEqual(SSHSession.nextRetryDelay(30), 30)
    }
}
