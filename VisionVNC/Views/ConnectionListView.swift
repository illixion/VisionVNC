import SwiftUI
import SwiftData

struct ConnectionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(VNCConnectionManager.self) private var connectionManager

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var savedConnections: [SavedConnection]

    @State private var showingNewConnection = false

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
                            NavigationLink(value: connection) {
                                connectionRow(connection)
                            }
                        }
                        .onDelete(perform: deleteConnections)
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
            .navigationDestination(for: SavedConnection.self) { connection in
                ConnectionFormView(savedConnection: connection)
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
        }
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
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
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(savedConnections[index])
        }
    }
}
