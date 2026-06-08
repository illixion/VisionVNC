import SwiftUI

/// Terminal window: status row, the SwiftTerm display, a gaze-friendly quick-key
/// row, and a dictation-capable composer. Looks up its `SSHSession` by id so the
/// session can outlive the window (tmux-backed re-attach).
struct SSHTerminalView: View {
    @Environment(SSHTerminalManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    let sessionID: SSHSessionID

    @State private var composer: String = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let session = manager.session(sessionID) {
                content(session)
            } else {
                ContentUnavailableView("Session ended", systemImage: "terminal")
            }
        }
        .background(Color(white: 0.07))
    }

    @ViewBuilder
    private func content(_ session: SSHSession) -> some View {
        VStack(spacing: 0) {
            statusRow(session)
            TerminalEmulatorView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            quickKeyRow(session)
            composerBar(session)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusRow(_ session: SSHSession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(session.state))
                .frame(width: 8, height: 8)
            Text(session.title)
                .font(.headline)
            Text(session.username + "@" + session.host)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusText(session.state))
                .font(.caption)
                .foregroundStyle(.secondary)
            reloadButton(session)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Manual relaunch — always reachable so a wedged launch can be kicked, and
    /// prominent once the connection has died (e.g. claude exited via Ctrl+C,
    /// taking its tmux session with it).
    @ViewBuilder
    private func reloadButton(_ session: SSHSession) -> some View {
        switch session.state {
        case .closed, .failed:
            Button {
                session.restart()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        case .connecting, .ready:
            Button {
                session.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private func statusColor(_ state: SSHSession.State) -> Color {
        switch state {
        case .connecting: return .yellow
        case .ready: return .green
        case .closed, .failed: return .red
        }
    }

    private func statusText(_ state: SSHSession.State) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .closed(let reason): return reason.map { "Closed: \($0)" } ?? "Closed"
        case .failed(let message): return message
        }
    }

    // MARK: - Quick keys

    @ViewBuilder
    private func quickKeyRow(_ session: SSHSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickKey("esc", TerminalKeyEncoder.escape, session)
                quickKey("tab", TerminalKeyEncoder.tab, session)
                quickKey("⇤", TerminalKeyEncoder.shiftTab, session)
                quickKey("↑", TerminalKeyEncoder.up, session)
                quickKey("↓", TerminalKeyEncoder.down, session)
                quickKey("←", TerminalKeyEncoder.left, session)
                quickKey("→", TerminalKeyEncoder.right, session)
                quickKey("⌃C", TerminalKeyEncoder.ctrlC, session)
                quickKey("⌃R", TerminalKeyEncoder.ctrlR, session)
                quickKey("⏎", TerminalKeyEncoder.enter, session)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func quickKey(_ label: String, _ bytes: [UInt8], _ session: SSHSession) -> some View {
        Button(label) { session.sendBytes(bytes) }
            .buttonStyle(.bordered)
            .frame(minWidth: 48, minHeight: 44)
    }

    // MARK: - Composer

    @ViewBuilder
    private func composerBar(_ session: SSHSession) -> some View {
        HStack(spacing: 12) {
            TextField("Message Claude…", text: $composer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit { send(session) }
            Button {
                send(session)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .disabled(composer.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    private func send(_ session: SSHSession) {
        guard !composer.isEmpty else { return }
        // Send the composed text followed by CR (what a PTY treats as Enter).
        session.sendText(composer + "\r")
        composer = ""
    }
}
