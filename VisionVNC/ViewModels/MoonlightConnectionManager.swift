import Foundation
import SwiftUI

/// Orchestrates the Moonlight connection lifecycle:
/// server info → pairing → app list → stream launch.
@Observable
class MoonlightConnectionManager {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case fetchingServerInfo
        case needsPairing(pin: String)
        case pairing(pin: String)
        case paired
        case fetchingApps
        case ready
        case streaming
        case error(String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.connecting, .connecting),
                 (.fetchingServerInfo, .fetchingServerInfo),
                 (.paired, .paired), (.fetchingApps, .fetchingApps),
                 (.ready, .ready), (.streaming, .streaming):
                return true
            case (.needsPairing(let a), .needsPairing(let b)):
                return a == b
            case (.pairing(let a), .pairing(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var connectionState: ConnectionState = .idle
    var serverInfo: ServerInfo?
    var apps: [MoonlightApp] = []
    var statusMessage: String = ""

    private var httpClient: NvHTTPClient?
    private let cryptoManager = CryptoManager.shared
    private let pairingManager = NvPairingManager()

    // MARK: - Connection Flow

    /// Begin connecting to a Moonlight/Sunshine server.
    func connect(to connection: SavedConnection) {
        guard connectionState == .idle || isErrorState else { return }

        connectionState = .connecting
        statusMessage = "Connecting to \(connection.hostname)..."
        apps = []
        serverInfo = nil

        let hostname = connection.hostname
        let port = UInt16(connection.port)
        let savedServerCert = connection.moonlightServerCert

        Task {
            do {
                let client = NvHTTPClient(hostname: hostname, httpPort: port)
                httpClient = client

                // If we have a saved server cert, configure HTTPS
                if let certDER = savedServerCert {
                    try await client.setServerCert(certDER)
                }

                // Fetch server info
                connectionState = .fetchingServerInfo
                statusMessage = "Fetching server info..."
                let info = try await client.getServerInfo()
                serverInfo = info

                if info.httpsPort != 47984 {
                    await client.updateHttpsPort(info.httpsPort)
                }

                if info.pairStatus {
                    // Already paired — configure HTTPS if not already done
                    if savedServerCert == nil, let uuid = serverInfo?.uuid, !uuid.isEmpty {
                        // Paired but we don't have the cert stored — need to re-pair
                        startPairing()
                        return
                    }

                    connectionState = .paired
                    statusMessage = "Paired with \(info.hostname)"
                    await fetchApps()
                } else {
                    // Need to pair
                    startPairing()
                }
            } catch {
                connectionState = .error(error.localizedDescription)
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Initiate pairing — generates PIN and waits for user action.
    private func startPairing() {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        connectionState = .needsPairing(pin: pin)
        statusMessage = "Enter PIN on your server"
    }

    /// Begin the pairing handshake after user has seen the PIN.
    func beginPairing(pin: String, connection: SavedConnection) {
        guard case .needsPairing = connectionState else { return }
        connectionState = .pairing(pin: pin)
        statusMessage = "Pairing... Enter PIN \(pin) on your server"

        Task {
            do {
                guard let client = httpClient, let info = serverInfo else {
                    connectionState = .error("No server connection")
                    return
                }

                let result = try await pairingManager.pair(with: client, pin: pin, serverInfo: info)

                switch result {
                case .success(let serverCertDER):
                    // Store server cert on the connection
                    connection.moonlightServerCert = serverCertDER
                    connection.moonlightUUID = info.uuid

                    connectionState = .paired
                    statusMessage = "Paired successfully!"
                    await fetchApps()

                case .pinRejected:
                    connectionState = .error("Incorrect PIN. Please try again.")
                    statusMessage = "PIN rejected"

                case .alreadyInProgress:
                    connectionState = .error("Server is already in a pairing session. Cancel the existing pairing on the server and try again.")
                    statusMessage = "Already pairing"

                case .failed(let message):
                    connectionState = .error("Pairing failed: \(message)")
                    statusMessage = "Pairing failed"
                }
            } catch {
                connectionState = .error("Pairing error: \(error.localizedDescription)")
                statusMessage = "Pairing error"
            }
        }
    }

    /// Fetch the app list from the server.
    private func fetchApps() async {
        connectionState = .fetchingApps
        statusMessage = "Fetching apps..."

        do {
            guard let client = httpClient else { return }
            let appList = try await client.getAppList()
            apps = appList.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            connectionState = .ready
            statusMessage = "\(appList.count) app(s) available"
        } catch {
            connectionState = .error("Failed to fetch apps: \(error.localizedDescription)")
            statusMessage = "Failed to fetch apps"
        }
    }

    /// Disconnect and reset state.
    func disconnect() {
        httpClient = nil
        connectionState = .idle
        serverInfo = nil
        apps = []
        statusMessage = ""
    }

    /// Retry connection after an error.
    func retry(connection: SavedConnection) {
        disconnect()
        connect(to: connection)
    }

    private var isErrorState: Bool {
        if case .error = connectionState { return true }
        return false
    }
}
