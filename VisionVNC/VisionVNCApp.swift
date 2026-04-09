import SwiftUI
import SwiftData

@main
struct VisionVNCApp: App {
    @State private var connectionManager = VNCConnectionManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightManager = MoonlightConnectionManager()
    #endif

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environment(connectionManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightManager)
                #endif
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Remote Desktop", id: "remote-desktop") {
            RemoteDesktopView()
                .environment(connectionManager)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Stream", id: "moonlight-stream") {
            MoonlightStreamView()
                .environment(moonlightManager)
        }
        .defaultSize(width: 1920, height: 1080)
        .windowResizability(.contentMinSize)
        #endif

        WindowGroup("Keyboard", id: "keyboard") {
            KeyboardInputView()
                .environment(connectionManager)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard") {
            MoonlightKeyboardView()
                .environment(moonlightManager)
        }
        .defaultSize(width: 500, height: 450)
        .windowResizability(.contentSize)
        #endif
    }
}
