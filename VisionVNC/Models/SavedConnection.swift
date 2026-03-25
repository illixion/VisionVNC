import SwiftData
import Foundation

@Model
final class SavedConnection {
    var id: UUID
    var hostname: String
    var port: Int
    var label: String
    var lastConnected: Date?
    var colorDepth: Int

    init(hostname: String, port: Int = 5900, label: String = "", colorDepth: Int = 24) {
        self.id = UUID()
        self.hostname = hostname
        self.port = port
        self.label = label.isEmpty ? "\(hostname):\(port)" : label
        self.colorDepth = colorDepth
        self.lastConnected = nil
    }

    var displayName: String {
        label.isEmpty ? "\(hostname):\(port)" : label
    }
}
