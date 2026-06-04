import Foundation
import Network
import AVFoundation
import Observation

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
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var bytesReceived: Int = 0

    var formatLabel: String {
        guard sampleRate > 0 else { return "—" }
        let channels = channelCount == 1 ? "Mono" : channelCount == 2 ? "Stereo" : "\(channelCount)ch"
        return "\(channels) · \(Int(sampleRate)) Hz · Float32 PCM"
    }

    private var receiver: AudioStreamReceiver?

    func connect(hostname: String, port: UInt16, title: String) {
        disconnect()
        connectionTitle = title
        state = .connecting
        bytesReceived = 0
        sampleRate = 0
        channelCount = 0

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
        receiver?.stop()
        receiver = nil
        state = .idle
    }

    private func handle(_ event: AudioStreamReceiver.Event) {
        switch event {
        case .connected(let rate, let channels):
            sampleRate = rate
            channelCount = channels
            state = .streaming
        case .bytesReceived(let total):
            bytesReceived = total
        case .disconnected(let reason):
            // Ignore events from a receiver we already tore down
            guard receiver != nil else { return }
            receiver = nil
            if let reason {
                state = .error(reason)
            } else {
                state = .idle
            }
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

        // Then length-prefixed PCM frames
        while let length = AudioStreamProtocol.decodeFrameLength(pending) {
            guard length <= AudioStreamProtocol.maxFrameBytes else {
                fail("Malformed frame (\(length) bytes)")
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard pending.count >= frameEnd else { return }

            let payload = pending.subdata(in: pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)..<pending.startIndex.advanced(by: frameEnd))
            pending.removeFirst(frameEnd)
            schedule(payload)
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
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("[AudioStream] Failed to configure audio session: \(error)")
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            print("[AudioStream] Failed to start audio engine: \(error)")
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
