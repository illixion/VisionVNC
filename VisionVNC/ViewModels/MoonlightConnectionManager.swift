#if MOONLIGHT_ENABLED
import Foundation
import SwiftUI
import QuartzCore
@preconcurrency import MoonlightCommonC

/// NSObject proxy for CADisplayLink target (since MoonlightConnectionManager doesn't extend NSObject).
private class DisplayLinkProxy: NSObject {
    var handler: (() -> Void)?
    @objc func displayLinkFired() {
        handler?()
    }
}

/// Live streaming statistics displayed in the stats overlay.
struct StreamStats {
    var videoCodec: String = ""
    var resolution: String = ""
    var configuredFPS: Int = 0
    var actualFPS: Double = 0
    var networkRttMs: UInt32 = 0
    var rttVarianceMs: UInt32 = 0
    var decodeTimeMs: Double = 0
    var totalFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
}

/// Orchestrates the Moonlight connection lifecycle:
/// server info → pairing → app list → stream launch.
@Observable
class MoonlightConnectionManager: MoonlightStreamDelegate {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case fetchingServerInfo
        case pairing(pin: String)
        case paired
        case fetchingApps
        case ready
        case launching
        case streaming
        case error(String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.connecting, .connecting),
                 (.fetchingServerInfo, .fetchingServerInfo),
                 (.paired, .paired), (.fetchingApps, .fetchingApps),
                 (.ready, .ready), (.launching, .launching),
                 (.streaming, .streaming):
                return true
            case (.pairing(let a), .pairing(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var connectionState: ConnectionState = .idle
    var serverInfo: ServerInfo?
    var apps: [MoonlightApp] = []
    var statusMessage: String = ""
    /// Touch mode for the active connection (relative trackpad vs absolute positioning).
    var touchMode: TouchMode = .relative
    /// Stream resolution for coordinate mapping in absolute mode.
    var streamWidth: Int = 1920
    var streamHeight: Int = 1080
    /// Selected display index for multi-display servers.
    var selectedDisplayIndex: Int = 0

    /// Video renderer — exposed so MoonlightStreamView can check streaming state.
    var videoRenderer: MoonlightVideoRenderer?
    /// Latest decoded video frame for SwiftUI display.
    var streamFrameImage: CGImage?
    /// Live streaming statistics.
    var streamStats = StreamStats()

    private var audioRenderer: MoonlightAudioRenderer?
    private var gamepadManager: MoonlightGamepadManager?
    private var isStreamActive = false

    // FPS tracking
    private var fpsFrameCount: UInt64 = 0
    private var fpsLastSampleTime: CFTimeInterval = 0

    /// Display link proxy and timer for throttled frame updates.
    private var displayLinkProxy: DisplayLinkProxy?
    private var streamDisplayLink: CADisplayLink?

    private var httpClient: NvHTTPClient?
    private var activeConnection: SavedConnection?
    private let cryptoManager = CryptoManager.shared
    private let pairingManager = NvPairingManager()

    // MARK: - Connection Flow

    /// Begin connecting to a Moonlight/Sunshine server.
    func connect(to connection: SavedConnection) {
        guard connectionState == .idle || isErrorState else { return }

        connectionState = .connecting
        statusMessage = "Connecting to \(connection.hostname)..."
        apps = []
        serverInfo = nil
        activeConnection = connection

        let hostname = connection.hostname
        let port = UInt16(connection.port)
        let savedServerCert = connection.moonlightServerCert

        Task {
            do {
                let client = NvHTTPClient(hostname: hostname, httpPort: port)
                httpClient = client

                // If we have a saved server cert, configure HTTPS
                if let certDER = savedServerCert {
                    try await client.setServerCert(certDER)
                }

                // Fetch server info
                connectionState = .fetchingServerInfo
                statusMessage = "Fetching server info..."
                let info = try await client.getServerInfo()
                serverInfo = info

                if info.httpsPort != 47984 {
                    await client.updateHttpsPort(info.httpsPort)
                }

                if info.pairStatus {
                    // Already paired — configure HTTPS if not already done
                    if savedServerCert == nil, let uuid = serverInfo?.uuid, !uuid.isEmpty {
                        // Paired but we don't have the cert stored — need to re-pair
                        startPairing(connection: connection)
                        return
                    }

                    connectionState = .paired
                    statusMessage = "Paired with \(info.hostname)"
                    await fetchApps()
                } else {
                    // Need to pair
                    startPairing(connection: connection)
                }
            } catch {
                connectionState = .error(error.localizedDescription)
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Initiate pairing — generates PIN and immediately starts the handshake.
    /// The first pair request blocks on the server until the user enters the PIN,
    /// so we fire it immediately and display the PIN while waiting.
    private func startPairing(connection: SavedConnection) {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        connectionState = .pairing(pin: pin)
        statusMessage = "Enter PIN \(pin) on your server"

        Task {
            do {
                guard let client = httpClient, let info = serverInfo else {
                    connectionState = .error("No server connection")
                    return
                }

                let result = try await pairingManager.pair(with: client, pin: pin, serverInfo: info)

                switch result {
                case .success(let serverCertDER):
                    // Store server cert on the connection
                    connection.moonlightServerCert = serverCertDER
                    connection.moonlightUUID = info.uuid

                    connectionState = .paired
                    statusMessage = "Paired successfully!"
                    await fetchApps()

                case .pinRejected:
                    connectionState = .error("Incorrect PIN. Please try again.")
                    statusMessage = "PIN rejected"

                case .alreadyInProgress:
                    connectionState = .error("Server is already in a pairing session. Cancel the existing pairing on the server and try again.")
                    statusMessage = "Already pairing"

                case .failed(let message):
                    connectionState = .error("Pairing failed: \(message)")
                    statusMessage = "Pairing failed"
                }
            } catch {
                connectionState = .error("Pairing error: \(error.localizedDescription)")
                statusMessage = "Pairing error"
            }
        }
    }

    /// Fetch the app list from the server.
    private func fetchApps() async {
        connectionState = .fetchingApps
        statusMessage = "Fetching apps..."

        do {
            guard let client = httpClient else { return }
            let appList = try await client.getAppList()
            apps = appList.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            connectionState = .ready
            statusMessage = "\(appList.count) app(s) available"
        } catch {
            connectionState = .error("Failed to fetch apps: \(error.localizedDescription)")
            statusMessage = "Failed to fetch apps"
        }
    }

    // MARK: - App Launch

    /// Launch or resume a streaming session for the given app.
    func launchApp(_ app: MoonlightApp) {
        guard let connection = activeConnection,
              let client = httpClient,
              let info = serverInfo else { return }

        // Override resolution/fps from selected display mode if available
        let displayOverride: DisplayMode?
        if selectedDisplayIndex > 0,
           selectedDisplayIndex < info.displayModes.count {
            displayOverride = info.displayModes[selectedDisplayIndex]
        } else {
            displayOverride = nil
        }

        connectionState = .launching
        statusMessage = "Launching \(app.name)..."

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                // Generate AES key and key ID for remote input encryption
                let riKey = self.generateRandomBytes(16)
                let riKeyId = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))

                // Determine video format based on server support and connection settings
                let videoFormats = self.resolveVideoFormats(
                    serverCodecModeSupport: Int32(info.serverCodecModeSupport),
                    preference: connection.moonlightVideoCodec
                )

                // Determine audio configuration
                // Values: ((channelMask) << 16) | (channelCount << 8) | 0xCA
                let noAudio = connection.moonlightAudioConfig == .none
                let audioConfig: Int32
                switch connection.moonlightAudioConfig {
                case .surround51: audioConfig = 0x3F06CA  // 5.1
                case .surround71: audioConfig = 0x63F08CA // 7.1
                default: audioConfig = 0x302CA            // stereo (also used for .none — audio stream still negotiated)
                }

                let surroundInfo = surroundAudioInfo(from: audioConfig)

                // Use display mode override if selected, otherwise connection settings
                let effectiveWidth = displayOverride?.width ?? connection.moonlightResolutionWidth
                let effectiveHeight = displayOverride?.height ?? connection.moonlightResolutionHeight
                let effectiveFPS = displayOverride?.refreshRate ?? connection.moonlightFPS

                // Launch or resume the app via HTTP
                let sessionUrl: String
                if info.currentGameId == app.id {
                    // App already running — resume
                    sessionUrl = try await client.resumeApp(
                        riKey: riKey, riKeyId: riKeyId,
                        surroundAudioInfo: surroundInfo
                    )
                } else if info.currentGameId != 0 {
                    // Different app running — quit it first, then launch
                    try await client.quitApp()
                    sessionUrl = try await client.launchApp(
                        appId: app.id,
                        width: effectiveWidth,
                        height: effectiveHeight,
                        fps: effectiveFPS,
                        bitrate: connection.moonlightBitrate,
                        riKey: riKey, riKeyId: riKeyId,
                        localAudioPlayMode: connection.moonlightPlayAudioOnPC,
                        surroundAudioInfo: surroundInfo,
                        supportedVideoFormats: Int(videoFormats),
                        optimizeGameSettings: connection.moonlightOptimizeGameSettings
                    )
                } else {
                    sessionUrl = try await client.launchApp(
                        appId: app.id,
                        width: effectiveWidth,
                        height: effectiveHeight,
                        fps: effectiveFPS,
                        bitrate: connection.moonlightBitrate,
                        riKey: riKey, riKeyId: riKeyId,
                        localAudioPlayMode: connection.moonlightPlayAudioOnPC,
                        surroundAudioInfo: surroundInfo,
                        supportedVideoFormats: Int(videoFormats),
                        optimizeGameSettings: connection.moonlightOptimizeGameSettings
                    )
                }

                // Create renderers
                let video = MoonlightVideoRenderer()
                let audio = MoonlightAudioRenderer()
                audio.muted = noAudio

                // Determine codec name for stats display
                let codecName: String
                if videoFormats & VIDEO_FORMAT_H265 != 0 {
                    codecName = "HEVC"
                } else if videoFormats & Int32(VIDEO_FORMAT_AV1_MAIN8) != 0 {
                    codecName = "AV1"
                } else {
                    codecName = "H.264"
                }

                await MainActor.run {
                    self.videoRenderer = video
                    self.audioRenderer = audio
                    self.isStreamActive = true
                    self.touchMode = connection.moonlightTouchMode
                    self.streamWidth = effectiveWidth
                    self.streamHeight = effectiveHeight
                    self.streamStats = StreamStats(
                        videoCodec: codecName,
                        resolution: "\(effectiveWidth)x\(effectiveHeight)",
                        configuredFPS: effectiveFPS
                    )
                }

                // Build stream config
                let streamConfig = MoonlightStreamConfig(
                    width: Int32(effectiveWidth),
                    height: Int32(effectiveHeight),
                    fps: Int32(effectiveFPS),
                    bitrate: Int32(connection.moonlightBitrate),
                    audioConfiguration: audioConfig,
                    supportedVideoFormats: videoFormats,
                    serverAddress: connection.hostname,
                    serverAppVersion: info.appVersion,
                    serverGfeVersion: info.gfeVersion,
                    rtspSessionUrl: sessionUrl,
                    serverCodecModeSupport: Int32(info.serverCodecModeSupport),
                    riKey: riKey,
                    riKeyId: riKeyId
                )

                // Start connection (blocks until connected or fails)
                let result = startMoonlightStream(
                    config: streamConfig,
                    videoRenderer: video,
                    audioRenderer: audio,
                    delegate: self
                )

                if result != 0 {
                    await MainActor.run {
                        self.connectionState = .error("Failed to start stream (error: \(result))")
                        self.statusMessage = "Stream failed"
                        self.cleanupStream()
                    }
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .error("Launch failed: \(error.localizedDescription)")
                    self.statusMessage = "Launch failed"
                }
            }
        }
    }

    /// Stop the active streaming session.
    func stopStreaming() {
        guard isStreamActive else { return }
        Task.detached {
            stopMoonlightStream()
            await MainActor.run {
                self.cleanupStream()
                self.connectionState = .ready
                self.statusMessage = "Disconnected from stream"
            }
        }
    }

    private func cleanupStream() {
        stopDisplayLink()
        gamepadManager?.stopListening()
        gamepadManager = nil
        activeGamepadManager = nil
        videoRenderer = nil
        audioRenderer = nil
        isStreamActive = false
        streamFrameImage = nil
        // Reset FPS tracking so the next session doesn't underflow
        fpsFrameCount = 0
        fpsLastSampleTime = 0
    }

    private func startGamepadManager() {
        let swapABXY = activeConnection?.moonlightSwapABXY ?? false
        let manager = MoonlightGamepadManager(swapABXY: swapABXY)
        gamepadManager = manager
        activeGamepadManager = manager
        manager.startListening()
    }

    private func startDisplayLink() {
        let proxy = DisplayLinkProxy()
        proxy.handler = { [weak self] in
            self?.updateStreamFrame()
        }
        displayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        streamDisplayLink = link
    }

    private func stopDisplayLink() {
        streamDisplayLink?.invalidate()
        streamDisplayLink = nil
        displayLinkProxy = nil
    }

    private nonisolated(unsafe) var displayLinkLogCount = 0
    private func updateStreamFrame() {
        guard let renderer = videoRenderer else {
            if displayLinkLogCount < 3 {
                print("[MoonlightStream] Display link: no videoRenderer")
                displayLinkLogCount += 1
            }
            return
        }
        let frame = renderer.latestFrame
        if displayLinkLogCount < 5 {
            print("[MoonlightStream] Display link tick: latestFrame=\(frame != nil ? "yes" : "nil")")
            displayLinkLogCount += 1
        }
        if let frame = frame, frame !== streamFrameImage {
            streamFrameImage = frame
        }

        // Update stats periodically
        updateStats(renderer: renderer)
    }

    private func updateStats(renderer: MoonlightVideoRenderer) {
        let now = CACurrentMediaTime()

        // Compute actual FPS every second
        let currentFrameCount = renderer.frameCount
        if fpsLastSampleTime == 0 {
            fpsLastSampleTime = now
            fpsFrameCount = currentFrameCount
        } else {
            let elapsed = now - fpsLastSampleTime
            if elapsed >= 1.0 {
                // Use Int64 to avoid unsigned underflow if frame counter was reset
                let frames = Int64(currentFrameCount) - Int64(fpsFrameCount)
                streamStats.actualFPS = frames > 0 ? Double(frames) / elapsed : 0
                fpsLastSampleTime = now
                fpsFrameCount = currentFrameCount
            }
        }

        // Update decode time and frame counts
        streamStats.decodeTimeMs = renderer.lastDecodeTimeMs
        streamStats.totalFrames = currentFrameCount
        streamStats.droppedFrames = renderer.droppedFrames

        // Update network RTT
        var rtt: UInt32 = 0
        var rttVariance: UInt32 = 0
        if LiGetEstimatedRttInfo(&rtt, &rttVariance) {
            streamStats.networkRttMs = rtt
            streamStats.rttVarianceMs = rttVariance
        }
    }

    // MARK: - MoonlightStreamDelegate

    nonisolated func moonlightStreamStageStarting(_ stage: Int32) {
        let name = String(cString: LiGetStageName(stage))
        Task { @MainActor in
            self.statusMessage = "Starting \(name)..."
        }
    }

    nonisolated func moonlightStreamStageComplete(_ stage: Int32) {}

    nonisolated func moonlightStreamStageFailed(_ stage: Int32, errorCode: Int32) {
        let name = String(cString: LiGetStageName(stage))
        Task { @MainActor in
            self.connectionState = .error("Stage '\(name)' failed (error: \(errorCode))")
            self.statusMessage = "Stream setup failed"
            self.cleanupStream()
        }
    }

    nonisolated func moonlightStreamConnectionStarted() {
        Task { @MainActor in
            self.connectionState = .streaming
            self.statusMessage = "Streaming"
            self.startDisplayLink()
            self.startGamepadManager()
        }
    }

    nonisolated func moonlightStreamConnectionTerminated(_ errorCode: Int32) {
        Task { @MainActor in
            self.cleanupStream()
            if errorCode == 0 {
                self.connectionState = .ready
                self.statusMessage = "Stream ended"
            } else {
                self.connectionState = .error("Stream terminated (error: \(errorCode))")
                self.statusMessage = "Stream lost"
            }
        }
    }

    nonisolated func moonlightStreamConnectionStatusUpdate(_ status: Int32) {
        // Could update UI with connection quality indicators
    }

    // MARK: - Helpers

    private nonisolated func generateRandomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Determine supported video formats based on server capabilities and user preference.
    private nonisolated func resolveVideoFormats(serverCodecModeSupport: Int32, preference: VideoCodecPreference) -> Int32 {
        switch preference {
        case .h264:
            return VIDEO_FORMAT_H264
        case .hevc:
            if serverCodecModeSupport & Int32(SCM_HEVC) != 0 {
                return VIDEO_FORMAT_H265
            }
            return VIDEO_FORMAT_H264
        case .av1:
            if serverCodecModeSupport & Int32(SCM_AV1_MAIN8) != 0 {
                return Int32(VIDEO_FORMAT_AV1_MAIN8)
            }
            return VIDEO_FORMAT_H264
        case .auto:
            // Prefer HEVC if available, fall back to H.264
            if serverCodecModeSupport & Int32(SCM_HEVC) != 0 {
                return VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265
            }
            return VIDEO_FORMAT_H264
        }
    }

    /// Quit the currently running app on the server (ends the session).
    func quitServerSession() {
        guard let client = httpClient else { return }
        Task {
            do {
                try await client.quitApp()
                // Refresh server info to update currentGameId
                if let info = try? await client.getServerInfo() {
                    serverInfo = info
                }
                statusMessage = "Session ended on server"
            } catch {
                statusMessage = "Failed to quit: \(error.localizedDescription)"
            }
        }
    }

    /// Stop the local stream AND quit the app on the server.
    func stopStreamingAndQuit() {
        guard isStreamActive else { return }
        let client = httpClient
        Task.detached {
            stopMoonlightStream()
            // End the session on the server
            try? await client?.quitApp()
            await MainActor.run {
                self.cleanupStream()
                self.connectionState = .ready
                self.statusMessage = "Session ended"
            }
        }
    }

    /// Disconnect and reset state.
    func disconnect() {
        if isStreamActive {
            stopStreaming()
        }
        httpClient = nil
        activeConnection = nil
        connectionState = .idle
        serverInfo = nil
        apps = []
        statusMessage = ""
    }

    /// Retry connection after an error.
    func retry(connection: SavedConnection) {
        disconnect()
        connect(to: connection)
    }

    private var isErrorState: Bool {
        if case .error = connectionState { return true }
        return false
    }
}
#endif
