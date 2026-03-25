import SwiftUI
import RoyalVNCKit

struct CredentialPromptView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var username: String = ""
    @State private var password: String = ""

    private var requiresUsername: Bool {
        connectionManager.credentialAuthType.requiresUsername
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("The server requires authentication.") {
                    if requiresUsername {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
            }
            .navigationTitle("Authentication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        connectionManager.cancelCredential()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        connectionManager.submitCredential(
                            username: requiresUsername ? username : nil,
                            password: password
                        )
                        dismiss()
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}
