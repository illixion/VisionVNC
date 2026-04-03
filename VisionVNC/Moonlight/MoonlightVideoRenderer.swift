import Foundation
import AVFoundation
import VideoToolbox
@preconcurrency import MoonlightCommonC

/// Decodes H.264/HEVC NAL units from moonlight-common-c using VTDecompressionSession,
/// producing CGImage frames for display in SwiftUI.
class MoonlightVideoRenderer: @unchecked Sendable {
    /// Latest decoded frame — read by the display link on the main thread.
    nonisolated(unsafe) var latestFrame: CGImage?

    private nonisolated(unsafe) var decompressionSession: VTDecompressionSession?
    private nonisolated(unsafe) var formatDescription: CMVideoFormatDescription?
    private nonisolated(unsafe) var videoFormat: Int32 = 0
    nonisolated(unsafe) var frameCount: UInt64 = 0

    // Stats tracking
    nonisolated(unsafe) var totalDecodeTimeMs: Double = 0
    nonisolated(unsafe) var lastDecodeTimeMs: Double = 0
    nonisolated(unsafe) var droppedFrames: UInt64 = 0

    // Cached parameter sets for creating format descriptions
    private nonisolated(unsafe) var currentSPS: Data?
    private nonisolated(unsafe) var currentPPS: Data?
    private nonisolated(unsafe) var currentVPS: Data?  // HEVC only

    nonisolated init() {}

    nonisolated func setup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 {
        self.videoFormat = videoFormat
        self.formatDescription = nil
        self.currentSPS = nil
        self.currentPPS = nil
        self.currentVPS = nil
        self.frameCount = 0
        self.latestFrame = nil

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        let isHEVC = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0
        print("[MoonlightVideo] Setup: \(width)x\(height)@\(fps) format=0x\(String(videoFormat, radix: 16)) (\(isHEVC ? "HEVC" : "H.264"))")

        return 0
    }

    nonisolated func start() {
        print("[MoonlightVideo] Start")
    }

    nonisolated func stop() {
        print("[MoonlightVideo] Stop")
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    nonisolated func cleanup() {
        stop()
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        currentVPS = nil
        latestFrame = nil
    }

    /// Process a decode unit from moonlight-common-c. Called from a background thread.
    nonisolated func submitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        var spsData: Data?
        var ppsData: Data?
        var vpsData: Data?
        var pictureData = Data()
        var currentNAL = Data()  // Accumulates the current NAL unit across continuation entries

        // Walk the LENTRY linked list.
        // moonlight-common-c splits large NAL units across multiple LENTRYs for network
        // packet alignment. Only the first entry of a NAL has an Annex B start code;
        // subsequent entries (startCode=0) are continuation data for the same NAL.
        var entry = du.pointee.bufferList
        while let e = entry {
            let length = Int(e.pointee.length)
            guard length > 0, let dataPtr = e.pointee.data else {
                entry = e.pointee.next
                continue
            }

            let rawData = Data(bytes: dataPtr, count: length)
            let startCodeLen = detectStartCodeLength(rawData)

            switch e.pointee.bufferType {
            case BUFFER_TYPE_SPS:
                spsData = Data(rawData.dropFirst(startCodeLen))
            case BUFFER_TYPE_PPS:
                ppsData = Data(rawData.dropFirst(startCodeLen))
            case BUFFER_TYPE_VPS:
                vpsData = Data(rawData.dropFirst(startCodeLen))
            default:
                if startCodeLen > 0 {
                    // New NAL unit — flush the previous one if any
                    if !currentNAL.isEmpty {
                        var nalLength = UInt32(currentNAL.count).bigEndian
                        pictureData.append(Data(bytes: &nalLength, count: 4))
                        pictureData.append(currentNAL)
                    }
                    // Start accumulating a new NAL (strip Annex B start code)
                    currentNAL = Data(rawData.dropFirst(startCodeLen))
                } else {
                    // Continuation data — append to the current NAL
                    currentNAL.append(rawData)
                }
            }

            entry = e.pointee.next
        }

        // Flush the last NAL unit
        if !currentNAL.isEmpty {
            var nalLength = UInt32(currentNAL.count).bigEndian
            pictureData.append(Data(bytes: &nalLength, count: 4))
            pictureData.append(currentNAL)
        }

        if frameCount < 2 && !pictureData.isEmpty {
            let preview = Array(pictureData.prefix(16)).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[MoonlightVideo] pictureData: \(pictureData.count) bytes (\(currentNAL.count) NAL), first16=\(preview)")
        }

        // Update format description if we got new parameter sets
        if let sps = spsData, let pps = ppsData {
            // Only update if parameter sets actually changed
            let spsChanged = (currentSPS != sps)
            let ppsChanged = (currentPPS != pps)
            let vpsChanged = (vpsData != nil && currentVPS != vpsData)

            if spsChanged || ppsChanged || vpsChanged || formatDescription == nil {
                currentSPS = sps
                currentPPS = pps
                if let vps = vpsData {
                    currentVPS = vps
                }
                updateFormatDescription()
                recreateDecompressionSession()
            }
        }

        // Decode the picture data
        guard !pictureData.isEmpty, let fmtDesc = formatDescription else {
            if frameCount == 0 {
                print("[MoonlightVideo] No format description yet, requesting IDR")
            }
            return DR_NEED_IDR
        }

        // Ensure we have a decompression session
        if decompressionSession == nil {
            recreateDecompressionSession()
            guard decompressionSession != nil else {
                print("[MoonlightVideo] No decompression session, requesting IDR")
                return DR_NEED_IDR
            }
        }

        guard let session = decompressionSession,
              let sampleBuffer = createSampleBuffer(from: pictureData, formatDescription: fmtDesc) else {
            return DR_OK
        }

        // Decode using closure-based output handler (avoids C function pointer issues on visionOS)
        let renderer = self
        var infoFlags = VTDecodeInfoFlags()
        let decodeStart = CACurrentMediaTime()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { decodeStatus, _, imageBuffer, _, _ in
            guard decodeStatus == noErr, let pixelBuffer = imageBuffer else {
                if renderer.frameCount < 10 {
                    print("[MoonlightVideo] Decode handler: error status=\(decodeStatus), hasImage=\(imageBuffer != nil)")
                }
                return
            }

            // Convert CVPixelBuffer to CGImage
            var cgImage: CGImage?
            let vtStatus = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if vtStatus == noErr, let image = cgImage {
                renderer.latestFrame = image
                if renderer.frameCount < 3 {
                    print("[MoonlightVideo] Frame decoded to CGImage: \(image.width)x\(image.height)")
                }
            } else {
                if renderer.frameCount < 10 {
                    print("[MoonlightVideo] CGImage creation failed: OSStatus \(vtStatus)")
                }
            }
        }

        let decodeElapsed = (CACurrentMediaTime() - decodeStart) * 1000.0
        lastDecodeTimeMs = decodeElapsed
        totalDecodeTimeMs += decodeElapsed

        if status != noErr {
            if frameCount < 5 || frameCount % 300 == 0 {
                print("[MoonlightVideo] DecodeFrame error: OSStatus \(status), frame \(frameCount)")
            }
            if status == kVTInvalidSessionErr {
                recreateDecompressionSession()
                return DR_NEED_IDR
            }
            droppedFrames += 1
        }

        frameCount += 1
        if frameCount == 1 {
            print("[MoonlightVideo] First frame decoded! pictureData=\(pictureData.count) bytes")
        } else if frameCount % 300 == 0 {
            print("[MoonlightVideo] Frame \(frameCount) decoded")
        }

        return DR_OK
    }

