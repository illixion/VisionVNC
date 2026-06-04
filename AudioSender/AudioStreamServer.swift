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
    /// Media transport command received from the client (fires on `queue`).
    nonisolated(unsafe) var onCommand: (@Sendable (MediaCommand) -> Void)?

    private final class Client {
        let connection: NWConnection
        var pendingBytes = 0
        var headerSent = false
        /// Buffer for inbound command frames from the client.
        var inbound = Data()
        init(connection: NWConnection) { self.connection = connection }
    }

    private let port: UInt16
    private let header: AudioStreamHeader
    private let queue = DispatchQueue(label: "com.illixion.VisionVNCAudioSender.server", qos: .userInteractive)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var clients: [ObjectIdentifier: Client] = [:]

    /// Latest pre-encoded metadata frames, replayed to newly connected
    /// clients right after the header. Mutated only on `queue`.
    private nonisolated(unsafe) var currentNowPlayingFrame: Data?
    private nonisolated(unsafe) var currentArtworkFrame: Data?

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

    /// Publishes new now-playing metadata. Pre-encoded frames are stored
    /// for replay-on-connect and sent to the connected client immediately.
    /// Metadata frames bypass the PCM latency cap — they're rare and must
    /// not be dropped. Pass a nil artwork frame when artwork is unchanged;
    /// pass nil info to clear (e.g. Music quit).
    nonisolated func updateMetadata(infoFrame: Data?, artworkFrame: Data?) {
        queue.async { [self] in
            if let artworkFrame {
                currentArtworkFrame = artworkFrame
            } else if infoFrame == nil {
                currentArtworkFrame = nil
            }
            currentNowPlayingFrame = infoFrame
            for client in clients.values where client.headerSent {
                if let artworkFrame {
                    client.connection.send(content: artworkFrame, completion: .contentProcessed { _ in })
                }
                if let infoFrame {
                    client.connection.send(content: infoFrame, completion: .contentProcessed { _ in })
                }
            }
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
                // Replay current now-playing state (artwork first so the
                // receiver can pair it with the info's artworkID).
                if let artwork = self.currentArtworkFrame {
                    client.connection.send(content: artwork, completion: .contentProcessed { _ in })
                }
                if let info = self.currentNowPlayingFrame {
                    client.connection.send(content: info, completion: .contentProcessed { _ in })
                }
                self.notifyClientCount()
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }

        // Receive loop: parses inbound command frames and detects remote close
        receiveLoop(client)
        connection.start(queue: queue)
    }

    private nonisolated func receiveLoop(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.inbound.append(data)
                self.processInbound(client)
            }
            if isComplete || error != nil {
                self.remove(client.connection)
            } else {
                self.receiveLoop(client)
            }
        }
    }

    /// Parses typed frames from the client. Only `command` frames are
    /// meaningful; unknown types are skipped. Runs on `queue`.
    private nonisolated func processInbound(_ client: Client) {
        while let length = AudioStreamProtocol.decodeFrameLength(client.inbound) {
            guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
                // Malformed stream — drop the client
                remove(client.connection)
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard client.inbound.count >= frameEnd else { return }

            let start = client.inbound.startIndex
            let type = client.inbound[start + AudioStreamProtocol.frameLengthPrefixSize]
            let payload = client.inbound.subdata(
                in: start.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<start.advanced(by: frameEnd)
            )
            client.inbound.removeFirst(frameEnd)

            if type == AudioStreamProtocol.FrameType.command.rawValue,
               let message = MediaCommandMessage.decode(payload) {
                onCommand?(message.command)
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
