import SwiftUI

/// Terminal window: status row, the SwiftTerm display, a gaze-friendly quick-key
/// row, and a dictation-capable composer. Looks up its `SSHSession` by id so the
/// session can outlive the window (tmux-backed re-attach).
struct SSHTerminalView: View {
    @Environment(SSHTerminalManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    let sessionID: SSHSessionID

    @State private var composer: String = ""
    @FocusState private var composerFocused: Bool

    /// When latched (the ⌃ key in the row), a single-letter send becomes the
    /// matching control character (e.g. ⌃ + "b" → 0x02 — tmux prefix).
    @State private var ctrlLatched = false

    @AppStorage(ConnectionDefaults.Keys.terminalFontSize)
    private var terminalFontSize: Double = ConnectionDefaults.terminalFontSizeDefault
    @AppStorage(ConnectionDefaults.Keys.terminalQuickKeys)
    private var quickKeysRaw: String = TerminalQuickKey.defaultSelectionStored

    var body: some View {
        Group {
            if let session = manager.session(sessionID) {
                content(session)
            } else {
                ContentUnavailableView("Session ended", systemImage: "terminal")
            }
        }
        .background(Color(white: 0.07))
        // Auto-reconnect lifecycle (same shape as AudioStreamView): revive on
        // appear / scene activation, stop retrying when the window goes away.
        // Sessions are looked up by id inside the closures — the window can
        // outlive a captured session reference.
        .onAppear { manager.session(sessionID)?.ensureConnected() }
        .onDisappear { manager.session(sessionID)?.windowDisappeared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.session(sessionID)?.ensureConnected() }
        }
    }

    @ViewBuilder
    private func content(_ session: SSHSession) -> some View {
        VStack(spacing: 0) {
            statusRow(session)
            TerminalEmulatorView(session: session, fontSize: terminalFontSize)
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
            Text(statusText(session))
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

    private func statusText(_ session: SSHSession) -> String {
        if session.isAutoReconnecting { return "Reconnecting…" }
        switch session.state {
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .closed(let reason): return reason.map { "Closed: \($0)" } ?? "Closed"
        case .failed(let message): return message
        }
    }

    // MARK: - Quick keys

    /// Enabled keys in stable catalog order (user-customizable in Settings →
    /// Terminal).
    private var enabledQuickKeys: [TerminalQuickKey] {
        let enabled = TerminalQuickKey.enabledIDs(from: quickKeysRaw)
        return TerminalQuickKey.catalog.filter { enabled.contains($0.id) }
    }

    @ViewBuilder
    private func quickKeyRow(_ session: SSHSession) -> some View {
        let keys = enabledQuickKeys
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ctrlLatchButton
                Divider().frame(height: 28)
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    if index > 0, keys[index - 1].group != key.group {
                        Divider().frame(height: 28)
                    }
                    quickKey(key.label, key.bytes, session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var ctrlLatchButton: some View {
        Button("⌃") { ctrlLatched.toggle() }
            .buttonStyle(.bordered)
            .tint(ctrlLatched ? .accentColor : nil)
            .frame(minWidth: 48, minHeight: 44)
    }

    private func quickKey(_ label: String, _ bytes: [UInt8], _ session: SSHSession) -> some View {
        Button(label) { session.sendBytes(bytes) }
            .buttonStyle(.bordered)
            .frame(minWidth: 48, minHeight: 44)
            // Unlike composed text, raw key bytes aren't worth queueing —
            // disable instead of silently dropping while disconnected.
            .disabled(!session.isReady)
    }

    // MARK: - Composer

    @ViewBuilder
    private func composerBar(_ session: SSHSession) -> some View {
        VStack(spacing: 8) {
            if let queued = session.queuedComposerText {
                HStack(spacing: 8) {
                    Label("Sends on reconnect: \(queued)", systemImage: "clock")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Cancel") { session.clearQueuedComposerText() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                TextField("Type a command…", text: $composer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        }
        .padding(16)
        .background(.bar)
    }

    /// Note: the send path has no focus dependency — neither the terminal view
    /// nor the composer needs focus for delivery. The historical "had to focus
    /// the session first" text loss was a dead channel silently dropping the
    /// bytes; with a dead connection the text now queues (visible chip above)
    /// and flushes when the session reconnects.
    private func send(_ session: SSHSession) {
        guard !composer.isEmpty else { return }
        if ctrlLatched {
            ctrlLatched = false
            let trimmed = composer.trimmingCharacters(in: .whitespaces)
            if let ctrl = TerminalKeyEncoder.controlByte(for: trimmed) {
                if session.sendBytes([ctrl]) { composer = "" }
                return
            }
            // No control mapping — fall through and send as plain text.
        }
        session.sendComposerText(composer)
        composer = ""
    }
}
