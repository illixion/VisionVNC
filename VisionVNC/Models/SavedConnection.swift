import SwiftData
import Foundation
import RoyalVNCKit

// MARK: - Connection Type

enum ConnectionType: String, CaseIterable, Codable {
    case vnc
    #if MOONLIGHT_ENABLED
    case moonlight
    #endif

    var label: String {
        switch self {
        case .vnc: "VNC"
        #if MOONLIGHT_ENABLED
        case .moonlight: "Moonlight"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .vnc: "display"
        #if MOONLIGHT_ENABLED
        case .moonlight: "gamecontroller"
        #endif
        }
    }

    var defaultPort: Int {
        switch self {
        case .vnc: 5900
        #if MOONLIGHT_ENABLED
        case .moonlight: 47989
        #endif
        }
    }
}

// MARK: - VNC Quality

/// Quality presets mapping to VNC color depth.
/// Note: 8-bit depth uses palettized color map mode which most modern
/// VNC servers (including macOS Screen Sharing) don't support, so the
/// lowest usable depth is 16-bit.
enum ConnectionQuality: Int, CaseIterable, Codable {
    case low = 16      // 65K colors
    case high = 24     // 16.7M colors (full color)

    var label: String {
        switch self {
        case .low: "Low"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low: "16-bit, 65K colors — lower bandwidth"
        case .high: "24-bit, full color"
        }
    }

    var vncColorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
        case .low: .depth16Bit
        case .high: .depth24Bit
        }
    }
}

#if MOONLIGHT_ENABLED
// MARK: - Moonlight Enums

enum VideoCodecPreference: String, CaseIterable, Codable {
    case auto       // let server/client negotiate best option
    case h264
    case hevc
    case av1        // future — requires FFmpeg for bitstream parsing

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
    var vncTouchModeRawValue: String = TouchMode.absolute.rawValue

    var quality: ConnectionQuality {
        get { ConnectionQuality(rawValue: qualityRawValue) ?? .high }
        set { qualityRawValue = newValue.rawValue }
    }

    var vncTouchMode: TouchMode {
        get { TouchMode(rawValue: vncTouchModeRawValue) ?? .absolute }
        set { vncTouchModeRawValue = newValue.rawValue }
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
