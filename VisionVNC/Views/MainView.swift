import SwiftUI

/// Root of the main window: Connections / Settings / Console tabs,
/// switched by a bottom ornament tab bar (matches the app's ornament idiom;
/// each tab keeps its own NavigationStack for visionOS navigation titles).
struct MainView: View {

    enum Tab: String, CaseIterable {
        case connections = "Connections"
        case sessions = "Sessions"
        case console = "Console"
        case settings = "Settings"

        var systemImage: String {
            switch self {
            case .connections: "rectangle.connected.to.line.below"
            case .sessions: "macwindow.on.rectangle"
            case .settings: "gear"
            case .console: "terminal"
            }
        }
    }

    @Environment(AudioStreamManager.self) private var audioManager
    @State private var selectedTab: Tab = .connections

    var body: some View {
        Group {
            switch selectedTab {
            case .connections:
                ConnectionListView()
            case .sessions:
                SessionsView()
            case .settings:
                SettingsView()
            case .console:
                ConsoleView()
            }
        }
        .onOpenURL { url in
            // An AirDropped visionvnc://…/setAudioToken URL: stash the token
            // and surface the Connections tab so the form can auto-fill it.
            guard let token = AudioTokenURL.parseToken(from: url) else { return }
            selectedTab = .connections
            audioManager.importToken(token)
        }
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    .background(
                        selectedTab == tab ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                        in: .capsule
                    )
                }
            }
            .padding(8)
            .glassBackgroundEffect()
        }
    }
}
