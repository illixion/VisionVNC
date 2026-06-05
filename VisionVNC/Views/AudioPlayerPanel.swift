import SwiftUI

/// Shared mini-player UI for an active audio stream: large album art
/// (falling back to the speaker status glyph), the track title/artist
/// labels, and the prev / play-pause / next / mute transport row.
///
/// Used both by the standalone audio-stream window (`AudioStreamView`,
/// which wraps this with window-management chrome) and by the companion
/// popover surfaced from the remote desktop toolbar. Both observe the same
/// `AudioStreamManager`, so they stay in sync.
struct AudioPlayerPanel: View {
    @Environment(AudioStreamManager.self) private var audioManager

    /// Width of the panel; the album art is an edge-to-edge square of this
    /// size, iTunes-mini-player style.
    var width: CGFloat = 400

    /// Whether the mute toggle is shown inline in the transport row. The
    /// standalone window sets this false and hosts mute in its own action
    /// row; the popover keeps it inline since it has no second row.
    var showsMute: Bool = true

    @State private var showTechInfo = false
    @State private var techInfoHideTask: Task<Void, Never>?

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

            transportRow
                .padding(.top, 14)
        }
        .frame(width: width)
    }

    // MARK: - Artwork

    /// Big square album art; when there is none (streaming-only Apple
    /// Music tracks expose no artwork via scripting) or nothing playing,
    /// shows the speaker status glyph instead. Tapping the art reveals
    /// technical stream info in the bottom-trailing corner, which
    /// auto-hides after a few seconds.
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
        .frame(width: width, height: width)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleTechInfo)
        .overlay(alignment: .bottomTrailing) {
            if audioManager.state == .streaming, showTechInfo {
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
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
    }

    /// Tap on the art: show the tech info and auto-hide it after a few
    /// seconds; tapping again while visible hides it immediately.
    private func toggleTechInfo() {
        techInfoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showTechInfo.toggle()
        }
        guard showTechInfo else { return }
        techInfoHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showTechInfo = false
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

    // MARK: - Transport

    /// [prev] [play/pause] [next] (+ [mute] when `showsMute`)
    private var transportRow: some View {
        HStack(spacing: 34) {
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
                    .font(.system(size: 48))
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

            if showsMute {
                Button {
                    audioManager.setMuted(!audioManager.isMuted)
                } label: {
                    Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .disabled(audioManager.state != .streaming)
                .help(audioManager.isMuted ? "Unmute" : "Mute")
            }
        }
        .buttonStyle(.borderless)
        .font(.largeTitle)
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
