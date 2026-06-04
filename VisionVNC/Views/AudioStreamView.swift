import SwiftUI

/// Mini-player window for an active audio-only stream from the
/// VisionVNC Audio Sender Mac menu bar app: large album art (falls back
/// to the speaker status glyph) over a transport row, with technical
/// stream info tucked into a corner of the art.
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
            artworkPane

            VStack(spacing: 2) {
                Text(primaryLine)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            controlsRow
                .padding(.top, 14)
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

    // MARK: - Artwork

    /// Big square album art; when there is none (streaming-only Apple
    /// Music tracks expose no artwork via scripting) or nothing playing,
    /// shows the speaker status glyph instead. Technical stream info sits
    /// in the bottom-trailing corner.
    private var artworkPane: some View {
        ZStack {
            if let artwork = audioManager.artworkImage {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                Image(systemName: iconName)
                    .font(.system(size: 64))
                    .foregroundStyle(audioManager.state == .streaming ? Color.accentColor : .secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: audioManager.state == .streaming)
            }
        }
        .frame(width: Self.playerWidth, height: Self.playerWidth)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if audioManager.state == .streaming {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(audioManager.formatLabel)
                    Text(dataLabel)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
        }
    }

    // MARK: - Labels

    private var primaryLine: String {
        if let title = audioManager.nowPlaying?.title, !title.isEmpty {
            return title
        }
        return statusText
    }

    private var secondaryLine: String {
        if let artist = audioManager.nowPlaying?.artist, !artist.isEmpty {
            return artist
        }
        if case .error(let message) = audioManager.state {
            return message
        }
        return " " // keep layout height stable
    }

    // MARK: - Controls

    /// [disconnect] [prev] [play/pause] [next] [mute]
    private var controlsRow: some View {
        HStack(spacing: 26) {
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
                audioManager.sendCommand(.previous)
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!hasTransport)
            .help("Previous track")

            Button {
                audioManager.sendCommand(.toggle)
            } label: {
                Image(systemName: audioManager.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
            }
            .disabled(!hasTransport)
            .help("Play / pause")

            Button {
                audioManager.sendCommand(.next)
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasTransport)
            .help("Next track")

            Button {
                audioManager.setMuted(!audioManager.isMuted)
            } label: {
                Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
            }
            .disabled(audioManager.state != .streaming)
            .help(audioManager.isMuted ? "Unmute" : "Mute")
        }
        .buttonStyle(.borderless)
        .font(.title)
    }

    private var hasTransport: Bool {
        audioManager.state == .streaming && audioManager.nowPlaying != nil
    }

    // MARK: - Status

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
        return String(format: "%.1f MB", mb)
    }
}
