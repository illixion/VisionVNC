import SwiftUI

/// Tracks which of the app's windows are currently open and whether each is
/// in the user's current room, so the Sessions tab can "summon" a window back
/// to the user. On visionOS a window can be snapped in another room and become
/// unreachable until you physically return there; calling `openWindow(id:)` on
/// an already-open window brings it to the user's current position — the same
/// mechanic SpatialStash uses.
@Observable
@MainActor
final class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()

    /// Open window ids → `true` when the window is in the user's current room
    /// (its scene phase is `.active`), `false` when snapped in another room.
    private(set) var sessions: [String: Bool] = [:]

    private init() {}

    /// Window ids the user can summon, in display order. Excludes "main"
    /// (the Sessions list itself lives there) and any window not open.
    var summonableIDs: [String] {
        WindowSessionRegistry.catalog
            .map(\.id)
            .filter { sessions[$0] != nil }
    }

    func register(_ id: String) {
        sessions[id] = true
    }

    func unregister(_ id: String) {
        sessions[id] = nil
    }

    func setActiveRoom(_ id: String, _ active: Bool) {
        guard sessions[id] != nil else { return }
        sessions[id] = active
    }

    func isInActiveRoom(_ id: String) -> Bool {
        sessions[id] ?? true
    }

    // MARK: - Display catalog

    /// Static description of each summonable window: id, label, and SF Symbol.
    /// Subtitles (connection names) are resolved live by the Sessions view.
    struct WindowKind: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    static let catalog: [WindowKind] = {
        var kinds: [WindowKind] = [
            WindowKind(id: "remote-desktop", title: "Remote Desktop", systemImage: "display"),
        ]
        #if MOONLIGHT_ENABLED
        kinds.append(WindowKind(id: "moonlight-stream", title: "Game Stream", systemImage: "gamecontroller"))
        #endif
        kinds.append(WindowKind(id: "audio-stream", title: "Audio Stream", systemImage: "hifispeaker"))
        kinds.append(WindowKind(id: "keyboard", title: "Keyboard", systemImage: "keyboard"))
        #if MOONLIGHT_ENABLED
        kinds.append(WindowKind(id: "moonlight-keyboard", title: "Game Keyboard", systemImage: "keyboard"))
        #endif
        kinds.append(WindowKind(id: "console", title: "Console", systemImage: "terminal"))
        return kinds
    }()

    static func kind(for id: String) -> WindowKind? {
        catalog.first { $0.id == id }
    }
}

/// Registers a window with `WindowSessionRegistry` for its lifetime and keeps
/// its room status (scene phase) up to date. Apply to each window's root view.
private struct TrackWindowSession: ViewModifier {
    let id: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                WindowSessionRegistry.shared.register(id)
            }
            .onDisappear {
                WindowSessionRegistry.shared.unregister(id)
            }
            .onChange(of: scenePhase) { _, phase in
                WindowSessionRegistry.shared.setActiveRoom(id, phase == .active)
            }
    }
}

extension View {
    /// Tracks this window in `WindowSessionRegistry` so it can be summoned
    /// from the Sessions tab.
    func trackWindowSession(id: String) -> some View {
        modifier(TrackWindowSession(id: id))
    }
}
