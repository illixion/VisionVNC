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

    /// Low-latency (UDP) mode was requested for the current connection.
    private(set) var lowLatencyRequested = false
    /// PCM is actually flowing over the UDP path.
    private(set) var lowLatencyActive = false
    /// Low-latency was requested but UDP couldn't deliver, so the session
    /// fell back to TCP. Sticky for the session — surfaced in the UI.
    private(set) var lowLatencyDegraded = false

    /// One-line transport summary for the UI.
    var transportLabel: String {
        if lowLatencyActive { return "UDP · low-latency" }
        if lowLatencyDegraded { return "TCP · low-latency unavailable" }
        if lowLatencyRequested { return "TCP · negotiating low-latency…" }
        return "TCP"
    }

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
    private var lastReloadAt: Date?
    private static let maxRetryDelay: TimeInterval = 30

    /// Token delivered via an AirDropped x-callback URL, waiting to be
    /// consumed by an open (or freshly opened) connection form. Set by the
    /// app's onOpenURL handler; cleared once a form fills its field.
    var pendingImportedToken: String?

    /// Records a token imported from a `visionvnc://…/setAudioToken` URL so
    /// the connection form can auto-fill it.
    func importToken(_ token: String) {
        pendingImportedToken = token
    }

    private enum DefaultsKeys {
        static let host = "lastAudioHost"
        static let port = "lastAudioPort"
        static let title = "lastAudioTitle"
        static let token = "lastAudioToken"
        static let lowLatency = "lastAudioLowLatency"
    }

    /// Forces TCP for the *next* reconnect without overwriting the user's
    /// saved low-latency preference — set when the UDP path fails to deliver
    /// (one-way block), cleared on the next explicit `connect(...)`.
    private var lowLatencyOverride: Bool?

    /// True while streaming and data has arrived recently. The receiver
    /// reports byte counts every ~0.5 s, so a few seconds of silence means
    /// the connection is dead even if no error has surfaced yet.
    var isHealthy: Bool {
        guard state == .streaming, let lastActivityAt else { return false }
        return Date().timeIntervalSince(lastActivityAt) < 2.5
    }

    func connect(hostname: String, port: UInt16, token: String, title: String, lowLatency: Bool = false) {
        disconnect()
        lowLatencyOverride = nil
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
        lowLatencyRequested = lowLatency
        lowLatencyActive = false
        // Reset the sticky degraded flag only on a genuine low-latency
        // attempt — not on the automatic TCP fallback reconnect, which must
        // preserve the warning for the UI.
        if lowLatency { lowLatencyDegraded = false }

        // Remember the target so the stream can resume after the app is
        // relaunched by visionOS space restoration of a snapped window.
        let defaults = UserDefaults.standard
        defaults.set(hostname, forKey: DefaultsKeys.host)
        defaults.set(Int(port), forKey: DefaultsKeys.port)
        defaults.set(title, forKey: DefaultsKeys.title)
        defaults.set(token, forKey: DefaultsKeys.token)
        defaults.set(lowLatency, forKey: DefaultsKeys.lowLatency)

        let receiver = AudioStreamReceiver(hostname: hostname, port: port, token: token, lowLatency: lowLatency)
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
        defaults.removeObject(forKey: DefaultsKeys.token)
        defaults.removeObject(forKey: DefaultsKeys.lowLatency)
        disconnect()
    }

    /// Reconnects to the last-used sender, if one is remembered.
    func reconnectLast() {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: DefaultsKeys.host),
              let port = UInt16(exactly: defaults.integer(forKey: DefaultsKeys.port)),
              port > 0 else { return }
        // A pending fallback override (UDP failed) forces TCP for this
        // reconnect without disturbing the saved preference.
        let lowLatency = lowLatencyOverride ?? defaults.bool(forKey: DefaultsKeys.lowLatency)
        connect(
            hostname: host,
            port: port,
            token: defaults.string(forKey: DefaultsKeys.token) ?? "",
            title: defaults.string(forKey: DefaultsKeys.title) ?? "",
            lowLatency: lowLatency
        )
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
        case .reloadRequested(let reason):
            // Audio config shifted under us (VoIP call grabbing the session,
            // route change). Reload immediately — same as the manual reload
            // button — instead of the backoff retry path: a fresh receiver
            // re-asserts setCategory/setActive and restores routing.
            guard receiver != nil else { return }
            receiver = nil
            // If the system re-interrupts straight after a reload, don't
            // hot-loop — fall back to the backoff retry path.
            if let lastReloadAt, Date().timeIntervalSince(lastReloadAt) < 2 {
                AppLog.audioStream.line("Reload requested again too soon (\(reason)) — backing off")
                state = .idle
                scheduleRetry()
                return
            }
            lastReloadAt = Date()
            AppLog.audioStream.line("Reloading stream: \(reason)")
            reconnectLast()
        case .authFailed(let reason):
            guard receiver != nil else { return }
            receiver = nil
            nowPlaying = nil
            artworkImage = nil
            pendingArtwork = nil
            // Terminal: don't schedule a retry — the same token would just
            // be rejected again. The user must fix the token and reconnect.
            retryTask?.cancel()
            retryTask = nil
            state = .error(reason)
            AppLog.audioStream.line("Authentication failed: \(reason)")
        case .lowLatencyEngaged:
            lowLatencyActive = true
            lowLatencyDegraded = false
            AppLog.audioStream.line("Low-latency UDP engaged")
        case .lowLatencyUnavailable:
            // UDP couldn't deliver — reconnect once over plain TCP. Keep the
            // saved preference intact (override only this session) so it
            // retries low-latency next time the user connects fresh.
            guard receiver != nil else { return }
            receiver = nil
            lowLatencyActive = false
            lowLatencyDegraded = true
            lowLatencyOverride = false
            AppLog.audioStream.line("Low-latency UDP unavailable — reconnecting over TCP")
            reconnectLast()
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
        /// The audio session/config was lost (VoIP interruption, reroute);
        /// the manager should immediately rebuild via a fresh receiver.
        case reloadRequested(String)
        /// The sender rejected our token. Terminal — auto-retry with the
        /// same token would just loop, so the manager surfaces it and stops.
        case authFailed(String)
        /// First PCM datagram arrived over the low-latency UDP path.
        case lowLatencyEngaged
        /// Low-latency UDP was requested but no PCM arrived over it (one-way
        /// block / firewall). The manager reconnects once over plain TCP
        /// without disturbing the saved preference.
        case lowLatencyUnavailable
        case disconnected(String?)
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let hostname: String
    private let port: UInt16
    private let token: String
    /// When true, PCM is carried over a parallel UDP socket with a smaller
    /// jitter buffer; the TCP connection still handles auth/header/metadata.
    private let lowLatency: Bool
    private let queue = DispatchQueue(label: "com.illixion.VisionVNC.audio-stream", qos: .userInteractive)

    private nonisolated(unsafe) var connection: NWConnection?
    /// Low-latency PCM path. The receiver *listens* on an ephemeral UDP port
    /// (advertised to the sender via a `udpHello` over TCP); the sender
    /// connects out and pushes `pcm` frames (one per datagram). Listening,
    /// rather than connecting, avoids connected-UDP source-port filtering.
    private nonisolated(unsafe) var udpListener: NWListener?
    private nonisolated(unsafe) var udpConnection: NWConnection?
    /// Count of PCM datagrams received over UDP — gates the fallback timer.
    private nonisolated(unsafe) var udpFramesReceived = 0
    private nonisolated(unsafe) var pending = Data()
    private nonisolated(unsafe) var header: AudioStreamHeader?
    private nonisolated(unsafe) var stopped = false

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// Frames scheduled before starting playback, to absorb network jitter.
    /// At a typical ~10 ms device IO cadence the standard buffer is ~40 ms;
    /// low-latency mode trades robustness for a ~20 ms buffer.
    private let prebufferFrameCount: Int
    private nonisolated(unsafe) var scheduledFrames = 0
    private nonisolated(unsafe) var totalBytes = 0
    /// While true, incoming PCM is dropped instead of scheduled (local
    /// pause); the connection keeps draining.
    private nonisolated(unsafe) var playbackPaused = false
    private nonisolated(unsafe) var droppedWhilePaused = 0
    private nonisolated(unsafe) var sessionConfigured = false
    private nonisolated(unsafe) var engineObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var sessionObservers: [any NSObjectProtocol] = []

    nonisolated init(hostname: String, port: UInt16, token: String, lowLatency: Bool = false) {
        self.hostname = hostname
        self.port = port
        self.token = token
        self.lowLatency = lowLatency
        self.prebufferFrameCount = lowLatency ? 2 : 4
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
                // Authenticate first: the sender withholds the stream
                // header until this token matches its configured one.
                let authFrame = AudioStreamProtocol.encodeFrame(.auth, Data(self.token.utf8))
                connection.send(content: authFrame, completion: .contentProcessed { _ in })
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

        // Any signal that the audio config has shifted (interruption,
        // engine config-change, silence-hint flip) triggers an immediate
        // stream reload via the manager (fresh receiver). Engine-only
        // rebuilds *don't* recover when visionOS reroutes us away for
        // another app's VoIP — only a fresh receiver with a re-asserted
        // setCategory/setActive does (confirmed via the manual reload
        // button). The crucial case is interruption *began*: the app
        // loses its audio session the moment GMeet starts, with no
        // matching route-change or ended event until the call finishes.
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch rawType {
            case AVAudioSession.InterruptionType.began.rawValue:
                AppLog.audioStream.line("Audio session interrupted (began)")
                self?.requestReload("audio session interrupted")
            case AVAudioSession.InterruptionType.ended.rawValue:
                AppLog.audioStream.line("Audio session interruption ended")
                self?.requestReload("interruption ended")
            default:
                break
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            AppLog.audioStream.line("Media services reset — rebuilding engine")
            self?.sessionConfigured = false // session state was wiped
            self?.scheduleAudioRebuild(delay: .milliseconds(100))
        })
        // Diagnostics: visionOS rerouting our output to the People channel
        // when Safari WebRTC kicks in shows up here, not as an interruption.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let session = AVAudioSession.sharedInstance()
            let outs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            AppLog.audioStream.line("Route change (\(reason.map(String.init(describing:)) ?? "?")) → outputs=[\(outs)] silenceHint=\(session.secondaryAudioShouldBeSilencedHint)")
        })
        // visionOS doesn't always notify us via interruption/route-change
        // when Safari WebRTC takes the People channel — sometimes it just
        // flips this hint and silently routes our output to nowhere. On
        // any flip (begin and end), reload the stream.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 0
            let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw)
            AppLog.audioStream.line("Silence-secondary-audio hint: \(type.map(String.init(describing:)) ?? "?")")
            self?.requestReload("silence-secondary-audio hint flipped")
        })
    }

    /// Tears down this receiver and asks the manager to reload the stream
    /// immediately with a fresh receiver (which re-asserts the audio
    /// session). Mirrors `fail(_:)` but routes to the instant reload path
    /// instead of the error/backoff retry path. Safe against bursts: the
    /// first signal wins, the rest hit `stopped` and no-op.
    private nonisolated func requestReload(_ reason: String) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            connection?.cancel()
            connection = nil
            udpListener?.cancel()
            udpListener = nil
            udpConnection?.cancel()
            udpConnection = nil
            for observer in sessionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            sessionObservers.removeAll()
            teardownAudio()
            onEvent?(.reloadRequested(reason))
        }
    }

    nonisolated func stop() {
        queue.async { [self] in
            stopped = true
            onEvent = nil
            connection?.cancel()
            connection = nil
            udpListener?.cancel()
            udpListener = nil
            udpConnection?.cancel()
            udpConnection = nil
            for observer in sessionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            sessionObservers.removeAll()
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
            // Before the header, the only thing the sender may send instead
            // is an authFailed frame (token rejected). The header begins with
            // the magic; an authFailed frame begins with its length prefix —
            // so a non-magic prefix means auth was rejected.
            if pending.count >= AudioStreamProtocol.frameLengthPrefixSize,
               Array(pending.prefix(4)) != AudioStreamProtocol.magic {
                handlePreHeaderFrame()
                return
            }
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
            if lowLatency { openUDP() }
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
            case .command, .auth, .authFailed, .udpHello, nil:
                break // not receiver-bound / unknown — skip
            }
        }
    }

    // MARK: - Low-latency UDP path

    /// Opens a UDP listener on an ephemeral port and advertises it to the
    /// sender via a `udpHello` over TCP. The sender then connects out and
    /// pushes PCM datagrams here. Runs on `queue`. Falls back to TCP if no
    /// PCM arrives within the grace window.
    private nonisolated func openUDP() {
        guard !stopped, udpListener == nil else { return }
        udpFramesReceived = 0
        let listener: NWListener
        do {
            listener = try NWListener(using: NWParameters(dtls: nil, udp: NWProtocolUDP.Options()))
        } catch {
            AppLog.audioStream.line("Low-latency UDP listener failed to open: \(error.localizedDescription) — staying on TCP")
            onEvent?(.lowLatencyUnavailable)
            return
        }
        udpListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let udpPort = listener.port?.rawValue else { return }
                AppLog.audioStream.line("Low-latency UDP listening on port \(udpPort) — advertising to sender")
                var payload = Data(count: 2)
                payload[0] = UInt8(udpPort & 0xff)
                payload[1] = UInt8(udpPort >> 8)
                let hello = AudioStreamProtocol.encodeFrame(.udpHello, payload)
                self.connection?.send(content: hello, completion: .contentProcessed { _ in })
            case .failed(let error):
                AppLog.audioStream.line("Low-latency UDP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // Single sender; a fresh inbound flow displaces any prior.
            self.udpConnection?.cancel()
            self.udpConnection = connection
            connection.start(queue: self.queue)
            self.udpReceiveLoop(connection)
        }
        listener.start(queue: queue)

        // Fallback: if PCM never arrives (one-way UDP block / firewall), drop
        // to plain TCP for this session and surface it loudly.
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped, self.udpFramesReceived == 0 else { return }
            AppLog.audioStream.line("⚠️ No UDP PCM within 2 s — low-latency unavailable, falling back to TCP")
            self.udpListener?.cancel()
            self.udpListener = nil
            self.udpConnection?.cancel()
            self.udpConnection = nil
            self.onEvent?(.lowLatencyUnavailable)
        }
    }

    private nonisolated func udpReceiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                if self.udpFramesReceived == 0 {
                    AppLog.audioStream.line("First low-latency UDP PCM datagram received (\(data.count) bytes)")
                    self.onEvent?(.lowLatencyEngaged)
                }
                self.totalBytes += data.count
                self.processUDPDatagram(data)
            }
            if error == nil { self.udpReceiveLoop(connection) }
        }
    }

    /// One UDP datagram == one `pcm` frame (datagram boundaries preserve
    /// framing). Decoded directly — kept off the TCP `pending` byte-stream
    /// buffer to avoid interleaving a whole datagram into a partial TCP frame.
    private nonisolated func processUDPDatagram(_ data: Data) {
        guard let length = AudioStreamProtocol.decodeFrameLength(data),
              length >= 1, length <= AudioStreamProtocol.maxFrameBytes else { return }
        let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
        guard data.count >= frameEnd else { return }
        let type = data[data.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)]
        guard type == AudioStreamProtocol.FrameType.pcm.rawValue else { return }
        let payload = data.subdata(in: data.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<data.startIndex.advanced(by: frameEnd))
        udpFramesReceived += 1
        schedule(payload)
    }

    /// Parses a frame received before the stream header. The sender only
    /// emits one here: an authFailed frame when the token is rejected.
    /// Waits for the full frame, then surfaces the reason as a terminal
    /// error (retrying with the same token won't help).
    private nonisolated func handlePreHeaderFrame() {
        guard let length = AudioStreamProtocol.decodeFrameLength(pending) else { return }
        guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
            fail("Malformed stream from sender")
            return
        }
        let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
        guard pending.count >= frameEnd else { return } // await the rest

        let type = pending[pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)]
        let payload = pending.subdata(in: pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<pending.startIndex.advanced(by: frameEnd))

        if type == AudioStreamProtocol.FrameType.authFailed.rawValue {
            let reason = String(data: payload, encoding: .utf8) ?? "Authentication failed"
            authFailed(reason)
        } else {
            fail("Unexpected response from sender")
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
        udpListener?.cancel()
        udpListener = nil
        udpConnection?.cancel()
        udpConnection = nil
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        teardownAudio()
        onEvent?(.disconnected(reason))
    }

    /// Like `fail`, but routes to the terminal authFailed event so the
    /// manager surfaces the reason without scheduling a retry.
    private nonisolated func authFailed(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        udpListener?.cancel()
        udpListener = nil
        udpConnection?.cancel()
        udpConnection = nil
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        teardownAudio()
        onEvent?(.authFailed(reason))
    }

    // MARK: - Audio

    private nonisolated func setupAudio(header: AudioStreamHeader) -> Bool {
        let session = AVAudioSession.sharedInstance()

        // Configure the session only once per receiver. Re-asserting the
        // category mid-stream (e.g. while a VoIP call owns the voice
        // channel) yanks the system audio config out from under the other
        // app — the cause of "GMeet loses audio until speaker test".
        if !sessionConfigured {
            sessionConfigured = true
            // Opt out of visionOS's default AutomaticSpatialAudio. The stream is
            // an already-mixed stereo signal from the Mac; spatializing it again
            // would double-process it. AVAudioEngine isn't a Now Playing candidate
            // so the per-app Spatialize Stereo toggle doesn't apply — bypass at
            // the session level instead.
            // .mixWithOthers: coexist with other visionOS apps and VoIP calls
            // instead of taking exclusive audio focus. Deliberate trade-off:
            // a mixable session is ineligible for Now Playing / Control Center.
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setIntendedSpatialExperience(.bypassed)
                // Become a Now Playing candidate so visionOS keeps playback running
                // (and doesn't duck the audio) when the user looks at other windows.
                try session.setIsNowPlayingCandidate(true)
            } catch {
                AppLog.audioStream.line("Failed to configure audio session: \(error)")
            }
        }

        // Activate on every (re)build. After an interruption (e.g. a VoIP
        // call grabbing the People channel) the system deactivates our
        // session — engine.start() alone won't bring it back, so the
        // rebuilt engine reports "running" but pumps audio nowhere.
        // Returning false here engages the rebuild retry/backoff.
        do {
            try session.setActive(true)
        } catch {
            AppLog.audioStream.line("Failed to activate audio session: \(error)")
            return false
        }
        let outs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        AppLog.audioStream.line("Session activated — outputs=[\(outs)] silenceHint=\(session.secondaryAudioShouldBeSilencedHint) otherAudio=\(session.isOtherAudioPlaying)")

        // The wire format is interleaved, but AVAudioEngine throws an
        // NSException ("SetFormat") when connecting a player node to the
        // mixer with an interleaved Float32 format — the engine graph
        // requires the standard (deinterleaved) format. We deinterleave
        // in schedule() instead.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: header.sampleRate,
            channels: AVAudioChannelCount(header.channelCount)
        ) else { return false }

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

        // Engine config change = audio path shifted underneath us (VoIP
        // route, sample-rate switch, device change). Engine-only rebuild
        // doesn't recover when visionOS has rerouted us — reload the
        // whole receiver so the next setupAudio re-asserts the session.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            AppLog.audioStream.line("Audio engine configuration changed")
            self?.requestReload("engine configuration changed")
        }

        return true
    }

    /// Tears down and rebuilds the engine for the current stream format,
    /// retrying with backoff while the system audio config is in flux
    /// (engine starts can fail transiently mid-call-transition).
    private nonisolated func scheduleAudioRebuild(delay: DispatchTimeInterval, attempt: Int = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, let header = self.header else { return }
            self.teardownAudio()
            if self.setupAudio(header: header) {
                AppLog.audioStream.line("Audio engine rebuilt")
            } else if attempt < 5 {
                self.scheduleAudioRebuild(delay: .milliseconds(500 * (attempt + 1)), attempt: attempt + 1)
            } else {
                AppLog.audioStream.line("Audio engine rebuild failed after \(attempt + 1) attempts")
            }
        }
    }

    private nonisolated func teardownAudio() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = nil
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
        if scheduledFrames == prebufferFrameCount {
            playerNode.play()
        }

        // Throttled stats update (~every 0.5 s at 10 ms frames)
        if scheduledFrames % 50 == 0 {
            onEvent?(.bytesReceived(totalBytes))
        }
    }
}
