import SwiftUI
import AppKit
import os

/// Menu bar companion app for VisionVNC: captures system audio via a
/// Core Audio process tap and streams it as uncompressed PCM to the
/// VisionVNC app on Apple Vision Pro.
///
/// Workaround for macOS forcing Spatial Audio on for Mac Virtual Display
/// audio — audio played by the visionOS app honors the per-app setting.
@main
struct AudioSenderApp: App {
    @State private var controller = AudioStreamerController()

    init() {
        // Surface the Local Network permission prompt at launch rather than
        // waiting for the first stream — reading hostName performs a
        // local-network lookup, which is enough to trigger the dialog.
        let hostName = ProcessInfo.processInfo.hostName
        Logger(subsystem: "com.illixion.VisionVNCAudioSender", category: "App")
            .info("Local network access prompt triggered (host: \(hostName, privacy: .private))")
    }

    var body: some Scene {
        MenuBarExtra {
            AudioSenderMenuView(controller: controller)
        } label: {
            if let track = controller.menuBarTrackText {
                Text("\(track) ♪")
            } else {
                Image(systemName: controller.isRunning ? "speaker.wave.2.fill" : "speaker.slash")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct AudioSenderMenuView: View {
    @Bindable var controller: AudioStreamerController
    @State private var copied = false

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.token, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Opens the AirDrop sheet with the token's x-callback URL. AirDropping
    /// it to the Vision Pro launches VisionVNC and auto-fills the token.
    private func shareToken() {
        guard let url = controller.tokenShareURL,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: [url])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VisionVNC Audio Sender")
                .font(.headline)

            Toggle("Stream system audio", isOn: $controller.isRunning)
                .toggleStyle(.switch)

            Toggle("Mute Mac output while streaming", isOn: $controller.muteWhileStreaming)
                .toggleStyle(.checkbox)
                .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the VisionVNC app.")

            Toggle("Show track in menu bar", isOn: $controller.showTrackInMenuBar)
                .toggleStyle(.checkbox)
                .help("Shows the current Music.app track as \"Artist – Title\" in the menu bar while streaming.")

            Divider()

            Group {
                Text(controller.statusText)
                if controller.isRunning {
                    Text("Port \(String(controller.port)) · \(controller.formatText)")
                }
                if let nowPlaying = controller.nowPlaying, nowPlaying.hasTrack {
                    Text("♪ \(nowPlaying.title ?? "") — \(nowPlaying.artist ?? "")")
                        .lineLimit(1)
                }
                if let error = controller.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Access Token")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    Text(controller.token)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                    Button {
                        copyToken()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the token to the clipboard")

                    Button {
                        shareToken()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Send the token to your Vision Pro via AirDrop")
                }

                Text("Enter this token in VisionVNC, or AirDrop it to auto-fill. The token both authorizes the connection and encrypts it (TLS) — no VPN needed. Keep it secret; regenerate to revoke access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Regenerate Token", role: .destructive) {
                    controller.regenerateToken()
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Control (SSH)")
                    .font(.subheadline.weight(.semibold))

                if let fingerprint = controller.macHostFingerprint {
                    Text("This Mac: \(fingerprint)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Add Vision Pro Key from Clipboard") {
                    controller.addKeyFromClipboard()
                }
                .controlSize(.small)

                if let status = controller.keyActionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(controller.installedVisionKeys) { key in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.comment.isEmpty ? key.type : key.comment)
                                .font(.caption)
                            Text(key.fingerprint)
                                .font(.system(.caption2, design: .monospaced))
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
                        .controlSize(.small)
                    }
                }

                Text("Copy the key from VisionVNC (Projects → Copy Public Key), then add it here. Enable Remote Login in System Settings → General → Sharing for SSH to work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Quit") {
                controller.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { controller.refreshKeys() }
    }
}

/// Orchestrates the system audio tap and the TCP stream server.
@Observable
final class AudioStreamerController {

    let port: UInt16 = AudioStreamProtocol.defaultPort

    /// Remembers whether the user had streaming on, so the menu bar app
    /// resumes it automatically on the next launch (e.g. after login).
    private static let autoStartKey = "autoStartStreaming"

    init() {
        if UserDefaults.standard.bool(forKey: Self.autoStartKey) {
            // Defer past App init so it runs on the main actor's run loop —
            // starting the tap/server synchronously during init is too early.
            Task { @MainActor in self.start() }
        }
    }

    /// Persistent static auth token — clients must present it to connect.
    /// Loaded from (or generated into) UserDefaults on init; the didSet
    /// keeps the store in sync when regenerated.
    var token: String = AudioStreamerController.loadOrCreateToken() {
        didSet { UserDefaults.standard.set(token, forKey: "audioStreamToken") }
    }

    /// x-callback URL carrying the token, for AirDrop to the Vision Pro.
    var tokenShareURL: URL? {
        AudioTokenURL.make(token: token)
    }

    private static func loadOrCreateToken() -> String {
        if let existing = UserDefaults.standard.string(forKey: "audioStreamToken"), !existing.isEmpty {
            return existing
        }
        let generated = AudioToken.generate()
        UserDefaults.standard.set(generated, forKey: "audioStreamToken")
        return generated
    }

    /// Discards the current token and generates a fresh one. Any connected
    /// client is dropped (its old token no longer matches) and must re-pair.
    func regenerateToken() {
        token = AudioToken.generate()
        if isRunning { start() } // restart server with the new token
    }

    // MARK: - SSH authorized keys (remote control)

    /// VisionVNC-added keys currently in ~/.ssh/authorized_keys.
    var installedVisionKeys: [AuthorizedKey] = []
    var keyActionStatus: String?
    var macHostFingerprint: String?

    func refreshKeys() {
        installedVisionKeys = AuthorizedKeysManager.read().filter { $0.comment.contains("visionvnc") }
        if macHostFingerprint == nil {
            macHostFingerprint = AuthorizedKeysManager.macHostFingerprint()
        }
    }

    /// Reads a public key from the clipboard (Universal Clipboard from the
    /// Vision Pro), prompts for explicit approval, then installs it.
    func addKeyFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            keyActionStatus = "Clipboard is empty."
            return
        }
        guard let key = AuthorizedKeysManager.parse(raw) else {
            keyActionStatus = "Clipboard isn't an SSH public key."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Authorize this Vision Pro for SSH?"
        alert.informativeText = """
        \(key.type)
        \(key.fingerprint)\(key.comment.isEmpty ? "" : "\n\(key.comment)")

        Allowing adds it to ~/.ssh/authorized_keys, letting that device log in over SSH (key-based).
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            keyActionStatus = "Cancelled."
            return
        }
        do {
            try AuthorizedKeysManager.add(line: raw)
            refreshKeys()
            keyActionStatus = "Authorized \(key.fingerprint)."
        } catch {
            keyActionStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func removeKey(_ key: AuthorizedKey) {
        do {
            try AuthorizedKeysManager.remove(base64: key.base64)
            refreshKeys()
            keyActionStatus = "Removed \(key.fingerprint)."
        } catch {
            keyActionStatus = "Failed: \(error.localizedDescription)"
        }
    }

    var clientCount = 0
    var lastError: String?
    private(set) var streamFormat: SystemAudioTap.StreamFormat?
    private(set) var nowPlaying: NowPlayingInfo?

    private var tap: SystemAudioTap?
    private var server: AudioStreamServer?
    private var musicBridge: MusicAppBridge?

    var isRunning: Bool {
        get { tap != nil }
        set {
            guard newValue != isRunning else { return }
            UserDefaults.standard.set(newValue, forKey: Self.autoStartKey)
            newValue ? start() : stop()
        }
    }

    var showTrackInMenuBar: Bool {
        get {
            access(keyPath: \.showTrackInMenuBar)
            return UserDefaults.standard.bool(forKey: "showTrackInMenuBar")
        }
        set {
            withMutation(keyPath: \.showTrackInMenuBar) {
                UserDefaults.standard.set(newValue, forKey: "showTrackInMenuBar")
            }
        }
    }

    /// "Artist – Title" for the menu bar label, or nil when the option is
    /// off, nothing is playing (paused hides it too), or metadata is missing.
    var menuBarTrackText: String? {
        guard showTrackInMenuBar,
              let nowPlaying, nowPlaying.hasTrack, nowPlaying.isPlaying else { return nil }
        let parts = [nowPlaying.artist, nowPlaying.title].compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " – ")
    }

    var muteWhileStreaming: Bool {
        get {
            access(keyPath: \.muteWhileStreaming)
            return UserDefaults.standard.object(forKey: "muteWhileStreaming") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.muteWhileStreaming) {
                UserDefaults.standard.set(newValue, forKey: "muteWhileStreaming")
            }
            // The mute behavior is baked into the tap at creation — restart
            // the tap (only matters while a client is actually connected,
            // since the tap runs unmuted with no clients).
            if isRunning, clientCount > 0 {
                restartTap(muted: newValue)
            }
        }
    }

    var statusText: String {
        guard isRunning else { return "Not streaming" }
        switch clientCount {
        case 0: return "Listening — waiting for VisionVNC to connect"
        default: return "Streaming to VisionVNC"
        }
    }

    var formatText: String {
        guard let format = streamFormat else { return "—" }
        return "\(format.channelCount)ch \(Int(format.sampleRate)) Hz int24"
    }

    func start() {
        stop()
        lastError = nil

        // Start unmuted — local output is only silenced once a client
        // actually connects (see the client-count handler below).
        let tap = SystemAudioTap()
        do {
            let format = try tap.start(muteSystemOutput: false)
            streamFormat = format

            let server = AudioStreamServer(
                port: port,
                token: token,
                header: AudioStreamHeader(sampleRate: format.sampleRate, channelCount: format.channelCount)
            )
            server.onClientCountChange = { [weak self] count in
                Task { @MainActor [weak self] in
                    self?.handleClientCountChange(count)
                }
            }
            try server.start()

            tap.onAudio = { [weak server] pcm in
                server?.broadcast(pcm)
            }

            // Music.app now-playing metadata + transport commands
            let bridge = MusicAppBridge()
            bridge.onNowPlaying = { [weak self] info, artwork in
                self?.handleNowPlaying(info, artwork: artwork)
            }
            server.onCommand = { [weak bridge] command in
                Task { @MainActor [weak bridge] in
                    bridge?.send(command)
                }
            }
            bridge.start()

            self.tap = tap
            self.server = server
            self.musicBridge = bridge
        } catch {
            tap.stop()
            streamFormat = nil
            lastError = error.localizedDescription
        }
    }

    private func handleClientCountChange(_ count: Int) {
        let previous = clientCount
        clientCount = count
        guard muteWhileStreaming, isRunning else { return }
        // Mute local output only while someone is listening
        if previous == 0, count > 0 {
            restartTap(muted: true)
        } else if previous > 0, count == 0 {
            restartTap(muted: false)
        }
    }

    /// Rebuilds the tap with the given mute behavior (it's baked in at
    /// creation time). The server and its already-sent header are kept —
    /// the tap format doesn't change with mute behavior.
    private func restartTap(muted: Bool) {
        guard isRunning else { return }
        tap?.onAudio = nil
        tap?.stop()
        tap = nil

        let newTap = SystemAudioTap()
        do {
            let format = try newTap.start(muteSystemOutput: muted)
            if let old = streamFormat,
               format.sampleRate != old.sampleRate || format.channelCount != old.channelCount {
                // Stream format changed under us — connected clients hold a
                // stale header. Restart everything so a reconnect resyncs.
                newTap.stop()
                start()
                return
            }
            newTap.onAudio = { [weak server] pcm in
                server?.broadcast(pcm)
            }
            tap = newTap
        } catch {
            lastError = error.localizedDescription
            stop()
        }
    }

    func stop() {
        tap?.onAudio = nil
        tap?.stop()
        tap = nil
        musicBridge?.stop()
        musicBridge = nil
        server?.stop()
        server = nil
        clientCount = 0
        streamFormat = nil
        nowPlaying = nil
    }

    private func handleNowPlaying(_ info: NowPlayingInfo?, artwork: Data?) {
        nowPlaying = info
        let infoFrame = info?.encoded().map { AudioStreamProtocol.encodeFrame(.nowPlaying, $0) }
            ?? NowPlayingInfo(isPlaying: false).encoded().map { AudioStreamProtocol.encodeFrame(.nowPlaying, $0) }
        let artworkFrame = artwork.map { AudioStreamProtocol.encodeFrame(.artwork, $0) }
        server?.updateMetadata(infoFrame: infoFrame, artworkFrame: artworkFrame)
    }
}
