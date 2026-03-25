import SwiftUI
import SwiftData

struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager

    var savedConnection: SavedConnection?

    @State private var hostname: String = ""
    @State private var port: String = "5900"
    @State private var password: String = ""
    @State private var label: String = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Hostname or IP Address", text: $hostname)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }

            Section("Authentication") {
                SecureField("Password (optional)", text: $password)
            }

            Section("Label") {
                TextField("Display Name (optional)", text: $label)
            }

            Section {
                Button(action: connectToServer) {
                    HStack {
                        Spacer()
                        Label("Connect", systemImage: "display")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(savedConnection == nil ? "New Connection" : "Edit Connection")
        .onAppear {
            if let saved = savedConnection {
                hostname = saved.hostname
                port = String(saved.port)
                label = saved.label
            }
        }
    }

    private func connectToServer() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let portNum = UInt16(port) ?? 5900

        // Save or update the connection
        if let saved = savedConnection {
            saved.hostname = trimmedHost
            saved.port = Int(portNum)
            saved.label = label
            saved.lastConnected = Date()
        } else {
            let newConnection = SavedConnection(
                hostname: trimmedHost,
                port: Int(portNum),
                label: label
            )
            newConnection.lastConnected = Date()
            modelContext.insert(newConnection)
        }

        // Initiate the VNC connection
        connectionManager.connect(
            hostname: trimmedHost,
            port: portNum,
            password: password.isEmpty ? nil : password
        )

        // Open the remote desktop window
        openWindow(id: "remote-desktop")
        dismiss()
    }
}
