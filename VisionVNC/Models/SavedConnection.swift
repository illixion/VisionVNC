import SwiftData
import Foundation
import RoyalVNCKit

// MARK: - Connection Type

enum ConnectionType: String, CaseIterable, Codable {
    case vnc
    case ssh
    #if MOONLIGHT_ENABLED
    case moonlight
    #endif
    case audio

    var label: String {
        switch self {
        case .vnc: "VNC"
        case .ssh: "SSH"
        #if MOONLIGHT_ENABLED
        case .moonlight: "Moonlight"
        #endif
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .vnc: "display"
        case .ssh: "terminal"
        #if MOONLIGHT_ENABLED
        case .moonlight: "gamecontroller"
        #endif
        case .audio: "speaker.wave.2"
        }
    }

    var defaultPort: Int {
        switch self {
        case .vnc: 5900
        case .ssh: 22
        #if MOONLIGHT_ENABLED
        case .moonlight: 47989
        #endif
        case .audio: Int(AudioStreamProtocol.defaultPort)
        }
    }
}

// MARK: - VNC Quality

/// Quality presets mapping to VNC color depth, JPEG quality, and compression level.
/// Note: 8-bit depth uses palettized color map mode which most modern
/// VNC servers (including macOS Screen Sharing) don't support, so the
/// lowest usable depth is 16-bit.
enum ConnectionQuality: Int, CaseIterable, Codable {
    case trackpadOnly = 0  // No video, transparent overlay for input only
    case low = 1           // 16-bit, aggressive JPEG compression
    case medium = 16       // 16-bit, balanced (was "low" before low tier existed)
    case high = 24         // 24-bit, full color

    var label: String {
        switch self {
        case .trackpadOnly: "Trackpad Only"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .trackpadOnly: "Transparent input overlay. Position over Mac Virtual Display for mouse and keyboard control."
        case .low: "16-bit, aggressive JPEG compression — lowest bandwidth"
        case .medium: "16-bit, balanced compression"
        case .high: "24-bit, full color — best quality"
        }
    }

    var vncColorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
        case .trackpadOnly, .low, .medium: .depth16Bit
        case .high: .depth24Bit
        }
    }

    /// JPEG quality level for Tight encoding (0 = lowest, 9 = highest)
    var jpegQualityLevel: Int {
        switch self {
        case .trackpadOnly, .low: 2
        case .medium: 6
        case .high: 8
        }
    }

    /// Compression level (1 = lowest/fastest, 10 = highest/slowest)
    var compressionLevel: Int {
        switch self {
        case .trackpadOnly, .low: 9
        case .medium: 6
        case .high: 3
        }
    }
}

#if MOONLIGHT_ENABLED
// MARK: - Moonlight Enums

enum VideoCodecPreference: String, CaseIterable, Codable {
    case auto       // let server/client negotiate best option
    case h264
    case hevc
    case av1        // native AV1 OBU parsing via VideoToolbox

    var label: String {
        switch self {
        case .auto: "Auto"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        }
    }
}

enum AudioConfiguration: String, CaseIterable, Codable {
    case stereo     // 2ch
    case surround51 // 6ch
    case surround71 // 8ch
    case none       // no audio

    var label: String {
        switch self {
        case .stereo: "Stereo"
        case .surround51: "5.1 Surround"
        case .surround71: "7.1 Surround"
        case .none: "No Audio"
        }
    }

    var channelCount: Int {
        switch self {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        case .none: 0
        }
    }
}
#endif

// MARK: - Touch Mode

enum TouchMode: String, CaseIterable, Codable {
    case relative   // cursor-based, deltas — trackpad style
    case absolute   // direct screen coordinate mapping — tap where you want

    var label: String {
        switch self {
        case .relative: "Touchpad (Relative)"
        case .absolute: "Direct Touch (Absolute)"
        }
    }
}

// MARK: - Saved Connection Model

@Model
final class SavedConnection {
    var id: UUID
    var hostname: String
    var port: Int
    var label: String
    var lastConnected: Date?

    // Connection type discrimination
    var connectionTypeRawValue: String = ConnectionType.vnc.rawValue

    var connectionType: ConnectionType {
        get { ConnectionType(rawValue: connectionTypeRawValue) ?? .vnc }
        set { connectionTypeRawValue = newValue.rawValue }
    }

    // MARK: VNC-specific

