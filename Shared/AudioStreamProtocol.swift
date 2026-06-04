import Foundation

/// Wire protocol for streaming uncompressed system audio from the macOS
/// sender (VisionVNC Audio Sender) to the visionOS receiver.
///
/// Transport: TCP. The sender writes a fixed 16-byte header on connect,
/// followed by length-prefixed frames of interleaved Float32 PCM samples.
/// All integers are little-endian.
///
/// Header layout (16 bytes):
///   0-3   magic "VVAS"
///   4     protocol version (1)
///   5     channel count
///   6-7   reserved (0)
///   8-15  sample rate, Float64 bit pattern
///
/// Frame layout:
///   0-3   payload byte count, UInt32
///   4-    interleaved Float32 samples
nonisolated enum AudioStreamProtocol {
    static let magic: [UInt8] = Array("VVAS".utf8)
    static let version: UInt8 = 1
    static let headerSize = 16
    static let frameLengthPrefixSize = 4
    static let defaultPort: UInt16 = 4855
    /// Sanity cap for a single frame (1 MB ≈ 1.3 s of 48 kHz stereo Float32)
    static let maxFrameBytes: UInt32 = 1 << 20

    /// Wraps a PCM payload in a length-prefixed frame.
    static func encodeFrame(_ payload: Data) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + payload.count)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Reads the frame length prefix from the start of `data`.
    /// Returns nil if fewer than 4 bytes are available.
    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for i in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + i]) << (8 * i)
        }
        return value
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
