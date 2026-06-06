import Foundation
import CoreAudio
import AudioToolbox

/// Captures system-wide audio output via a Core Audio process tap
/// (macOS 14.2+) — no virtual audio driver (BlackHole etc.) required.
///
/// When `muteSystemOutput` is enabled, the tap is created with
/// `.muted` behavior: the Mac's (or Vision Pro Sidecar's) physical output
/// is silenced while the tap keeps receiving the rendered audio, so the
/// only audible copy is the one streamed to the receiver.
///
/// Audio flows: process tap → private aggregate device → IOProc block,
/// which converts the tap's interleaved Float32 to interleaved signed int24
/// (the wire format, see `PCM24`) and delivers it via `onAudio` on a
/// realtime Core Audio thread.
final class SystemAudioTap: @unchecked Sendable {

    struct StreamFormat: Sendable {
        let sampleRate: Double
        let channelCount: Int
    }

    enum TapError: LocalizedError {
        case osStatus(String, OSStatus)
        case badFormat

        var errorDescription: String? {
            switch self {
            case .osStatus(let stage, let status):
                "\(stage) failed (OSStatus \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .badFormat:
                "The system audio tap reported an unusable stream format."
            }
        }
    }

    /// Called on a Core Audio realtime thread with interleaved signed int24
    /// PCM (the wire format), converted from the tap's Float32 samples.
    nonisolated(unsafe) var onAudio: (@Sendable (Data) -> Void)?

    private nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) var format: AudioStreamBasicDescription?

    nonisolated init() {}

    /// Creates the tap + aggregate device and starts IO.
    /// Returns the capture format so the caller can build the stream header.
    nonisolated func start(muteSystemOutput: Bool) throws -> StreamFormat {
        stop()

        // 1. System-wide stereo mixdown tap of all processes
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "VisionVNC Audio Tap"
        description.isPrivate = true
        description.muteBehavior = muteSystemOutput ? .muted : .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw TapError.osStatus("Creating process tap", status) }
        tapID = newTapID

        // 2. Read the tap's stream format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Reading tap format", status)
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            stop()
            throw TapError.badFormat
        }
        format = asbd

        // 3. Private aggregate device hosting the tap
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VisionVNC Audio Sender",
            kAudioAggregateDeviceUIDKey: "com.illixion.VisionVNCAudioSender.aggregate",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Creating aggregate device", status)
        }
        aggregateID = newAggregateID

        // 4. IOProc pulling tapped audio
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channelCount = Int(asbd.mChannelsPerFrame)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let onAudio = self.onAudio else { return }
            let payload = Self.extractPCM(
                from: inInputData,
                isNonInterleaved: isNonInterleaved,
                channelCount: channelCount
            )
            if !payload.isEmpty {
                onAudio(payload)
            }
        }
        guard status == noErr, ioProcID != nil else {
            stop()
            throw TapError.osStatus("Creating IO proc", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Starting audio device", status)
        }

        return StreamFormat(sampleRate: asbd.mSampleRate, channelCount: channelCount)
    }

    nonisolated func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
    }

    /// Converts an AudioBufferList of Float32 samples into a contiguous
    /// interleaved signed int24 blob (the wire format — see `PCM24`).
    private nonisolated static func extractPCM(
        from bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int
    ) -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard !buffers.isEmpty else { return Data() }

        if !isNonInterleaved || buffers.count == 1 {
            // Already interleaved (the stereo mixdown tap's usual format)
            let buffer = buffers[0]
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let floats = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float32.self),
                count: count
            )
            return PCM24.encode(floats)
        }

        // Non-interleaved: one buffer per channel — interleave manually
        let frameBytes = Int(buffers[0].mDataByteSize)
        let frameCount = frameBytes / MemoryLayout<Float32>.size
        var interleaved = [Float32](repeating: 0, count: frameCount * channelCount)
        for channel in 0..<min(channelCount, buffers.count) {
            guard let base = buffers[channel].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + channel] = base[frame]
            }
        }
        return interleaved.withUnsafeBufferPointer { PCM24.encode($0) }
    }
}
