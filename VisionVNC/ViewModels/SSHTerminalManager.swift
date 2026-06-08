import Foundation
import SwiftTerm
import NIOSSH
import NIOTransportServices
import os

/// Window value for a terminal scene — one window per SSH session.
struct SSHSessionID: Hashable, Codable, Sendable {
    let raw: String
}

/// A remote directory entry from the Projects folder browser.
struct DirEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isDir: Bool
    var id: String { name }
}

/// A single interactive SSH terminal session. MainActor `@Observable` view
/// model that owns an off-main `SSHConnection` and bridges its byte stream to a
/// SwiftTerm `TerminalView`. Persistence/re-attach across drops is delegated to
/// `tmux` on the Mac, so this holds no scrollback state of its own — a reopened
/// window just re-runs `tmux new -A` and the server replays the pane.
@Observable
@MainActor
final class SSHSession: Identifiable {
    let id: SSHSessionID
    let title: String
    let host: String
    let username: String
    let kind: Kind
    /// Working directory for managed Claude sessions (nil for plain shells).
    let cwd: String?

    enum Kind: Sendable { case shell, claude }

    enum State: Equatable {
        case connecting
        case ready
        case closed(String?)
        case failed(String)
    }
    private(set) var state: State = .connecting

    /// The live terminal view, set when a window attaches. Weak: the window can
    /// come and go while the session (and its SSH connection) lives on.
    weak var terminalView: TerminalView?
    private var pendingOutput: [UInt8] = []
    private var connection: SSHConnection?

    // Retained so `restart()` can rebuild the connection with the same launch.
    private var config: SSHConnection.Config?
    private var privateKey: NIOSSHPrivateKey?
    private var group: NIOTSEventLoopGroup?

    init(id: SSHSessionID, title: String, host: String, username: String,
         kind: Kind, cwd: String?) {
        self.id = id
        self.title = title
        self.host = host
        self.username = username
        self.kind = kind
        self.cwd = cwd
    }

    func start(config: SSHConnection.Config, privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup) {
        self.config = config
        self.privateKey = privateKey
        self.group = group
        connect()
    }

    /// Manual reconnect after a drop or a wedged launch. Re-runs the original
    /// launch command: tmux `new -A` re-attaches a surviving remote session, or
    /// creates a fresh one if the program exited (e.g. claude after Ctrl+C).
    func restart() {
        connection?.close()
        // Full terminal reset (RIS) so stale output from the dead connection
        // doesn't mix with the relaunch.
        let reset: [UInt8] = [0x1B, 0x63]
        terminalView?.feed(byteArray: reset[...])
        pendingOutput.removeAll()
        connect()
    }

    private func connect() {
        guard let config, let privateKey, let group else { return }
        state = .connecting
        let conn = SSHConnection(config: config, privateKey: privateKey, group: group)
        // Events are dropped unless they come from the *current* connection, so
        // a discarded connection's close can't clobber a restarted session.
        conn.onEvent = { [weak self, weak conn] event in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, conn === self.connection else { return }
                self.handle(event)
            }
        }
        connection = conn
        conn.start()
    }

    private func handle(_ event: SSHConnection.Event) {
        switch event {
        case .ready:
            state = .ready
        case .output(let bytes):
            if let view = terminalView {
                view.feed(byteArray: bytes[...])
            } else {
                pendingOutput.append(contentsOf: bytes)
            }
        case .closed(let reason):
            state = .closed(reason)
        case .failed(let message):
            state = .failed(message)
        }
    }

    /// Bind the terminal view, flushing any output that arrived before attach.
    func attach(_ view: TerminalView) {
        terminalView = view
        if !pendingOutput.isEmpty {
            view.feed(byteArray: pendingOutput[...])
            pendingOutput.removeAll()
        }
    }

    func detach() { terminalView = nil }

    func sendBytes(_ bytes: [UInt8]) { connection?.send(bytes) }
    func sendText(_ text: String) { connection?.send(Array(text.utf8)) }
    func resize(cols: Int, rows: Int) { connection?.resize(cols: cols, rows: rows) }
    func terminate() { connection?.close() }
}

/// Owns the device SSH key, the shared NIO event-loop group, and the set of
/// live terminal sessions.
@Observable
@MainActor
final class SSHTerminalManager {
    private(set) var sessions: [SSHSession] = []

    private let group = NIOTSEventLoopGroup()
    private var cachedKey: SecureEnclaveSSHKey?
    private let log = Logger(subsystem: "com.illixion.VisionVNC", category: "SSHManager")

    /// The Vision Pro's SSH identity (Secure Enclave where available).
    func deviceKey() throws -> SecureEnclaveSSHKey {
        if let cachedKey { return cachedKey }
        let key = try SecureEnclaveSSHKey.loadOrCreate()
        cachedKey = key
        return key
    }

    func session(_ id: SSHSessionID) -> SSHSession? {
        sessions.first { $0.id == id }
    }

    /// Open or re-attach a generic interactive SSH terminal. Empty `command`
    /// requests a login shell; a non-empty command is exec'd verbatim.
    @discardableResult
    func newShellSession(host: String, port: Int, username: String,
                         displayName: String, command: String,
                         environment: [(name: String, value: String)] = []) throws -> SSHSessionID {
        let title = displayName.isEmpty ? host : displayName
        let launch = Self.shellCommand(launch: command, environment: environment)
        return try startSession(slug: Self.slug(title), title: title, host: host, port: port,
                                username: username, command: launch, kind: .shell, cwd: nil)
    }