    // Keep the original column name so lightweight migration works with existing stores
    @Attribute(originalName: "colorDepth")
    var qualityRawValue: Int = 24

    var autoLogin: Bool = false
    var savedUsername: String = ""
    var savedPassword: String = ""
    var vncTouchModeRawValue: String = TouchMode.relative.rawValue

    // MARK: Audio-specific

    /// Static auth token presented to the VisionVNC Audio Sender. Default
    /// empty so lightweight migration of existing stores is safe.
    var audioToken: String = ""

    /// Opt-in low-latency mode: carries PCM over UDP with a smaller jitter
    /// buffer (DTLS-encrypted) instead of TCP. Needs a clean LAN path. Default
    /// false so lightweight migration is safe and behavior is unchanged.
    var lowLatencyAudio: Bool = false

    /// On a VNC connection, the `id` of a saved **companion** (audio) connection
    /// to pair with the VNC session — it provides both the companion audio
    /// stream and, on the same host/token, the text-injection channel for the
    /// keyboard bypass. Lets the desktop run over an encrypted tunnel (e.g.
    /// Tailscale) while the companion runs on a different LAN host — the
    /// implicit same-hostname match can't express that. nil → fall back to the
    /// hostname match (or no companion). Renamed from `linkedAudioConnectionID`;
    /// `originalName` keeps lightweight migration of existing stores working.
    @Attribute(originalName: "linkedAudioConnectionID")
    var linkedCompanionConnectionID: UUID?

    // MARK: SSH-specific

    /// Username for SSH login. Auth is key-based — the device's Secure Enclave
    /// key is the credential. Default empty so lightweight migration is safe.
    var sshUsername: String = ""

    /// Remote command to run under the PTY. Empty → an interactive login shell
    /// (generic terminal). The Projects tab overrides this per launch to run
    /// `claude` in a chosen folder via tmux.
    var sshLaunchCommand: String = ""

    /// Managed-session client command (Projects tab). Empty → `claude`. Lets
    /// the same tmux-backed workflow drive a different CLI. Default empty so
    /// lightweight migration is safe.
    var sshClientCommand: String = ""

    /// Extra non-secret environment variables to inject over the (encrypted)
    /// SSH channel, `KEY=VALUE` one per line. Each name must be listed in the
    /// Mac's sshd `AcceptEnv`. The Claude auth token is handled separately
    /// (stored in the Keychain, not here). Default empty for safe migration.
    var sshEnvVars: String = ""

    /// Env var name the stored auth token is injected as. Empty →
    /// `CLAUDE_CODE_OAUTH_TOKEN` (Claude Code's headless credential — it's read
    /// before the macOS Keychain, which is unreachable in an SSH session).
    var sshAuthEnvName: String = ""

    /// Whether an auth token is stored in the Keychain for this connection.
    /// The token *value* lives in `KeychainStore` (keyed by `id`), never in
    /// SwiftData; this is only a UI flag. Default false for safe migration.
    var sshHasAuthToken: Bool = false

    var quality: ConnectionQuality {
        get { ConnectionQuality(rawValue: qualityRawValue) ?? .high }
        set { qualityRawValue = newValue.rawValue }
    }

    var vncTouchMode: TouchMode {
        get { TouchMode(rawValue: vncTouchModeRawValue) ?? .relative }
        set { vncTouchModeRawValue = newValue.rawValue }
    }

    // MARK: SSH helpers

    private static let sshAuthTokenService = "com.illixion.VisionVNC.sshAuthToken"

    /// Client command for managed (Projects-tab) sessions — `claude` by default.
    var effectiveSSHClientCommand: String {
        sshClientCommand.isEmpty ? "claude" : sshClientCommand
    }

    /// Env var name the auth token is injected as.
    var effectiveSSHAuthEnvName: String {
        sshAuthEnvName.isEmpty ? "CLAUDE_CODE_OAUTH_TOKEN" : sshAuthEnvName
    }

    /// The per-connection auth token, stored in the Keychain (not SwiftData).
    /// Setting it also updates the `sshHasAuthToken` flag; an empty/nil value
    /// clears the stored secret.
    var sshAuthToken: String? {
        get { KeychainStore.get(service: Self.sshAuthTokenService, account: id.uuidString) }
        set {
            let v = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(service: Self.sshAuthTokenService, account: id.uuidString, value: v)
            sshHasAuthToken = !v.isEmpty
        }
    }

