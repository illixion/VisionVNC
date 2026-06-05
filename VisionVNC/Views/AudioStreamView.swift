import SwiftUI

/// Standalone mini-player window for an active audio-only stream from the
/// VisionVNC Audio Sender Mac menu bar app. Wraps the shared
/// `AudioPlayerPanel` (album art + labels + transport) with window-level
/// chrome: lifecycle handling and a disconnect / home / reconnect row.
struct AudioStreamView: View {
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    /// Width of the window content; the album art is an edge-to-edge
    /// square of this size, iTunes-mini-player style.
    private static let playerWidth: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            AudioPlayerPanel(width: Self.playerWidth, showsMute: false)

            utilityRow
                .padding(.top, 28)
                .padding(.bottom, 22)
        }
        .frame(width: Self.playerWidth)
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

    /// Action row: mute + disconnect + home + manual stream-recovery. The
    /// home button lives here instead of the bottom ornament — the ornament
    /// floats over the album art and overlaps the transport controls.
    private var utilityRow: some View {
        HStack(spacing: 28) {
            Button {
                audioManager.setMuted(!audioManager.isMuted)
            } label: {
                Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
            }
            .disabled(audioManager.state != .streaming)
            .help(audioManager.isMuted ? "Unmute" : "Mute")

            Button(role: .destructive) {
                audioManager.userDisconnect()
                // Pushed windows restore the connection manager on
                // dismiss. Standalone (space-restored) windows must
                // surface it explicitly — visionOS won't let an app
                // close its own last window.
                if !audioManager.openedViaPush {
                    openWindow(id: "main")
                }
                dismissWindow(id: "audio-stream")
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Disconnect")

            Button {
                openWindow(id: "main")
            } label: {
                Image(systemName: "house")
            }
            .help("Open the connection manager")

            Button {
                audioManager.reconnectLast()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(audioManager.state == .connecting)
            .help("Reconnect the audio stream")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
}
