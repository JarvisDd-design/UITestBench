import Foundation
import CoreMedia
import VideoToolbox

public enum H264DecoderError: Error, Equatable {
    case invalidParameterSets
    case notConfigured
    case sessionCreationFailed(Int32)
    case decodeFailed(Int32)
}

/// 包一层 VTDecompressionSession，把 Annex-B 负载解成像素缓冲。
///
/// 一次 `decode` 对应一个完整的访问单元，同步返回（内部等解码回调）。
/// 设备旋转或分辨率变化时重新 `configure`，旧会话会被释放。
public final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    private let stateLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var pendingStatus: OSStatus = noErr
    private let outputReady = DispatchSemaphore(value: 0)

    public init() {}

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    public func configure(sps: Data, pps: Data) throws {
        var format: CMFormatDescription?
        let createStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else { return -1 }

                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard createStatus == noErr, let format else {
            throw H264DecoderError.invalidParameterSets
        }

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard let refcon else { return }
                Unmanaged<H264Decoder>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .recordOutput(status: status, imageBuffer: imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else {
            throw H264DecoderError.sessionCreationFailed(sessionStatus)
        }

        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        self.session = newSession
        self.formatDescription = format
    }

    /// 返回 nil 表示这一帧没有产出（例如非关键帧缺参考帧）。
    public func decode(_ annexB: Data, pts: CMTime, isKeyFrame: Bool) throws -> CVPixelBuffer? {
        guard let session, let formatDescription else {
            throw H264DecoderError.notConfigured
        }

        let avcc = H264.avcc(fromAnnexB: annexB)
        guard !avcc.isEmpty else {
            throw H264DecoderError.decodeFailed(-1)
        }

        stateLock.lock()
        pendingBuffer = nil
        pendingStatus = noErr
        stateLock.unlock()
        while outputReady.wait(timeout: .now()) == .success {}

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw H264DecoderError.decodeFailed(status)
        }

        status = CMBlockBufferAssureBlockMemory(blockBuffer)
        guard status == noErr else {
            throw H264DecoderError.decodeFailed(status)
        }

        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard status == noErr else {
            throw H264DecoderError.decodeFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw H264DecoderError.decodeFailed(status)
        }

        if !isKeyFrame {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }

        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw H264DecoderError.decodeFailed(status)
        }

        if outputReady.wait(timeout: .now() + 2) == .timedOut {
            return nil
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        if pendingStatus != noErr {
            throw H264DecoderError.decodeFailed(pendingStatus)
        }
        return pendingBuffer
    }

    private func recordOutput(status: OSStatus, imageBuffer: CVImageBuffer?) {
        stateLock.lock()
        pendingStatus = status
        pendingBuffer = imageBuffer
        stateLock.unlock()
        outputReady.signal()
    }
}
