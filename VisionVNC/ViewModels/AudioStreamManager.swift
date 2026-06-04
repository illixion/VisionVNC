import Foundation
import os
import Network
import AVFoundation
import Observation
import UIKit

/// Receives an uncompressed PCM audio stream from the VisionVNC Audio Sender
/// Mac menu bar app and plays it through AVAudioEngine.
///
/// Because audio rendered by a regular visionOS app honors the per-app
/// "Spatial Audio off" setting, this bypasses the forced spatialization
/// that Mac Virtual Display applies to its own audio.
@Observable
final class AudioStreamManager {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case streaming
        case error(String)
    }

    var state: ConnectionState = .idle
    var connectionTitle: String = ""

    /// Now-playing state mirrored from the Mac's Music.app (nil when
    /// nothing is playing or Music is closed).
    var nowPlaying: NowPlayingInfo?
    var artworkImage: UIImage?
    /// Local mute: drops the stream's audio on this end without
    /// disconnecting or affecting Mac playback.
    private(set) var isMuted = false
    /// True when the audio window was opened via pushWindow from the
    /// connection manager — dismissing it then restores the manager
    /// automatically. False after a space-restoration relaunch (standalone).
    var openedViaPush = false
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var bytesReceived: Int = 0

    var formatLabel: String {
        guard sampleRate > 0 else { return "—" }
        let channels = channelCount == 1 ? "Mono" : channelCount == 2 ? "Stereo" : "\(channelCount)ch"
        return "\(channels) · \(Int(sampleRate)) Hz · Float32 PCM"
    }

    private var receiver: AudioStreamReceiver?

    /// Last event (connect or data) timestamp — drives the health probe
    /// used to detect a silently dead TCP connection after the app was
    /// suspended (visionOS space restore / scenePhase flips).
    private var lastActivityAt: Date?
    private var pendingCloseTask: Task<Void, Never>?
    /// Artwork bytes waiting for the matching nowPlaying frame's artworkID.
    private var pendingArtwork: Data?

    /// Auto-reconnect after unexpected drops. On a space-restoration
    /// relaunch the first attempt typically fails (the network stack isn't
    /// ready that early), so a single try isn't enough — retry with backoff
    /// until the stream is up, the user disconnects, or the window closes.
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2
    private static let maxRetryDelay: TimeInterval = 30

    private enum DefaultsKeys {
        static let host = "lastAudioHost"
        static let port = "lastAudioPort"
        static let title = "lastAudioTitle"
    }

    /// True while streaming and data has arrived recently. The receiver
    /// reports byte counts every ~0.5 s, so a few seconds of silence means
    /// the connection is dead even if no error has surfaced yet.
    var isHealthy: Bool {
        guard state == .streaming, let lastActivityAt else { return false }
        return Date().timeIntervalSince(lastActivityAt) < 2.5
    }

    func connect(hostname: String, port: UInt16, title: String) {
        disconnect()
        connectionTitle = title
        state = .connecting
        bytesReceived = 0
        sampleRate = 0
        channelCount = 0
        lastActivityAt = nil
        nowPlaying = nil
        artworkImage = nil
        pendingArtwork = nil
        isMuted = false

        // Remember the target so the stream can resume after the app is
        // relaunched by visionOS space restoration of a snapped window.
        let defaults = UserDefaults.standard
        defaults.set(hostname, forKey: DefaultsKeys.host)
        defaults.set(Int(port), forKey: DefaultsKeys.port)
        defaults.set(title, forKey: DefaultsKeys.title)

        let receiver = AudioStreamReceiver(hostname: hostname, port: port)
        receiver.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        self.receiver = receiver
        receiver.start()
    }

    func disconnect() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        retryTask?.cancel()
        retryTask = nil
        receiver?.stop()
        receiver = nil
        state = .idle
    }

    /// Explicit user disconnect: also forget the last connection so the
    /// stream doesn't auto-resurrect on the next window restore.
    func userDisconnect() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKeys.host)
        defaults.removeObject(forKey: DefaultsKeys.port)
        defaults.removeObject(forKey: DefaultsKeys.title)
        disconnect()
    }

    /// Reconnects to the last-used sender, if one is remembered.
    func reconnectLast() {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: DefaultsKeys.host),
              let port = UInt16(exactly: defaults.integer(forKey: DefaultsKeys.port)),
              port > 0 else { return }
        connect(hostname: host, port: port, title: defaults.string(forKey: DefaultsKeys.title) ?? "")
    }

    /// Called when the audio window (re)appears or its scene becomes
    /// active: cancels any pending close-grace disconnect and rebuilds the
    /// connection if it is idle, errored, or silently dead.
    func ensureConnected() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        switch state {
        case .connecting:
            break
        case .idle, .error:
            reconnectLast()
        case .streaming:
            if !isHealthy {
                AppLog.audioStream.line("Connection unhealthy after scene activation — reconnecting")
                reconnectLast()
            }
        }
    }

    /// Called from the window's onDisappear. visionOS also fires this on
    /// transient hides (space restore, snapping), so tear down only after a
    /// grace period — `ensureConnected()` cancels it if the window returns.
    func windowDisappeared() {
        pendingCloseTask?.cancel()
        pendingCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.disconnect()
        }
    }

    /// Toggles local mute (drop incoming audio; connection stays up).
    func setMuted(_ muted: Bool) {
        isMuted = muted
        receiver?.setPaused(muted)
    }

    /// Sends a media transport command to control Music.app on the Mac.
    func sendCommand(_ command: MediaCommand) {
        receiver?.send(command)
    }

    private func handle(_ event: AudioStreamReceiver.Event) {
        switch event {
        case .connected(let rate, let channels):
            sampleRate = rate
            channelCount = channels
            state = .streaming
            lastActivityAt = Date()
            retryDelay = 2
            AppLog.audioStream.line("Connected: \(channels)ch @ \(Int(rate)) Hz")
        case .bytesReceived(let total):
            bytesReceived = total
            lastActivityAt = Date()
        case .nowPlaying(let info):
            nowPlaying = info.hasTrack ? info : nil
            if info.artworkID == nil {
                artworkImage = nil
            } else if let pendingArtwork {
                artworkImage = UIImage(data: pendingArtwork)
            } // same artworkID as before and no new artwork frame: keep current image
            pendingArtwork = nil
        case .artwork(let data):
            pendingArtwork = data
        case .disconnected(let reason):
            // Ignore events from a receiver we already tore down
            guard receiver != nil else { return }
            receiver = nil
            nowPlaying = nil
            artworkImage = nil
            pendingArtwork = nil
            if let reason {
                state = .error(reason)
                AppLog.audioStream.line("Disconnected: \(reason)")
            } else {
                state = .idle
                AppLog.audioStream.line("Disconnected: sender closed the stream")
            }
            scheduleRetry()
        }
    }

    /// Retries the last connection after an unexpected drop, with capped
    /// exponential backoff. Cancelled by disconnect()/userDisconnect()
    /// (and therefore by the window-close grace teardown).
    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        AppLog.audioStream.line("Reconnecting in \(Int(delay)) s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectLast()
        }
    }
}

