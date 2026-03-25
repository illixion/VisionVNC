import SwiftUI
import SwiftData

@main
struct VisionVNCApp: App {
    @State private var connectionManager = VNCConnectionManager()

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environment(connectionManager)
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Remote Desktop", id: "remote-desktop") {
            RemoteDesktopView()
                .environment(connectionManager)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
    }
}
