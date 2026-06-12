import SwiftUI
import AppKit

/// The companion's main window: sidebar navigation + grouped-form detail
/// panes. All configuration lives here; the menu bar popover keeps only the
/// quick audio controls and a button that opens this window.
struct CompanionWindowView: View {

    enum Pane: String, CaseIterable, Identifiable {
        case audio, accessToken, broadcast, remoteControl, keyboard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: "Audio Streaming"
            case .accessToken: "Access Token"
            case .broadcast: "Broadcast (OBS)"
            case .remoteControl: "Remote Control"
            case .keyboard: "Keyboard Control"
            }
        }

        var icon: String {
            switch self {
            case .audio: "speaker.wave.2"
            case .accessToken: "key"
            case .broadcast: "dot.radiowaves.left.and.right"
            case .remoteControl: "terminal"
            case .keyboard: "keyboard"
            }
        }
    }

    @Bindable var controller: AudioStreamerController
    @Bindable var broadcastServer: BroadcastServerManager
    @State private var selection: Pane = .audio

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            // No toolbar exists in a Settings window for the automatic
            // sidebar-collapse button to dock into, so it free-floats over
            // the sidebar — remove it (the sidebar shouldn't collapse anyway).
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .audio: AudioPane(controller: controller)
                case .accessToken: AccessTokenPane(controller: controller)
                case .broadcast: BroadcastPane(broadcastServer: broadcastServer)
                case .remoteControl: RemoteControlPane(controller: controller)
                case .keyboard: KeyboardPane(controller: controller)
                }
            }
            .formStyle(.grouped)
            // No navigationTitle: with no toolbar in a Settings window it
            // renders off-center over the detail column, and the selected
            // sidebar item already labels the pane.
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(HideWindowTitle())
        .onAppear {
            controller.refreshKeys()
            controller.injection.refreshAccessibility()
        }
    }
}

/// Hides the hosting window's title text: a Settings window has no toolbar,
/// so both navigationTitle and the default "… Settings" fallback render
/// off-center over the detail column. The title stays set for accessibility
/// and Mission Control — it's just not drawn. SwiftUI flips titleVisibility
/// back to .visible on every sidebar navigation (the title update re-asserts
/// it), so a one-shot hide isn't enough — KVO re-hides it each time.
private struct HideWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleHidingView: NSView {
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        guard let window else { return }
        window.titleVisibility = .hidden
        observation = window.observe(\.titleVisibility, options: [.new]) { window, change in
            guard change.newValue != .hidden else { return }
            DispatchQueue.main.async { window.titleVisibility = .hidden }
        }
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                Toggle("Stream system audio", isOn: $controller.isRunning)
                Toggle("Mute Mac output while streaming", isOn: $controller.muteWhileStreaming)
                    .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the VisionVNC app.")
                Toggle("Show track in menu bar", isOn: $controller.showTrackInMenuBar)
                    .help("Shows the current Music.app track as \"Artist – Title\" in the menu bar while streaming.")
            } footer: {
                Text("Streams the Mac's system audio to the VisionVNC app — audio played by the app honors the per-app Spatial Audio setting (Mac Virtual Display forces it on).")
            }

            Section("Status") {
                LabeledContent("Stream", value: controller.statusText)
                if controller.isRunning {
                    LabeledContent("Format", value: "Port \(String(controller.port)) · \(controller.formatText)")
                }
                if let nowPlaying = controller.nowPlaying, nowPlaying.hasTrack {
                    LabeledContent("Now Playing", value: "\(nowPlaying.title ?? "") — \(nowPlaying.artist ?? "")")
                }
                if let error = controller.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Access Token

private struct AccessTokenPane: View {
    @Bindable var controller: AudioStreamerController
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Token") {
                    Text(controller.token)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.token, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    Button {
                        guard let url = controller.tokenShareURL,
                              let service = NSSharingService(named: .sendViaAirDrop) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label("AirDrop to Vision Pro", systemImage: "square.and.arrow.up")
                    }

                    Spacer()

                    Button("Regenerate", role: .destructive) {
                        controller.regenerateToken()
                    }
                    .help("Invalidates the current token — connected devices must re-pair.")
                }
            } footer: {
                Text("Enter this token in VisionVNC, or AirDrop it to auto-fill. The token both authorizes the connection and encrypts it (TLS) — no VPN needed. Keep it secret; regenerate to revoke access.")
            }
        }
    }
}