/// Network + audio pipeline. All work happens on its serial queue and the
/// NWConnection callback queue — off the main actor, same pattern as
/// MoonlightAudioRenderer. Events are marshalled back via `onEvent`.
final class AudioStreamReceiver: @unchecked Sendable {

    enum Event: Sendable {
        case connected(sampleRate: Double, channels: Int)
        case bytesReceived(Int)
        case nowPlaying(NowPlayingInfo)
        case artwork(Data)
        case disconnected(String?)
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let hostname: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.illixion.VisionVNC.audio-stream", qos: .userInteractive)

    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var pending = Data()
    private nonisolated(unsafe) var header: AudioStreamHeader?
    private nonisolated(unsafe) var stopped = false

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// Frames scheduled before starting playback, to absorb network jitter.
    /// At a typical ~10 ms device IO cadence this is ~40 ms of buffer.
    private static let prebufferFrameCount = 4
    private nonisolated(unsafe) var scheduledFrames = 0
    private nonisolated(unsafe) var totalBytes = 0
    /// While true, incoming PCM is dropped instead of scheduled (local
    /// pause); the connection keeps draining.
    private nonisolated(unsafe) var playbackPaused = false
    private nonisolated(unsafe) var droppedWhilePaused = 0

    nonisolated init(hostname: String, port: UInt16) {
        self.hostname = hostname
        self.port = port
    }

    nonisolated func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.disconnected("Invalid port \(port)"))
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(
            host: NWEndpoint.Host(hostname),
            port: nwPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
            case .failed(let error):
                self.fail("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    nonisolated func stop() {
        queue.async { [self] in
            stopped = true
            onEvent = nil
            connection?.cancel()
            connection = nil
            teardownAudio()
        }
    }

    // MARK: - Receive / Parse

    private nonisolated func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }

            if let data, !data.isEmpty {
                self.pending.append(data)
                self.totalBytes += data.count
                self.processPending()
            }

