import SwiftUI
import SwiftData

struct ConnectionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager
    #if MOONLIGHT_ENABLED
    @Environment(MoonlightConnectionManager.self) private var moonlightManager
    #endif

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var savedConnections: [SavedConnection]

    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?
    #if MOONLIGHT_ENABLED
    @State private var moonlightConnection: SavedConnection?
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if savedConnections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "display",
                        description: Text(emptyStateDescription)
                    )
                } else {
                    List {
                        ForEach(savedConnections) { connection in
                            Button {
                                connectTo(connection)
                            } label: {
                                connectionRow(connection)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    modelContext.delete(connection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    connectionToEdit = connection
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("VisionVNC")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Connection", systemImage: "plus") {
                        showingNewConnection = true
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    NavigationLink {
                        ThirdPartyNoticesView()
                    } label: {
                        Label("Third-Party Notices", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
            }
            .sheet(isPresented: $showingNewConnection) {
                NavigationStack {
                    ConnectionFormView(savedConnection: nil)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    showingNewConnection = false
                                }
                            }
                        }
                }
            }
            .sheet(item: $connectionToEdit) { connection in
                NavigationStack {
                    ConnectionFormView(savedConnection: connection)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    connectionToEdit = nil
                                }
                            }
                        }
                }
            }
            #if MOONLIGHT_ENABLED
            .sheet(item: $moonlightConnection) { connection in
                MoonlightPairingView(connection: connection)
                    .environment(moonlightManager)
            }
            #endif
        }
    }

    private var emptyStateDescription: String {
        #if MOONLIGHT_ENABLED
        "Add a VNC or Moonlight connection to get started."
        #else
        "Add a VNC connection to get started."
        #endif
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
        HStack {
            Image(systemName: connection.connectionType.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)

                HStack(spacing: 4) {
                    Text(connection.connectionType.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(connection.hostname):\(connection.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if MOONLIGHT_ENABLED
                if connection.connectionType == .moonlight {
                    Text("\(connection.moonlightResolutionLabel) · \(connection.moonlightFPS) FPS")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                #endif

                if let date = connection.lastConnected {
                    Text("Last connected: \(date, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)

            Spacer()

            Button {
                connectionToEdit = connection
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func connectTo(_ connection: SavedConnection) {
        connection.lastConnected = Date()

        switch connection.connectionType {
        case .vnc:
            connectVNC(connection)
        #if MOONLIGHT_ENABLED
        case .moonlight:
            connectMoonlight(connection)
        #endif
        }
    }

    private func connectVNC(_ connection: SavedConnection) {
        var username: String?
        var password: String?

        if connection.autoLogin {
            if !connection.savedUsername.isEmpty {
                username = connection.savedUsername
            }
            if !connection.savedPassword.isEmpty {
                password = connection.savedPassword
            }
        }

        connectionManager.connect(
            hostname: connection.hostname,
            port: UInt16(connection.port),
            username: username,
            password: password,
            colorDepth: connection.quality.vncColorDepth,
            jpegQualityLevel: connection.quality.jpegQualityLevel,
            compressionLevel: connection.quality.compressionLevel,
            touchMode: connection.vncTouchMode,
            trackpadOnly: connection.quality == .trackpadOnly,
            title: connection.displayName
        )

        openWindow(id: "remote-desktop")
    }

    #if MOONLIGHT_ENABLED
    private func connectMoonlight(_ connection: SavedConnection) {
        moonlightManager.connect(to: connection)
        moonlightConnection = connection
    }
    #endif
}
