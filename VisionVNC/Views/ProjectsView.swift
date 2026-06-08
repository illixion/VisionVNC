import SwiftUI
import SwiftData
import UIKit

/// The managed-Claude tab: choose an SSH host, browse its folders, and launch
/// `claude` (tmux-backed) in a project directory. Reuses saved `.ssh`
/// connections as the available hosts.
struct ProjectsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var connections: [SavedConnection]

    private var sshConnections: [SavedConnection] {
        connections.filter { $0.connectionType == .ssh }
    }

    @State private var selectedHostID: UUID?
    @State private var homePath = ""
    @State private var path = ""
    @State private var entries: [DirEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var keyStatus: String?
    @State private var showingClaudeSetup = false

    private var selectedHost: SavedConnection? {
        sshConnections.first { $0.id == selectedHostID } ?? sshConnections.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if sshConnections.isEmpty {
                    ContentUnavailableView {
                        Label("No SSH Hosts", systemImage: "terminal")
                    } description: {
                        Text("Add an SSH connection in the Connections tab to run Claude on that machine.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy Public Key", systemImage: "key") { copyPublicKey() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Picker("Host", selection: Binding(
                    get: { selectedHost?.id },
                    set: { selectedHostID = $0 }
                )) {
                    ForEach(sshConnections) { conn in
                        Text(conn.displayName).tag(Optional(conn.id))
                    }
                }
                if let keyStatus {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
                if let host = selectedHost {
                    Button {
                        showingClaudeSetup = true
                    } label: {
                        HStack {
                            Label("Claude Login", systemImage: "person.badge.key")
                            Spacer()
                            if host.sshHasAuthToken {
                                Label("Configured", systemImage: "checkmark.seal.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Set up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            environmentSection
            runningSessionsSection
            recentsSection
            folderBrowserSection

            Section {
                Button {
                    openClaude(in: path)
                } label: {
                    Label("Open Claude Here", systemImage: "sparkles")
                }
                .disabled(selectedHost == nil || path.isEmpty || loading)
            }
        }
        .task(id: selectedHost?.id) { await loadHome() }
        .sheet(isPresented: $showingClaudeSetup) {
            if let host = selectedHost {
                NavigationStack { ClaudeSetupSheet(host: host) }
            }
        }
    }

    // MARK: Sections

    /// Per-host client + environment config, editable in place: swap `claude`
    /// for another CLI tool and provide its auth/PATH env vars. Stored on the
    /// SavedConnection (same fields as the connection form) and applied when a
    /// session is next launched.
    @ViewBuilder
    private var environmentSection: some View {
        if selectedHost != nil {
            Section("Environment Variables") {
                TextField("claude", text: clientCommandBinding)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("Client command launched in the project folder. Default: claude — point it at another CLI tool to reuse this workflow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("KEY=VALUE (one per line)", text: envVarsBinding, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("Injected into sessions on this host — auth keys or PATH entries for other tools. Applies to newly launched sessions. The Claude token is stored separately under Claude Login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientCommandBinding: Binding<String> {
        Binding(get: { selectedHost?.sshClientCommand ?? "" },
                set: { selectedHost?.sshClientCommand = $0 })
    }

    private var envVarsBinding: Binding<String> {
        Binding(get: { selectedHost?.sshEnvVars ?? "" },
                set: { selectedHost?.sshEnvVars = $0 })
    }

    @ViewBuilder
    private var runningSessionsSection: some View {
        let claudeSessions = sshManager.sessions.filter { $0.kind == .claude }
        if !claudeSessions.isEmpty {
            Section("Running Sessions") {
                ForEach(claudeSessions) { session in
                    Button {
                        openWindow(id: "ssh-terminal", value: session.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.headline)
                                if let cwd = session.cwd {
                                    Text(cwd).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sshManager.remove(session.id)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let recents = recentFolders(host: selectedHost?.hostname ?? "")
        if !recents.isEmpty {
            Section("Recent Projects") {
                ForEach(recents, id: \.self) { folder in
                    Button {
                        openClaude(in: folder)
                    } label: {
                        Label(displayName(of: folder), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderBrowserSection: some View {
        Section("Folder") {
            HStack {
                Button {
                    goUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)
                .disabled(path.isEmpty || path == "/")
                Spacer()
                Text(displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }

            if loading {
                ProgressView()
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ForEach(entries.filter(\.isDir)) { entry in
                Button {
                    enter(entry.name)
                } label: {
                    Label(entry.name, systemImage: "folder")
                }
            }
        }
    }

    // MARK: Path helpers

    private var displayPath: String {
        guard !homePath.isEmpty else { return path }
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    private func displayName(of folder: String) -> String {
        let trimmed = (folder.hasSuffix("/") && folder != "/") ? String(folder.dropLast()) : folder
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }

    // MARK: Browsing

    private func loadHome() async {
        guard let host = selectedHost else { return }
        loading = true; error = nil
        do {
            let home = try await sshManager.homeDirectory(host: host.hostname, port: host.port, username: host.sshUsername)
            homePath = home
            path = home
            entries = try await sshManager.listDirectory(host: host.hostname, port: host.port, username: host.sshUsername, absolutePath: home)
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    private func reload() async {
        guard let host = selectedHost, !path.isEmpty else { return }
        loading = true; error = nil
        do {
            entries = try await sshManager.listDirectory(host: host.hostname, port: host.port, username: host.sshUsername, absolutePath: path)
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    private func enter(_ name: String) {
        path = path.hasSuffix("/") ? path + name : path + "/" + name
        Task { await reload() }
    }

    private func goUp() {
        guard !path.isEmpty, path != "/" else { return }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        Task { await reload() }
    }

    // MARK: Launch

    private func openClaude(in folder: String) {
        guard let host = selectedHost, !folder.isEmpty else { return }
        do {
            let id = try sshManager.newClaudeSession(
                host: host.hostname, port: host.port, username: host.sshUsername,
                folder: folder, projectName: "",
                clientCommand: host.effectiveSSHClientCommand,
                environment: host.resolvedSSHEnvironment()
            )
            addRecent(host: host.hostname, folder: folder)
            openWindow(id: "ssh-terminal", value: id)
        } catch {
            self.error = "\(error)"
        }
    }

    private func copyPublicKey() {
        do {
            let key = try sshManager.deviceKey()
            UIPasteboard.general.string = key.openSSHPublicKeyLine(comment: "visionvnc")
            keyStatus = "Copied (\(key.sshFingerprint())). Add to ~/.ssh/authorized_keys on the host."
        } catch {
            keyStatus = "Key error: \(error)"
        }
    }

    // MARK: Recents (per host, UserDefaults)

    private func recentsKey(_ host: String) -> String { "claudeRecentFolders.\(host)" }

    private func recentFolders(host: String) -> [String] {
        guard !host.isEmpty else { return [] }
        return UserDefaults.standard.stringArray(forKey: recentsKey(host)) ?? []
    }

    private func addRecent(host: String, folder: String) {
        var list = recentFolders(host: host)
        list.removeAll { $0 == folder }
        list.insert(folder, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentsKey(host))
    }
}

/// Walks the user through giving a host a Claude login that works over SSH:
/// generate a `claude setup-token`, allow it through sshd's `AcceptEnv`, and
/// store the token in this device's Secure Enclave keychain. The token is then
/// injected into each session as `CLAUDE_CODE_OAUTH_TOKEN` (see
/// `SavedConnection.resolvedSSHEnvironment`) — the Mac never holds it at rest.
private struct ClaudeSetupSheet: View {
    @Bindable var host: SavedConnection
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                Text("Claude can't read its login from the macOS Keychain over SSH — the Keychain is locked outside the desktop session. Instead, give it a long-lived token that VisionVNC injects into each session as \(host.effectiveSSHAuthEnvName). It's stored only on this device and never written to the Mac — nothing in the Mac's SSH config needs changing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("1 · Generate a token on the Mac") {
                Text("In Terminal on the Mac, run once:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("claude setup-token")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Log in via the browser it opens, then copy the one-year token it prints (it isn't saved anywhere automatically).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("2 · Paste the token") {
                SecureField(host.effectiveSSHAuthEnvName, text: $token)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if host.sshHasAuthToken {
                    Label("A token is stored on this device for \(host.displayName).", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Remove Stored Token", role: .destructive) {
                        host.sshAuthToken = nil
                        try? host.modelContext?.save()
                        token = ""
                    }
                }
            }
        }
        .navigationTitle("Set up Claude")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    host.sshAuthToken = token
                    try? host.modelContext?.save()
                    dismiss()
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
