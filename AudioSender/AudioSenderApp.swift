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

    private var tap: SystemAudioTap?
    private var server: AudioStreamServer?

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
            if isRunning {
                stop()
                start()
            }
        }
    }

    var statusText: String {
        guard isRunning else { return "Not streaming" }
        switch clientCount {
        case 0: return "Streaming — waiting for VisionVNC to connect"
        case 1: return "Streaming to 1 client"
        default: return "Streaming to \(clientCount) clients"
        }
    }

    var formatText: String {
        guard let format = streamFormat else { return "—" }
        return "\(format.channelCount)ch \(Int(format.sampleRate)) Hz Float32"
    }

    func start() {
        stop()
        lastError = nil

        let tap = SystemAudioTap()
        do {
            let format = try tap.start(muteSystemOutput: muteWhileStreaming)
            streamFormat = format

            let server = AudioStreamServer(
                port: port,
                header: AudioStreamHeader(sampleRate: format.sampleRate, channelCount: format.channelCount)
            )
            server.onClientCountChange = { [weak self] count in
                Task { @MainActor in
                    self?.clientCount = count
                }
            }
            try server.start()

            tap.onAudio = { [weak server] pcm in
                server?.broadcast(pcm)
            }

            self.tap = tap
            self.server = server
        } catch {
            tap.stop()
            streamFormat = nil
            lastError = error.localizedDescription
        }
    }

    func stop() {
        tap?.onAudio = nil
        tap?.stop()
        tap = nil
        server?.stop()
        server = nil
        clientCount = 0
        streamFormat = nil
    }
}
