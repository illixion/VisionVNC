import SwiftUI

/// Status window for an active audio-only stream from the
/// VisionVNC Audio Sender Mac menu bar app.
struct AudioStreamView: View {
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: iconName)
                    .font(.system(size: 56))
                    .foregroundStyle(audioManager.state == .streaming ? Color.accentColor : .secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: audioManager.state == .streaming)

                VStack(spacing: 6) {
                    Text(statusText)
                        .font(.headline)

                    if audioManager.state == .streaming {
                        Text(audioManager.formatLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(dataLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    if case .error(let message) = audioManager.state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Button(role: .destructive) {
                    audioManager.userDisconnect()
                    // Pushed windows restore the connection manager on
                    // dismiss. Standalone (space-restored) windows must
                    // surface it explicitly — visionOS won't let an app
                    // close its own last window.
                    if !audioManager.openedViaPush {
                        openWindow(id: "main")
                    }
                    audioManager.openedViaPush = false
                    dismissWindow(id: "audio-stream")
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
            .padding(32)
            .navigationTitle(audioManager.connectionTitle.isEmpty ? "Audio Stream" : audioManager.connectionTitle)
        }
        .onAppear {
            // Resumes the last stream when visionOS restores this window
            // after an app relaunch (snapped-window space restoration).
            audioManager.ensureConnected()
        }
        .onDisappear {
            // Grace-period teardown — transient hides (space restore)
            // re-trigger onAppear/scenePhase, which cancels it.
            audioManager.windowDisappeared()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                audioManager.ensureConnected()
            }
        }
    }

    private var iconName: String {
        switch audioManager.state {
        case .streaming: "speaker.wave.3.fill"
        case .connecting: "speaker.wave.1"
        case .error: "speaker.slash"
        case .idle: "speaker"
        }
    }

    private var statusText: String {
        switch audioManager.state {
        case .idle: "Not Connected"
        case .connecting: "Connecting…"
        case .streaming: "Streaming"
        case .error: "Connection Lost"
        }
    }

    private var dataLabel: String {
        let mb = Double(audioManager.bytesReceived) / 1_048_576
        return String(format: "%.1f MB received", mb)
    }
}
