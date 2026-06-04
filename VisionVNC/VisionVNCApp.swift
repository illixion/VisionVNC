import SwiftUI
import SwiftData

@main
struct VisionVNCApp: App {
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightManager = MoonlightConnectionManager()
    #endif

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environment(connectionManager)
                .environment(audioManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightManager)
                #endif
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Audio Stream", id: "audio-stream") {
            AudioStreamView()
                .environment(audioManager)
        }
        .defaultSize(width: 420, height: 360)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Remote Desktop", id: "remote-desktop") {
            RemoteDesktopView()
                .environment(connectionManager)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Stream", id: "moonlight-stream") {
            MoonlightStreamView()
                .environment(moonlightManager)
        }
        .defaultSize(width: 1920, height: 1080)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif

        WindowGroup("Keyboard", id: "keyboard") {
            KeyboardInputView()
                .environment(connectionManager)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard") {
            MoonlightKeyboardView()
                .environment(moonlightManager)
        }
        .defaultSize(width: 500, height: 450)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}