// MARK: - Broadcast (OBS)

private struct BroadcastPane: View {
    @Bindable var broadcastServer: BroadcastServerManager
    @State private var linkCopied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(broadcastServer.statusText)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button(broadcastServer.isWorking ? "Configuring…" : "Set Up Broadcast Server") {
                        broadcastServer.setUpServer()
                    }
                    .disabled(!broadcastServer.mediamtxInstalled || broadcastServer.isWorking)
                    .help("Writes the mediamtx config (encrypted RTSPS ingest, OBS-only output), generates credentials + TLS certificate, and restarts the service.")

                    Spacer()

                    Button {
                        guard let url = broadcastServer.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        linkCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            linkCopied = false
                        }
                    } label: {
                        Label(linkCopied ? "Copied" : "Copy Link", systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(broadcastServer.shareURL == nil)
                    .help("Copy the pairing link to the clipboard")

                    Button {
                        guard let url = broadcastServer.shareURL,
                              let service = NSSharingService(named: .sendViaAirDrop) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                    }
                    .disabled(broadcastServer.shareURL == nil)
                    .help("Send the pairing link to your Vision Pro via AirDrop")
                }

                if let error = broadcastServer.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(broadcastServer.mediamtxInstalled
                     ? "Configures the local mediamtx server for encrypted ingest from the Vision Pro, then AirDrop the pairing link to auto-fill VisionVNC's Broadcast tab."
                     : "Install the server first: brew install mediamtx")
            }

            Section {
                SecureField("WebSocket password", text: $broadcastServer.obsPassword)
                    .help("The password from OBS → Tools → WebSocket Server Settings (leave empty if authentication is disabled).")

                HStack {
                    Button(broadcastServer.isOBSWorking ? "Adding…" : "Add Sources to OBS") {
                        broadcastServer.addSourcesToOBS()
                    }
                    .disabled(!broadcastServer.mediamtxInstalled || broadcastServer.isOBSWorking)
                    .help("Creates \"Vision Pro Camera\" and \"Vision Pro View\" Browser Sources in the current OBS scene, with audio routed into the OBS mixer.")

                    if let obsStatus = broadcastServer.obsStatusText {
                        Text(obsStatus)
                            .font(.caption)
                            .foregroundStyle(obsStatus.hasPrefix("OBS scene") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
            } header: {
                Text("OBS")
            } footer: {
                Text("In OBS, enable Tools → WebSocket Server Settings, press Show Connect Info → Copy Password, then click Add Sources to OBS — it picks the password up from the clipboard if the field is empty.")
            }
        }
    }
}

// MARK: - Remote Control (SSH)

private struct RemoteControlPane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                if let fingerprint = controller.macHostFingerprint {
                    LabeledContent("This Mac") {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Button("Add Vision Pro Key from Clipboard") {
                    controller.addKeyFromClipboard()
                }

                if let status = controller.keyActionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Copy the key from VisionVNC (Projects → Copy Public Key), then add it here. Enable Remote Login in System Settings → General → Sharing for SSH to work.")
            }

            if !controller.installedVisionKeys.isEmpty {
                Section("Authorized Keys") {
                    ForEach(controller.installedVisionKeys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.comment.isEmpty ? key.type : key.comment)
                                Text(key.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.removeKey(key)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .onAppear { controller.refreshKeys() }
    }
}

// MARK: - Keyboard Control

private struct KeyboardPane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                Toggle("Allow keyboard control", isOn: $controller.injectionEnabled)
                    .help("Lets a paired Vision Pro type text into the frontmost Mac app over an encrypted channel. Text and backspace only — never shortcuts or modifier keys.")

                if controller.injectionEnabled && !controller.injection.accessibilityTrusted {
                    HStack {
                        Text("Needs Accessibility permission to type.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Accessibility…") {
                            controller.grantAccessibility()
                        }
                    }
                } else if controller.injectionEnabled {
                    LabeledContent("Status", value: "Ready — remote typing routes through this Mac.")
                }
            } footer: {
                Text("Text-only injection (no modifier keys) keeps remote typing from triggering shortcuts. In VisionVNC, link this companion to a VNC connection to use it.")
            }
        }
    }
}