    /// Non-secret environment from the `sshEnvVars` lines (validated names).
    /// Used for generic terminal sessions; the auth token is **not** included
    /// here (it's a managed-Claude credential — see `resolvedSSHEnvironment`).
    func sshEnvironmentVariables() -> [(name: String, value: String)] {
        var env: [(name: String, value: String)] = []
        for raw in sshEnvVars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard Self.isValidEnvName(name) else { continue }
            let value = String(line[line.index(after: eq)...])
            env.removeAll { $0.name == name }
            env.append((name: name, value: value))
        }
        return env
    }

    /// Full environment for a managed (Claude) session: the non-secret vars
    /// plus the stored auth token under its env name (token wins on conflict).
    func resolvedSSHEnvironment() -> [(name: String, value: String)] {
        var env = sshEnvironmentVariables()
        if sshHasAuthToken, let token = sshAuthToken, !token.isEmpty {
            let name = effectiveSSHAuthEnvName
            guard Self.isValidEnvName(name) else { return env }
            env.removeAll { $0.name == name }
            env.append((name: name, value: token))
        }
        return env
    }

    /// POSIX environment-variable name (`[A-Za-z_][A-Za-z0-9_]*`). Guards the
    /// shell `NAME=value` assignment built in `SSHTerminalManager`.
    static func isValidEnvName(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.dropFirst().allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: Moonlight stored properties
    // IMPORTANT: All @Model stored properties MUST be outside #if blocks.
    // The @Model macro doesn't properly register properties inside #if,
    // causing "unknown key" crashes even on fresh install.
    // All use Optional so NULL is valid (lightweight migration safe).

    @Attribute(originalName: "moonlightBitrate")
    var moonlightBitrateStorage: Int?
    @Attribute(originalName: "moonlightFPS")
    var moonlightFPSStorage: Int?
    @Attribute(originalName: "moonlightResolutionWidth")
    var moonlightResolutionWidthStorage: Int?
    @Attribute(originalName: "moonlightResolutionHeight")
    var moonlightResolutionHeightStorage: Int?
    @Attribute(originalName: "moonlightVideoCodecRawValue")
    var moonlightVideoCodecRawValueStorage: String?
    @Attribute(originalName: "moonlightEnableHDR")
    var moonlightEnableHDRStorage: Bool?
    @Attribute(originalName: "moonlightUseFramePacing")
    var moonlightUseFramePacingStorage: Bool?
    @Attribute(originalName: "moonlightAudioConfigRawValue")
    var moonlightAudioConfigRawValueStorage: String?
    @Attribute(originalName: "moonlightPlayAudioOnPC")
    var moonlightPlayAudioOnPCStorage: Bool?
    @Attribute(originalName: "moonlightTouchModeRawValue")
    var moonlightTouchModeRawValueStorage: String?
    @Attribute(originalName: "moonlightMultiController")
    var moonlightMultiControllerStorage: Bool?
    @Attribute(originalName: "moonlightSwapABXY")
    var moonlightSwapABXYStorage: Bool?
    @Attribute(originalName: "moonlightOptimizeGameSettings")
    var moonlightOptimizeGameSettingsStorage: Bool?
    @Attribute(originalName: "moonlightShowStatsOverlay")
    var moonlightShowStatsOverlayStorage: Bool?

    #if MOONLIGHT_ENABLED
    // MARK: Moonlight computed properties (not persisted — safe inside #if)

    // Server identity (stored in UserDefaults, not SwiftData)
    var moonlightServerCert: Data? {
        get { UserDefaults.standard.data(forKey: "ml_cert_\(id.uuidString)") }
        set { UserDefaults.standard.set(newValue, forKey: "ml_cert_\(id.uuidString)") }
    }

    var moonlightUUID: String? {
        get { UserDefaults.standard.string(forKey: "ml_uuid_\(id.uuidString)") }
        set { UserDefaults.standard.set(newValue, forKey: "ml_uuid_\(id.uuidString)") }
    }

    // Nil-coalescing wrappers with defaults
    var moonlightBitrate: Int {
        get { moonlightBitrateStorage ?? 20000 }
        set { moonlightBitrateStorage = newValue }
    }

    var moonlightFPS: Int {
        get { moonlightFPSStorage ?? 60 }
        set { moonlightFPSStorage = newValue }
    }

    var moonlightResolutionWidth: Int {
        get { moonlightResolutionWidthStorage ?? 1920 }
        set { moonlightResolutionWidthStorage = newValue }
    }

    var moonlightResolutionHeight: Int {
        get { moonlightResolutionHeightStorage ?? 1080 }
        set { moonlightResolutionHeightStorage = newValue }
    }

    var moonlightVideoCodecRawValue: String {
        get { moonlightVideoCodecRawValueStorage ?? VideoCodecPreference.auto.rawValue }
        set { moonlightVideoCodecRawValueStorage = newValue }
    }
    var moonlightEnableHDR: Bool {
        get { moonlightEnableHDRStorage ?? false }
        set { moonlightEnableHDRStorage = newValue }
    }
    var moonlightUseFramePacing: Bool {
        get { moonlightUseFramePacingStorage ?? false }
        set { moonlightUseFramePacingStorage = newValue }
    }
    var moonlightPlayAudioOnPC: Bool {
        get { moonlightPlayAudioOnPCStorage ?? false }
        set { moonlightPlayAudioOnPCStorage = newValue }
    }
    var moonlightMultiController: Bool {
        get { moonlightMultiControllerStorage ?? true }
        set { moonlightMultiControllerStorage = newValue }
    }
    var moonlightSwapABXY: Bool {
        get { moonlightSwapABXYStorage ?? false }
        set { moonlightSwapABXYStorage = newValue }
    }
    var moonlightOptimizeGameSettings: Bool {
        get { moonlightOptimizeGameSettingsStorage ?? true }
        set { moonlightOptimizeGameSettingsStorage = newValue }
    }
    var moonlightShowStatsOverlay: Bool {
        get { moonlightShowStatsOverlayStorage ?? false }
        set { moonlightShowStatsOverlayStorage = newValue }
    }

    var moonlightVideoCodec: VideoCodecPreference {
        get { VideoCodecPreference(rawValue: moonlightVideoCodecRawValue) ?? .auto }
        set { moonlightVideoCodecRawValue = newValue.rawValue }
    }

    var moonlightAudioConfig: AudioConfiguration {
        get { AudioConfiguration(rawValue: moonlightAudioConfigRawValueStorage ?? AudioConfiguration.stereo.rawValue) ?? .stereo }
        set { moonlightAudioConfigRawValueStorage = newValue.rawValue }
    }

    var moonlightTouchMode: TouchMode {
        get { TouchMode(rawValue: moonlightTouchModeRawValueStorage ?? TouchMode.relative.rawValue) ?? .relative }
        set { moonlightTouchModeRawValueStorage = newValue.rawValue }
    }

    var moonlightResolutionLabel: String {
        let w = moonlightResolutionWidth
        let h = moonlightResolutionHeight
        switch (w, h) {
        case (1280, 720): return "720p"
        case (1920, 1080): return "1080p"
        case (2560, 1440): return "1440p"
        case (3840, 2160): return "4K"
        default: return "\(w)×\(h)"
        }
    }
    #endif

    // MARK: Init

    init(hostname: String, port: Int = 5900, label: String = "", quality: ConnectionQuality = .high, connectionType: ConnectionType = .vnc) {
        self.id = UUID()
        self.hostname = hostname
        self.port = port
        self.label = label.isEmpty ? "\(hostname):\(port)" : label
        self.qualityRawValue = quality.rawValue
        self.lastConnected = nil
        self.autoLogin = false
        self.savedUsername = ""
        self.savedPassword = ""
        self.connectionTypeRawValue = connectionType.rawValue
    }

    var displayName: String {
        label.isEmpty ? "\(hostname):\(port)" : label
    }

    #if MOONLIGHT_ENABLED
    // MARK: Bitrate Helpers

    /// Suggested bitrate (kbps) based on resolution and FPS
    static func suggestedBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = width * height
        let base: Int
        switch pixels {
        case ..<921_600:   base = 5000    // 720p -> 5 Mbps
        case ..<2_073_600: base = 10000   // 1080p -> 10 Mbps
        case ..<3_686_400: base = 20000   // 1440p -> 20 Mbps
        default:           base = 40000   // 4K -> 40 Mbps
        }
        return fps > 60 ? base * 2 : (fps > 30 ? base : base / 2)
    }

    /// Recalculates bitrate based on current resolution and FPS settings
    func recalculateBitrate() {
        moonlightBitrate = Self.suggestedBitrate(
            width: moonlightResolutionWidth,
            height: moonlightResolutionHeight,
            fps: moonlightFPS
        )
    }
    #endif
}
