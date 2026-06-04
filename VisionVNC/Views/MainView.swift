import SwiftUI

/// Root of the main window: Connections / Settings / Console tabs,
/// switched by a bottom ornament tab bar (matches the app's ornament idiom;
/// each tab keeps its own NavigationStack for visionOS navigation titles).
struct MainView: View {

    enum Tab: String, CaseIterable {
        case connections = "Connections"
        case settings = "Settings"
        case console = "Console"

        var systemImage: String {
            switch self {
            case .connections: "rectangle.connected.to.line.below"
            case .settings: "gear"
            case .console: "terminal"
            }
        }
    }

    @State private var selectedTab: Tab = .connections

    var body: some View {
        Group {
            switch selectedTab {
            case .connections:
                ConnectionListView()
            case .settings:
                SettingsView()
            case .console:
                ConsoleView()
            }
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
