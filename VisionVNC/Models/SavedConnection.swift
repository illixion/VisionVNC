import SwiftData
import Foundation
import RoyalVNCKit

/// Quality presets mapping to VNC color depth
enum ConnectionQuality: Int, CaseIterable, Codable {
    case low = 8       // 256 colors
    case medium = 16   // 65K colors
    case high = 24     // 16.7M colors (full color)

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low: "8-bit, 256 colors"
        case .medium: "16-bit, 65K colors"
        case .high: "24-bit, full color"
        }
    }

    var vncColorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
        case .low: .depth8Bit
        case .medium: .depth16Bit
        case .high: .depth24Bit
        }
    }
}

@Model
final class SavedConnection {
    var id: UUID
    var hostname: String
    var port: Int
    var label: String
    var lastConnected: Date?

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

    init(hostname: String, port: Int = 5900, label: String = "", quality: ConnectionQuality = .high) {
        self.id = UUID()
        self.hostname = hostname
        self.port = port
        self.label = label.isEmpty ? "\(hostname):\(port)" : label
        self.qualityRawValue = quality.rawValue
        self.lastConnected = nil
        self.autoLogin = false
        self.savedUsername = ""
        self.savedPassword = ""
    }

    var displayName: String {
        label.isEmpty ? "\(hostname):\(port)" : label
    }
}
