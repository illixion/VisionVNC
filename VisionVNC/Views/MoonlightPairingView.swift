import SwiftUI

/// Displays pairing status and PIN for Moonlight server pairing.
struct MoonlightPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MoonlightConnectionManager.self) private var manager

    let connection: SavedConnection

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch manager.connectionState {
                case .connecting, .fetchingServerInfo:
                    connectingView

                case .needsPairing(let pin):
                    pinView(pin: pin)

                case .pairing(let pin):
                    pairingInProgressView(pin: pin)

                case .paired, .fetchingApps:
                    fetchingAppsView

                case .ready:
                    appListView

                case .error(let message):
                    errorView(message: message)

                default:
                    ProgressView()
                }
            }
            .padding(32)
            .navigationTitle(connection.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        manager.disconnect()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - State Views

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(manager.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func pinView(pin: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Enter this PIN on your server")
                .font(.headline)

            Text(pin)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

            Text("Open your Sunshine web interface and enter this PIN when prompted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                manager.beginPairing(pin: pin, connection: connection)
            } label: {
                Label("Start Pairing", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func pairingInProgressView(pin: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)

            Text("Pairing in progress...")
                .font(.headline)

            Text("PIN: \(pin)")
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Waiting for server to accept the PIN...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var fetchingAppsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Paired!")
                .font(.headline)

            ProgressView("Fetching apps...")
        }
    }

    private var appListView: some View {
        VStack(spacing: 16) {
            if manager.apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Found",
                    systemImage: "app.dashed",
                    description: Text("No applications are available on the server.")
                )
            } else {
                Text("Available Apps")
                    .font(.headline)

                List(manager.apps) { app in
                    Button {
                        // TODO: Sprint 3 — launch streaming session
                    } label: {
                        HStack {
                            Image(systemName: app.isAppCollectorGame ? "folder" : "gamecontroller")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Text(app.name)
                                .font(.body)

                            Spacer()

                            if app.hdrSupported {
                                Text("HDR")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.yellow.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 400)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                manager.retry(connection: connection)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
