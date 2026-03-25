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
    @State private var label: String = ""
    @State private var quality: ConnectionQuality = .high
    @State private var autoLogin: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""

    private var hasCredentials: Bool {
        !password.isEmpty
    }

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
                Toggle("Auto Login", isOn: $autoLogin)

                if autoLogin {
                    TextField("Username (optional)", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    if savedConnection != nil && hasCredentials {
                        Button("Clear Saved Credentials", role: .destructive) {
                            username = ""
                            password = ""
                        }
                    }
                }
            }

            Section("Quality") {
                Picker("Quality", selection: $quality) {
                    ForEach(ConnectionQuality.allCases, id: \.self) { q in
                        Text(q.label).tag(q)
                    }
                }
                .pickerStyle(.segmented)

                Text(quality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Label") {
                TextField("Display Name (optional)", text: $label)
            }

            Section {
                Button(action: saveConnection) {
                    HStack {
                        Spacer()
                        Label("Save", systemImage: "checkmark.circle")
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
                quality = saved.quality
                autoLogin = saved.autoLogin
                username = saved.savedUsername
                password = saved.savedPassword
            }
        }
    }

    private func saveConnection() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let portNum = Int(port) ?? 5900

        if let saved = savedConnection {
            saved.hostname = trimmedHost
            saved.port = portNum
            saved.label = label.isEmpty ? "\(trimmedHost):\(portNum)" : label
            saved.quality = quality
            saved.autoLogin = autoLogin
            saved.savedUsername = autoLogin ? username : ""
            saved.savedPassword = autoLogin ? password : ""
        } else {
            let newConnection = SavedConnection(
                hostname: trimmedHost,
                port: portNum,
                label: label,
                quality: quality
            )
            newConnection.autoLogin = autoLogin
            newConnection.savedUsername = autoLogin ? username : ""
            newConnection.savedPassword = autoLogin ? password : ""
            modelContext.insert(newConnection)
        }

        dismiss()
    }
}