            if isComplete {
                self.fail(nil) // sender closed the stream cleanly
            } else if let error {
                self.fail("Receive error: \(error.localizedDescription)")
            } else {
                self.receiveLoop()
            }
        }
    }

    private nonisolated func processPending() {
        // Header first
        if header == nil {
            guard pending.count >= AudioStreamProtocol.headerSize else { return }
            guard let parsed = AudioStreamHeader(parsing: pending) else {
                fail("Invalid stream header — is the sender the VisionVNC Audio Sender?")
                return
            }
            pending.removeFirst(AudioStreamProtocol.headerSize)
            header = parsed
            guard setupAudio(header: parsed) else {
                fail("Unsupported audio format (\(parsed.channelCount)ch @ \(parsed.sampleRate) Hz)")
                return
            }
            onEvent?(.connected(sampleRate: parsed.sampleRate, channels: parsed.channelCount))
        }

        // Then typed, length-prefixed frames
        while let length = AudioStreamProtocol.decodeFrameLength(pending) {
            guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
                fail("Malformed frame (\(length) bytes)")
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard pending.count >= frameEnd else { return }

            let type = pending[pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)]
            let payload = pending.subdata(in: pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<pending.startIndex.advanced(by: frameEnd))
            pending.removeFirst(frameEnd)

            switch AudioStreamProtocol.FrameType(rawValue: type) {
            case .pcm:
                schedule(payload)
            case .nowPlaying:
                // Malformed metadata is logged and skipped — never fail
                // the audio stream over it.
                if let info = NowPlayingInfo.decode(payload) {
                    onEvent?(.nowPlaying(info))
                } else {
                    AppLog.audioStream.line("Skipping malformed now-playing frame (\(payload.count) bytes)")
                }
            case .artwork:
                onEvent?(.artwork(payload))
            case .command, nil:
                break // not receiver-bound / unknown — skip
            }
        }
    }

    /// Sends a media transport command to the Mac sender.
    nonisolated func send(_ command: MediaCommand) {
        queue.async { [self] in
            guard !stopped, let connection,
                  let payload = MediaCommandMessage(command: command).encoded() else { return }
            let frame = AudioStreamProtocol.encodeFrame(.command, payload)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Locally pauses/resumes playback without disconnecting: incoming PCM
    /// is dropped while paused (no stale backlog on resume) and the
    /// connection keeps draining so it stays healthy.
    nonisolated func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard playbackPaused != paused else { return }
            playbackPaused = paused
            if paused {
                playerNode?.pause()
            } else {
                // Restart with the normal jitter prebuffer.
                playerNode?.stop()
                scheduledFrames = 0
            }
        }
    }

    private nonisolated func fail(_ reason: String?) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        teardownAudio()
        onEvent?(.disconnected(reason))
    }

    // MARK: - Audio

    private nonisolated func setupAudio(header: AudioStreamHeader) -> Bool {
        // The wire format is interleaved, but AVAudioEngine throws an
        // NSException ("SetFormat") when connecting a player node to the
        // mixer with an interleaved Float32 format — the engine graph
        // requires the standard (deinterleaved) format. We deinterleave
        // in schedule() instead.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: header.sampleRate,
            channels: AVAudioChannelCount(header.channelCount)
        ) else { return false }

        // Opt out of visionOS's default AutomaticSpatialAudio. The stream is
        // an already-mixed stereo signal from the Mac; spatializing it again
        // would double-process it. AVAudioEngine isn't a Now Playing candidate
        // so the per-app Spatialize Stereo toggle doesn't apply — bypass at
        // the session level instead.
        // .mixWithOthers: coexist with other visionOS apps and VoIP calls
        // instead of taking exclusive audio focus. Deliberate trade-off:
        // a mixable session is ineligible for Now Playing / Control Center.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setIntendedSpatialExperience(.bypassed)
            // Become a Now Playing candidate so visionOS keeps playback running
            // (and doesn't duck the audio) when the user looks at other windows.
            try session.setIsNowPlayingCandidate(true)
        } catch {
            AppLog.audioStream.line("Failed to configure audio session: \(error)")
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            AppLog.audioStream.line("Failed to start audio engine: \(error)")
            return false
        }

        audioEngine = engine
        playerNode = player
        audioFormat = format
        scheduledFrames = 0
        return true
    }

    private nonisolated func teardownAudio() {
        playerNode?.stop()
        audioEngine?.stop()
        if let engine = audioEngine, let player = playerNode {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        audioEngine = nil
        playerNode = nil
        audioFormat = nil
    }

    private nonisolated func schedule(_ payload: Data) {
        guard let playerNode, let format = audioFormat else { return }

        // Local pause: drop frames (no stale backlog on resume) but keep
        // emitting throttled stats so the connection health probe stays alive.
        if playbackPaused {
            droppedWhilePaused += 1
            if droppedWhilePaused % 50 == 0 {
                onEvent?(.bytesReceived(totalBytes))
            }
            return
        }

        let channels = Int(format.channelCount)
        let bytesPerWireFrame = channels * MemoryLayout<Float32>.size
        guard payload.count % bytesPerWireFrame == 0 else { return }
        let frameCount = AVAudioFrameCount(payload.count / bytesPerWireFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        // Deinterleave wire Float32 into the engine's per-channel buffers
        payload.withUnsafeBytes { raw in
            guard let channelData = buffer.floatChannelData else { return }
            let samples = raw.bindMemory(to: Float32.self)
            for channel in 0..<channels {
                let out = channelData[channel]
                for frame in 0..<Int(frameCount) {
                    out[frame] = samples[frame * channels + channel]
                }
            }
        }

        playerNode.scheduleBuffer(buffer)
        scheduledFrames += 1

        // Hold playback until a small jitter buffer has accumulated
        if scheduledFrames == Self.prebufferFrameCount {
            playerNode.play()
        }

        // Throttled stats update (~every 0.5 s at 10 ms frames)
        if scheduledFrames % 50 == 0 {
            onEvent?(.bytesReceived(totalBytes))
        }
    }
}
