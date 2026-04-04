import SwiftData
import Foundation
import RoyalVNCKit

// MARK: - Connection Type

enum ConnectionType: String, CaseIterable, Codable {
    case vnc
    case moonlight

    var label: String {
        switch self {
        case .vnc: "VNC"
        case .moonlight: "Moonlight"
        }
    }

    var systemImage: String {
        switch self {
        case .vnc: "display"
        case .moonlight: "gamecontroller"
        }
    }

    var defaultPort: Int {
        switch self {
        case .vnc: 5900
        case .moonlight: 47989
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

enum TouchMode: String, CaseIterable, Codable {
    case relative   // cursor-based, deltas — default for games
    case absolute   // direct screen coordinate mapping — for desktop use

    var label: String {
        switch self {
        case .relative: "Relative (Cursor)"
        case .absolute: "Absolute (Direct)"
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

    var quality: ConnectionQuality {
        get { ConnectionQuality(rawValue: qualityRawValue) ?? .high }
        set { qualityRawValue = newValue.rawValue }
    }

    // MARK: Moonlight-specific

    var moonlightUUID: String?
    var moonlightServerCert: Data?

    // Stream quality
    var moonlightBitrate: Int = 20000  // kbps
    var moonlightFPS: Int = 60
    var moonlightResolutionWidth: Int = 1920
    var moonlightResolutionHeight: Int = 1080
    var moonlightVideoCodecRawValue: String = VideoCodecPreference.auto.rawValue
    var moonlightEnableHDR: Bool = false
    var moonlightUseFramePacing: Bool = false

    // Audio
    var moonlightAudioConfigRawValue: String = AudioConfiguration.stereo.rawValue
    var moonlightPlayAudioOnPC: Bool = false

    // Input
    var moonlightTouchModeRawValue: String = TouchMode.relative.rawValue
    var moonlightMultiController: Bool = true
    var moonlightSwapABXY: Bool = false

    // Server
    var moonlightOptimizeGameSettings: Bool = true

    // Debug
    var moonlightShowStatsOverlay: Bool = false

    // MARK: Moonlight computed properties

    var moonlightVideoCodec: VideoCodecPreference {
        get { VideoCodecPreference(rawValue: moonlightVideoCodecRawValue) ?? .auto }
        set { moonlightVideoCodecRawValue = newValue.rawValue }
    }

    var moonlightAudioConfig: AudioConfiguration {
        get { AudioConfiguration(rawValue: moonlightAudioConfigRawValue) ?? .stereo }
        set { moonlightAudioConfigRawValue = newValue.rawValue }
    }

    var moonlightTouchMode: TouchMode {
        get { TouchMode(rawValue: moonlightTouchModeRawValue) ?? .relative }
        set { moonlightTouchModeRawValue = newValue.rawValue }
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
}
