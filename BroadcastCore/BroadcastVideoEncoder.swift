import Foundation
import CoreMedia
import VideoToolbox

/// Hardware H.264 encoder for the broadcast pipeline. Mirrors the decode
/// side of `MoonlightVideoRenderer`: VideoToolbox session, AVCC output
/// split into raw NAL units. Runs entirely on the capture callback thread
/// (the session is created lazily from the first frame's dimensions).
final class BroadcastVideoEncoder: @unchecked Sendable {

    /// Fired once when SPS/PPS first become available (and again if they
    /// change) — gates RTSP ANNOUNCE, which embeds them in the SDP.
    nonisolated(unsafe) var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    /// One access unit: raw NALs (SPS/PPS prepended on keyframes), PTS,
    /// keyframe flag. Fires on the VideoToolbox output thread.
    nonisolated(unsafe) var onEncodedFrame: ((_ nalUnits: [Data], _ pts: CMTime, _ keyframe: Bool) -> Void)?
    nonisolated(unsafe) var onError: ((String) -> Void)?

    private let bitrate: Int
    private let frameRate: Int
    private nonisolated(unsafe) var session: VTCompressionSession?
    private nonisolated(unsafe) var currentSPS: Data?
    private nonisolated(unsafe) var currentPPS: Data?

    nonisolated init(bitrate: Int, frameRate: Int = 30) {
        self.bitrate = bitrate
        self.frameRate = frameRate
    }

    nonisolated func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if session == nil {
            createSession(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let session else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard let self, status == noErr, let encodedBuffer else { return }
            self.emit(encodedBuffer)
        }
        if status != noErr {
            onError?("VTCompressionSessionEncodeFrame failed (\(status))")
        }
    }

    nonisolated func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private nonisolated func createSession(width: Int, height: Int) {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            onError?("VTCompressionSessionCreate failed (\(status))")
            return
        }
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        // No B-frames: keeps PTS monotonic for direct RTP timestamping.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: frameRate as CFNumber)
        // 1 s GOP so WHEP/RTSP readers join and recover quickly.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: 1.0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        broadcastLog("🎥 H.264 encoder ready: \(width)x\(height) @ \(bitrate / 1_000_000) Mbps")
    }

    private nonisolated func emit(_ encodedBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(encodedBuffer) else { return }

        let keyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(encodedBuffer, createIfNecessary: false)
                    as? [[CFString: Any]], let first = attachments.first else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        if let formatDescription = CMSampleBufferGetFormatDescription(encodedBuffer) {
            refreshParameterSets(from: formatDescription)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(encodedBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard copyStatus == noErr else { return }

        var nalUnits = AVCCSplitter.nalUnits(fromAVCC: avcc)
        guard !nalUnits.isEmpty else { return }
        if keyframe, let sps = currentSPS, let pps = currentPPS {
            // In-band parameter sets ahead of each IDR — lets readers that
            // join mid-stream (and post-reconnect publishers) decode without
            // out-of-band SDP refreshes.
            nalUnits.insert(contentsOf: [sps, pps], at: 0)
        }
        onEncodedFrame?(nalUnits, CMSampleBufferGetPresentationTimeStamp(encodedBuffer), keyframe)
    }

    private nonisolated func refreshParameterSets(from formatDescription: CMFormatDescription) {
        func parameterSet(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(at: 0), let pps = parameterSet(at: 1) else { return }
        if sps != currentSPS || pps != currentPPS {
            currentSPS = sps
            currentPPS = pps
            onParameterSets?(sps, pps)
        }
    }
}
