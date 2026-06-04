import Foundation
import Network

/// TCP server that streams interleaved Float32 PCM to the connected
/// VisionVNC client. Sends the AudioStreamHeader on accept, then
/// length-prefixed frames (see AudioStreamProtocol).
///
/// Only one client may be connected at a time (security measure):
/// a new connection displaces any existing one (newest wins), which also
/// lets the Vision Pro reconnect past a stale half-open socket. A slow
/// client that falls more than `maxPendingBytes` behind has frames
/// dropped (latency cap) rather than queueing unbounded.
final class AudioStreamServer: @unchecked Sendable {

    /// ~0.5 s of 48 kHz stereo Float32 — beyond this a client is lagging
    /// badly and queueing more would only grow its latency.
    private static let maxPendingBytes = 200_000

    nonisolated(unsafe) var onClientCountChange: (@Sendable (Int) -> Void)?

    private final class Client {
        let connection: NWConnection
        var pendingBytes = 0
        var headerSent = false
        init(connection: NWConnection) { self.connection = connection }
    }

    private let port: UInt16
    private let header: AudioStreamHeader
    private let queue = DispatchQueue(label: "com.illixion.VisionVNCAudioSender.server", qos: .userInteractive)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var clients: [ObjectIdentifier: Client] = [:]

    nonisolated init(port: UInt16, header: AudioStreamHeader) {
        self.port = port
        self.header = header
    }

    nonisolated func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let listener = try NWListener(
            using: NWParameters(tls: nil, tcp: tcp),
            on: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    nonisolated func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.connection.cancel()
            }
            clients.removeAll()
            notifyClientCount()
        }
    }

    /// Called from the Core Audio realtime thread — hops to the server
    /// queue immediately, keeping the audio callback non-blocking.
    nonisolated func broadcast(_ pcm: Data) {
        queue.async { [self] in
            guard !clients.isEmpty else { return }
            let frame = AudioStreamProtocol.encodeFrame(pcm)
            for client in clients.values where client.headerSent {
                // Latency cap: drop frames for clients that can't keep up
                guard client.pendingBytes < Self.maxPendingBytes else { continue }
                client.pendingBytes += frame.count
                client.connection.send(content: frame, completion: .contentProcessed { [weak self, weak client] _ in
                    self?.queue.async { client?.pendingBytes -= frame.count }
                })
            }
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private nonisolated func accept(_ connection: NWConnection) {
        // Newest wins: displace any existing client so only one is ever
        // connected. Cancelling fires their .cancelled handlers, but the
        // dict is already cleared so remove() is a no-op for them.
        for old in clients.values {
            old.connection.cancel()
        }
        clients.removeAll()

        let client = Client(connection: connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                client.connection.send(content: self.header.encoded(), completion: .contentProcessed { _ in })
                client.headerSent = true
                self.notifyClientCount()
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }

        // Receive loop solely to detect remote close (clients never send)
        receiveToDetectClose(connection)
        connection.start(queue: queue)
    }

    private nonisolated func receiveToDetectClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.remove(connection)
            } else {
                self?.receiveToDetectClose(connection)
            }
        }
    }

    private nonisolated func remove(_ connection: NWConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
        notifyClientCount()
    }

    private nonisolated func notifyClientCount() {
        let count = clients.values.filter(\.headerSent).count
        onClientCountChange?(count)
    }
}
