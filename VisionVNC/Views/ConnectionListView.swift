import SwiftUI
import SwiftData

struct ConnectionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var savedConnections: [SavedConnection]

    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?

    var body: some View {
        NavigationStack {
            Group {
                if savedConnections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "display",
                        description: Text("Add a VNC connection to get started.")
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
                                Button("Done") {
                                    connectionToEdit = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text("\(connection.hostname):\(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Image(systemName: "pencil.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func connectTo(_ connection: SavedConnection) {
        connection.lastConnected = Date()

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
            password: password
        )

        openWindow(id: "remote-desktop")
    }
}