    /// Open or re-attach a managed Claude session in `folder`, tmux-backed so it
    /// survives disconnects (`-A` = attach-or-create) under a login+interactive
    /// shell (brew/nvm/bun PATHs resolve).
    @discardableResult
    func newClaudeSession(host: String, port: Int, username: String,
                          folder: String, projectName: String,
                          clientCommand: String = "claude",
                          environment: [(name: String, value: String)] = []) throws -> SSHSessionID {
        let title = projectName.isEmpty ? Self.folderName(folder) : projectName
        let slug = Self.slug(title)
        let command = Self.claudeCommand(tmuxSession: slug, folder: folder,
                                         clientCommand: clientCommand,
                                         environment: environment)
        return try startSession(slug: slug, title: title, host: host, port: port,
                                username: username, command: command, kind: .claude, cwd: folder)
    }

    private func startSession(slug: String, title: String, host: String, port: Int,
                              username: String, command: String,
                              kind: SSHSession.Kind, cwd: String?) throws -> SSHSessionID {
        let id = SSHSessionID(raw: slug)
        if let existing = session(id) { return existing.id }

        let key = try deviceKey()
        let config = SSHConnection.Config(
            host: host, port: port, username: username,
            command: command, cols: 80, rows: 24
        )
        let session = SSHSession(id: id, title: title, host: host, username: username, kind: kind, cwd: cwd)
        sessions.append(session)
        session.start(config: config, privateKey: key.nioPrivateKey, group: group)
        log.info("Opened SSH session \(slug, privacy: .public) to \(host, privacy: .public)")
        return id
    }

    func remove(_ id: SSHSessionID) {
        session(id)?.terminate()
        sessions.removeAll { $0.id == id }
    }

    /// tmux-safe session name: alphanumerics, dashes collapsed, never empty.
    static func slug(_ input: String) -> String {
        let scalars = input.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var out = String(scalars)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "claude" : out
    }

    private static func folderName(_ path: String) -> String {
        let trimmed = (path.hasSuffix("/") && path != "/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// Wrap a string as a single-quoted shell token (robust against spaces and
    /// quotes via the close/escape/reopen idiom). Applied twice for the Claude
    /// command — once for the folder, once for the whole inner command — so the
    /// double shell nesting (sshd's `$SHELL -c` → `zsh -lic`) stays correct.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func claudeCommand(tmuxSession: String, folder: String,
                              clientCommand: String = "claude",
                              environment: [(name: String, value: String)] = []) -> String {
        let client = clientCommand.isEmpty ? "claude" : clientCommand
        let vars = environment.filter { !$0.name.isEmpty }
        var inner = ""
        // A tmux server started before these vars existed snapshots an env
        // without them, and new sessions inherit that snapshot. Registering the
        // names in update-environment makes tmux import them from this client
        // when the session is created — so the token reaches `claude` even if a
        // server is already running, while staying scoped to this session (not
        // the server's global env). Verified on tmux 3.6.
        for v in vars {
            inner += "tmux set -gqa update-environment \(shellSingleQuote(v.name)) >/dev/null 2>&1; "
        }
        // Inline assignments scope the secret to the short-lived `tmux new`
        // child's environment — never written to disk, and macOS redacts a
        // process's env from other (non-root) processes.
        for v in vars {
            inner += "\(v.name)=\(shellSingleQuote(v.value)) "
        }
        inner += "tmux new -A -d -s \(tmuxSession)"
        if !folder.isEmpty { inner += " -c \(shellSingleQuote(folder))" }
        inner += " \(client); "
        // `exec` replaces this shell with the attach client, so the token-
        // bearing argv of `tmux new` is shed within milliseconds of launch.
        inner += "exec tmux attach -t \(tmuxSession)"
        return "zsh -lic \(shellSingleQuote(inner))"
    }

    /// Builds a generic (non-tmux) session command carrying non-secret
    /// `environment`. No env → `launch` unchanged (empty → a login shell).
    /// Otherwise the assignments prefix the command, or an exec'd login shell.
    static func shellCommand(launch: String,
                             environment: [(name: String, value: String)] = []) -> String {
        let assignments = environment
            .filter { !$0.name.isEmpty }
            .map { "\($0.name)=\(shellSingleQuote($0.value)) " }
            .joined()
        guard !assignments.isEmpty else { return launch }
        if launch.isEmpty { return "\(assignments)exec \"$SHELL\" -l" }
        return "\(assignments)\(launch)"
    }

    // MARK: - Remote directory browsing (Projects folder picker)

    /// Absolute home directory on the host — the browser's start point.
    func homeDirectory(host: String, port: Int, username: String) async throws -> String {
        let out = try await runCommand(host: host, port: port, username: username, command: "pwd")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Directory entries at `absolutePath` (dirs first; dotfiles hidden — a
    /// project picker doesn't need `.git`/`.config` noise).
    func listDirectory(host: String, port: Int, username: String, absolutePath: String) async throws -> [DirEntry] {
        let command = "ls -1p -- \(Self.shellSingleQuote(absolutePath))"
        let out = try await runCommand(host: host, port: port, username: username, command: command)
        return Self.parseLsEntries(out)
    }

    private func runCommand(host: String, port: Int, username: String, command: String) async throws -> String {
        let key = try deviceKey()
        let group = self.group
        return try await withCheckedThrowingContinuation { continuation in
            SSHCommandRunner.run(host: host, port: port, username: username, command: command,
                                 privateKey: key.nioPrivateKey, group: group) { result in
                continuation.resume(with: result)
            }
        }
    }

    static func parseLsEntries(_ output: String) -> [DirEntry] {
        output.split(separator: "\n").compactMap { raw -> DirEntry? in
            let s = String(raw)
            guard !s.isEmpty else { return nil }
            if s.hasSuffix("/") {
                return DirEntry(name: String(s.dropLast()), isDir: true)
            }
            return DirEntry(name: s, isDir: false)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }
}
