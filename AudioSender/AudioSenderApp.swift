import SwiftUI

/// Menu bar companion app for VisionVNC: captures system audio via a
/// Core Audio process tap and streams it as uncompressed PCM to the
/// VisionVNC app on Apple Vision Pro.
///
/// Workaround for macOS forcing Spatial Audio on for Mac Virtual Display
/// audio — audio played by the visionOS app honors the per-app setting.
@main
struct AudioSenderApp: App {
    @State private var controller = AudioStreamerController()

    var body: some Scene {
        MenuBarExtra {
            AudioSenderMenuView(controller: controller)
        } label: {
            Image(systemName: controller.isRunning ? "speaker.wave.2.fill" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

struct AudioSenderMenuView: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VisionVNC Audio Sender")
                .font(.headline)

            Toggle("Stream system audio", isOn: $controller.isRunning)
                .toggleStyle(.switch)

            Toggle("Mute Mac output while streaming", isOn: $controller.muteWhileStreaming)
                .toggleStyle(.checkbox)
                .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the VisionVNC app.")

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

            Button("Quit") {
                controller.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// Orchestrates the system audio tap and the TCP stream server.
@Observable
final class AudioStreamerController {

    let port: UInt16 = AudioStreamProtocol.defaultPort

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
            newValue ? start() : stop()
        }
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
        return "\(format.channelCount)ch \(Int(format.sampleRate)) Hz Float32"
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
                header: AudioStreamHeader(sampleRate: format.sampleRate, channelCount: format.channelCount)
            )
            server.onClientCountChange = { [weak self] count in
                Task { @MainActor in
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
                Task { @MainActor in
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
