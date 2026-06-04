import Foundation

/// Wire protocol for streaming uncompressed system audio from the macOS
/// sender (VisionVNC Audio Sender) to the visionOS receiver, plus
/// now-playing metadata (sender → receiver) and media transport commands
/// (receiver → sender) for controlling Music.app on the Mac.
///
/// Transport: TCP. The sender writes a fixed 16-byte header on connect,
/// followed by typed, length-prefixed frames in both directions.
/// All integers are little-endian.
///
/// Header layout (16 bytes):
///   0-3   magic "VVAS"
///   4     protocol version (2)
///   5     channel count
///   6-7   reserved (0)
///   8-15  sample rate, Float64 bit pattern
///
/// Frame layout (v2):
///   0-3   body byte count (type byte + payload), UInt32
///   4     frame type (FrameType)
///   5-    payload
///
/// Both apps are released together; version mismatches hard-fail at the
/// header parse (no v1 compatibility path).
nonisolated enum AudioStreamProtocol {
    static let magic: [UInt8] = Array("VVAS".utf8)
    static let version: UInt8 = 2
    static let headerSize = 16
    static let frameLengthPrefixSize = 4
    static let defaultPort: UInt16 = 4855
    /// Sanity cap for a single frame (1 MB ≈ 1.3 s of 48 kHz stereo Float32)
    static let maxFrameBytes: UInt32 = 1 << 20

    enum FrameType: UInt8, Sendable {
        /// Interleaved Float32 PCM samples (sender → receiver).
        case pcm = 0x00
        /// NowPlayingInfo JSON (sender → receiver).
        case nowPlaying = 0x01
        /// Scaled JPEG artwork bytes; always immediately precedes the
        /// nowPlaying frame carrying the matching artworkID (sender → receiver).
        case artwork = 0x02
        /// MediaCommandMessage JSON (receiver → sender).
        case command = 0x03
    }

    /// Wraps a payload in a typed, length-prefixed frame.
    static func encodeFrame(_ type: FrameType, _ payload: Data) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + 1 + payload.count)
        var length = UInt32(1 + payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    /// Convenience for the hot audio path.
    static func encodeFrame(_ payload: Data) -> Data {
        encodeFrame(.pcm, payload)
    }

    /// Reads the frame length prefix (type byte + payload count) from the
    /// start of `data`. Returns nil if fewer than 4 bytes are available.
    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for i in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + i]) << (8 * i)
        }
        return value
    }
}

// MARK: - Now Playing / Media Commands

/// Snapshot of the Mac's Music.app playback state, sent as JSON in a
/// `nowPlaying` frame on every state/track change (and replayed to newly
/// connected clients). `elapsedSeconds` is a snapshot — the receiver
/// extrapolates locally while `isPlaying`.
nonisolated struct NowPlayingInfo: Codable, Sendable, Equatable {
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var isPlaying: Bool = false
    var durationSeconds: Double? = nil
    var elapsedSeconds: Double? = nil
    /// Identity of the current artwork (Music persistent ID). The receiver
    /// pairs the preceding `artwork` frame with this id and caches it.
    var artworkID: String? = nil

    /// True when there is an actual track to show.
    var hasTrack: Bool { title != nil }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Returns nil on malformed JSON — a bad metadata frame must never
    /// kill the audio stream.
    static func decode(_ data: Data) -> NowPlayingInfo? {
        try? JSONDecoder().decode(NowPlayingInfo.self, from: data)
    }
}

/// Transport command sent by the receiver to control Music.app on the Mac.
nonisolated enum MediaCommand: String, Codable, Sendable {
    case play, pause, toggle, next, previous
}

nonisolated struct MediaCommandMessage: Codable, Sendable {
    let command: MediaCommand

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> MediaCommandMessage? {
        try? JSONDecoder().decode(MediaCommandMessage.self, from: data)
    }
}

/// Stream format negotiation header, sent once by the sender on connect.
nonisolated struct AudioStreamHeader: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    func encoded() -> Data {
        var data = Data(capacity: AudioStreamProtocol.headerSize)
        data.append(contentsOf: AudioStreamProtocol.magic)
        data.append(AudioStreamProtocol.version)
        data.append(UInt8(channelCount))
        data.append(contentsOf: [0, 0])
        var bits = sampleRate.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        return data
    }

    /// Parses the first 16 bytes of `data`. Returns nil on short data,
    /// bad magic, version mismatch, or nonsensical format values.
    init?(parsing data: Data) {
        guard data.count >= AudioStreamProtocol.headerSize else { return nil }
        let bytes = [UInt8](data.prefix(AudioStreamProtocol.headerSize))
        guard Array(bytes[0..<4]) == AudioStreamProtocol.magic,
              bytes[4] == AudioStreamProtocol.version else { return nil }

        let channels = Int(bytes[5])
        guard (1...8).contains(channels) else { return nil }

        var bits: UInt64 = 0
        for i in 0..<8 {
            bits |= UInt64(bytes[8 + i]) << (8 * i)
        }
        let rate = Double(bitPattern: bits)
        guard rate.isFinite, rate >= 8_000, rate <= 384_000 else { return nil }

        self.sampleRate = rate
        self.channelCount = channels
    }
}
