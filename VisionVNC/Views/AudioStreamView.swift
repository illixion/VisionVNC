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

                if audioManager.nowPlaying != nil {
                    nowPlayingCard
                }

                HStack(spacing: 12) {
                    if audioManager.state == .streaming {
                        Button {
                            audioManager.setMuted(!audioManager.isMuted)
                        } label: {
                            Label(
                                audioManager.isMuted ? "Unmute" : "Mute",
                                systemImage: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2"
                            )
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
                        dismissWindow(id: "audio-stream")
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
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

    // MARK: - Now Playing

    /// Card mirroring the Mac's Music.app playback with transport controls.
    private var nowPlayingCard: some View {
        HStack(spacing: 14) {
            Group {
                if let artwork = audioManager.artworkImage {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.fill.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(audioManager.nowPlaying?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = audioManager.nowPlaying?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Button {
                        audioManager.sendCommand(.previous)
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        audioManager.sendCommand(.toggle)
                    } label: {
                        Image(systemName: audioManager.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
                    }
                    Button {
                        audioManager.sendCommand(.next)
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.borderless)
                .font(.body)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 320)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
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
