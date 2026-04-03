import Foundation
import SwiftUI
@preconcurrency import MoonlightCommonC

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

    /// Video renderer — exposed so MoonlightStreamView can access the display layer.
    var videoRenderer: MoonlightVideoRenderer?
    private var audioRenderer: MoonlightAudioRenderer?
    private var isStreamActive = false

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
                let audioConfig: Int32
                switch connection.moonlightAudioConfig {
                case .stereo: audioConfig = 0x302CA       // stereo
                case .surround51: audioConfig = 0x3F06CA  // 5.1
                case .surround71: audioConfig = 0x63F08CA // 7.1
                }

                let surroundInfo = surroundAudioInfo(from: audioConfig)

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
                        width: connection.moonlightResolutionWidth,
                        height: connection.moonlightResolutionHeight,
                        fps: connection.moonlightFPS,
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
                        width: connection.moonlightResolutionWidth,
                        height: connection.moonlightResolutionHeight,
                        fps: connection.moonlightFPS,
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

                await MainActor.run {
                    self.videoRenderer = video
                    self.audioRenderer = audio
                    self.isStreamActive = true
                }

                // Build stream config
                let streamConfig = MoonlightStreamConfig(
                    width: Int32(connection.moonlightResolutionWidth),
                    height: Int32(connection.moonlightResolutionHeight),
                    fps: Int32(connection.moonlightFPS),
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
        videoRenderer = nil
        audioRenderer = nil
        isStreamActive = false
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
