import Foundation
import AVFoundation
import VideoToolbox
@preconcurrency import MoonlightCommonC

/// Decodes H.264/HEVC NAL units from moonlight-common-c and enqueues them
/// on an AVSampleBufferDisplayLayer for hardware-accelerated rendering.
class MoonlightVideoRenderer: @unchecked Sendable {
    nonisolated(unsafe) let displayLayer = AVSampleBufferDisplayLayer()

    private nonisolated(unsafe) var formatDescription: CMVideoFormatDescription?
    private nonisolated(unsafe) var videoFormat: Int32 = 0
    private nonisolated(unsafe) var frameCount: UInt64 = 0

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

        Task { @MainActor in
            self.displayLayer.videoGravity = .resizeAspect
        }

        return 0
    }

    nonisolated func start() {}
    nonisolated func stop() {
        Task { @MainActor in
            displayLayer.flushAndRemoveImage()
        }
    }
    nonisolated func cleanup() {
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        currentVPS = nil
    }

    /// Process a decode unit from moonlight-common-c. Called from a background thread.
    nonisolated func submitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        var spsData: Data?
        var ppsData: Data?
        var vpsData: Data?
        var pictureData = Data()

        // Walk the LENTRY linked list
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
                spsData = rawData.dropFirst(startCodeLen)
            case BUFFER_TYPE_PPS:
                ppsData = rawData.dropFirst(startCodeLen)
            case BUFFER_TYPE_VPS:
                vpsData = rawData.dropFirst(startCodeLen)
            default:
                // Picture data: replace start code with 4-byte length prefix
                let nalData = rawData.dropFirst(startCodeLen)
                var nalLength = UInt32(nalData.count).bigEndian
                pictureData.append(Data(bytes: &nalLength, count: 4))
                pictureData.append(nalData)
            }

            entry = e.pointee.next
        }

        // Update format description if we got new parameter sets
        if let sps = spsData, let pps = ppsData {
            currentSPS = sps
            currentPPS = pps
            if let vps = vpsData {
                currentVPS = vps
            }
            updateFormatDescription()
        }

        // Create and enqueue sample buffer
        guard !pictureData.isEmpty, let fmtDesc = formatDescription else {
            return DR_NEED_IDR
        }

        if let sampleBuffer = createSampleBuffer(from: pictureData, formatDescription: fmtDesc, decodeUnit: du) {
            displayLayer.enqueue(sampleBuffer)
        }

        frameCount += 1
        return DR_OK
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
        }
    }

    // MARK: - Sample Buffer Creation

    private nonisolated func createSampleBuffer(from pictureData: Data, formatDescription: CMVideoFormatDescription,
                                                decodeUnit du: UnsafeMutablePointer<DECODE_UNIT>) -> CMSampleBuffer? {
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

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = pictureData.count

        // Use presentation timestamp from moonlight-common-c
        let pts = CMTime(value: CMTimeValue(du.pointee.presentationTimeUs), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
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

        guard status == noErr else { return nil }
        return sampleBuffer
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
