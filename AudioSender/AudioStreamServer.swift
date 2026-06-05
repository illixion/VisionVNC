import Foundation
import Network
import os

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
        /// Set once the client has presented the correct token. The header
        /// and all stream/metadata frames are withheld until then.
        var authenticated = false
        /// Buffer for inbound frames (auth, then commands) from the client.
        var inbound = Data()
        /// Low-latency UDP return path, established once the client sends a
        /// valid `udpHello` datagram. When set, PCM is sent here instead of
        /// over `connection` (TCP). nil → PCM rides TCP as before.
        var udp: NWConnection?
        init(connection: NWConnection) { self.connection = connection }
    }

    private let port: UInt16
    private let token: String
    private let header: AudioStreamHeader
    private let queue = DispatchQueue(label: "com.illixion.VisionVNCAudioSender.server", qos: .userInteractive)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var clients: [ObjectIdentifier: Client] = [:]

    private let log = Logger(subsystem: "com.illixion.VisionVNCAudioSender", category: "AudioStreamServer")

    /// Latest pre-encoded metadata frames, replayed to newly connected
    /// clients right after the header. Mutated only on `queue`.
    private nonisolated(unsafe) var currentNowPlayingFrame: Data?
    private nonisolated(unsafe) var currentArtworkFrame: Data?

    nonisolated init(port: UInt16, token: String, header: AudioStreamHeader) {
        self.port = port
        self.token = token
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
                client.udp?.cancel()
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
                if let udp = client.udp {
                    // Low-latency path: one PCM frame per datagram, no
                    // backpressure accounting — the OS drops if it can't keep
                    // up, which is the desired latency-over-reliability trade.
                    udp.send(content: frame, completion: .contentProcessed { _ in })
                    continue
                }
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
                // Withhold the header until the client authenticates — the
                // receive loop calls authenticate(_:) on the auth frame.
                break
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

    /// Opens the outbound low-latency UDP path to a client that advertised a
    /// listener port via a `udpHello` frame (over TCP). The receiver's IP is
    /// taken from its TCP connection; PCM then flows to (that IP, `udpPort`).
    /// Runs on `queue`.
    private nonisolated func attachUDP(_ client: Client, udpPort: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: udpPort) else {
            log.error("udpHello: invalid UDP port \(udpPort)")
            return
        }
        guard let host = remoteHost(of: client.connection) else {
            log.error("udpHello: could not resolve client IP from TCP connection")
            return
        }
        let udp = NWConnection(host: host, port: port, using: NWParameters(dtls: nil, udp: NWProtocolUDP.Options()))
        client.udp?.cancel()
        client.udp = udp
        udp.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("Low-latency UDP attached → \(String(describing: host)):\(udpPort)")
            case .failed(let error):
                self?.log.error("UDP path failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    /// Extracts the peer IP host from a connection's remote endpoint.
    private nonisolated func remoteHost(of connection: NWConnection) -> NWEndpoint.Host? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case let .hostPort(host, _) = endpoint { return host }
        return nil
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

    /// Parses typed frames from the client. The first frame must be a valid
    /// `auth` frame; until authenticated, any other frame (or a bad token)
    /// drops the connection. Afterwards only `command` frames are
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

            guard client.authenticated else {
                // First frame must authenticate; anything else is rejected.
                guard type == AudioStreamProtocol.FrameType.auth.rawValue,
                      let presented = String(data: payload, encoding: .utf8),
                      constantTimeEquals(presented, token) else {
                    rejectAuth(client)
                    return
                }
                authenticate(client)
                continue
            }

            if type == AudioStreamProtocol.FrameType.command.rawValue,
               let message = MediaCommandMessage.decode(payload) {
                onCommand?(message.command)
            } else if type == AudioStreamProtocol.FrameType.udpHello.rawValue {
                guard payload.count == 2 else {
                    log.error("udpHello: bad payload (\(payload.count) bytes)")
                    continue
                }
                let udpPort = UInt16(payload[payload.startIndex]) | (UInt16(payload[payload.startIndex + 1]) << 8)
                log.info("udpHello: client requests low-latency UDP on port \(udpPort)")
                attachUDP(client, udpPort: udpPort)
            }
        }
    }

    /// Marks the client authenticated, sends the header, and replays the
    /// current now-playing state. Runs on `queue`.
    private nonisolated func authenticate(_ client: Client) {
        client.authenticated = true
        client.connection.send(content: header.encoded(), completion: .contentProcessed { _ in })
        client.headerSent = true
        // Replay current now-playing state (artwork first so the receiver
        // can pair it with the info's artworkID).
        if let artwork = currentArtworkFrame {
            client.connection.send(content: artwork, completion: .contentProcessed { _ in })
        }
        if let info = currentNowPlayingFrame {
            client.connection.send(content: info, completion: .contentProcessed { _ in })
        }
        notifyClientCount()
    }

    /// Sends an authFailed frame explaining the rejection, then drops the
    /// client once the frame has flushed. Runs on `queue`.
    private nonisolated func rejectAuth(_ client: Client) {
        let frame = AudioStreamProtocol.encodeFrame(
            .authFailed,
            Data("Invalid access token".utf8)
        )
        client.connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.remove(client.connection)
        })
    }

    /// Length-aware, content-independent string comparison to avoid leaking
    /// the token via response timing.
    private nonisolated func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    private nonisolated func remove(_ connection: NWConnection) {
        guard let client = clients.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        client.udp?.cancel()
        client.udp = nil
        connection.cancel()
        notifyClientCount()
    }

    private nonisolated func notifyClientCount() {
        let count = clients.values.filter(\.headerSent).count
        onClientCountChange?(count)
    }
}