    // MARK: - Decompression Session

    private nonisolated func recreateDecompressionSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        guard let fmtDesc = formatDescription else { return }

        // Create session without pixel format constraint — let VideoToolbox choose native format.
        // Requesting BGRA can fail on visionOS for HEVC.
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmtDesc,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr, let s = session {
            decompressionSession = s
            print("[MoonlightVideo] Decompression session created")
        } else {
            print("[MoonlightVideo] Failed to create decompression session: OSStatus \(status)")
        }
    }

    // MARK: - Format Description

    private nonisolated func updateFormatDescription() {
        guard let sps = currentSPS, let pps = currentPPS else { return }

        var newFmtDesc: CMVideoFormatDescription?
        var status: OSStatus

        let isHEVC = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0

        if isHEVC, let vps = currentVPS {
            // HEVC: VPS + SPS + PPS
            status = vps.withUnsafeBytes { vpsPtr in
                sps.withUnsafeBytes { spsPtr in
                    pps.withUnsafeBytes { ppsPtr in
                        let parameterSetPointers: [UnsafePointer<UInt8>] = [
                            vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ]
                        let parameterSetSizes: [Int] = [vps.count, sps.count, pps.count]
                        return parameterSetPointers.withUnsafeBufferPointer { ptrsBuffer in
                            parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: ptrsBuffer.baseAddress!,
                                    parameterSetSizes: sizesBuffer.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &newFmtDesc
                                )
                            }
                        }
                    }
                }
            }
        } else {
            // H.264: SPS + PPS
            status = sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let parameterSetSizes: [Int] = [sps.count, pps.count]
                    return parameterSetPointers.withUnsafeBufferPointer { ptrsBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrsBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &newFmtDesc
                            )
                        }
                    }
                }
            }
        }

        if status == noErr, let desc = newFmtDesc {
            formatDescription = desc
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            print("[MoonlightVideo] Format description created: \(dimensions.width)x\(dimensions.height)")
        } else {
            print("[MoonlightVideo] Failed to create format description: OSStatus \(status)")
        }
    }

    // MARK: - Sample Buffer Creation

    private nonisolated func createSampleBuffer(from pictureData: Data, formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        // Create CMBlockBuffer with a copy of the picture data
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: pictureData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: pictureData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        // Copy picture data into the block buffer
        pictureData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: pictureData.count
            )
        }

        // Create sample buffer with invalid timing (VTDecompressionSession ignores timing)
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = pictureData.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sb = sampleBuffer else {
            print("[MoonlightVideo] Failed to create sample buffer: OSStatus \(status)")
            return nil
        }

        return sb
    }

    // MARK: - Helpers

    /// Detect Annex B start code length (3 or 4 bytes)
    private nonisolated func detectStartCodeLength(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            return 4
        }
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
            return 3
        }
        return 0
    }
}
