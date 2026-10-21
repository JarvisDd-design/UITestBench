import Foundation
import CoreMedia
import CoreVideo

public enum VideoSampleBufferError: Error, Equatable {
    case formatDescriptionFailed(Int32)
    case sampleBufferFailed(Int32)
}

/// 把解码出的像素缓冲包成 AVSampleBufferDisplayLayer 能直接吃的样子。
public enum VideoSampleBuffer {
    public static func make(from frame: DecodedFrame) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw VideoSampleBufferError.formatDescriptionFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoSampleBufferError.sampleBufferFailed(sampleStatus)
        }
        return sampleBuffer
    }
}
