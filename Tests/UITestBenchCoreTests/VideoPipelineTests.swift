import XCTest
import CoreMedia
@testable import UITestBenchCore

final class ScrcpyFramePumpTests: XCTestCase {
    func testNextFrameDecodesFirstVideoFrame() throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let pump = ScrcpyFramePump(reader: ScrcpyVideoReader(
            stream: FakeByteStream(bytes: protocolStream(encoded: encoded, width: 320, height: 240))
        ))

        let frame = try XCTUnwrap(try pump.nextFrame())

        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 240)
        XCTAssertEqual(frame.pts, CMTime(value: 1_000, timescale: 1_000_000))
    }

    /// 转屏时服务端会先发新的会话包，再发新的配置包。
    /// 解码器必须丢掉旧会话，按新的 SPS/PPS 重建，否则第二帧解不出来。
    func testRebuildsDecoderWhenServerReportsNewSize() throws {
        let portrait = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let landscape = try H264TestData.encodeSolidFrame(width: 240, height: 320)
        let stream = protocolStream(encoded: portrait, width: 320, height: 240)
            + protocolStream(encoded: landscape, width: 240, height: 320)
        let pump = ScrcpyFramePump(reader: ScrcpyVideoReader(stream: FakeByteStream(bytes: stream)))

        let first = try XCTUnwrap(try pump.nextFrame())
        let second = try XCTUnwrap(try pump.nextFrame())

        XCTAssertEqual([first.width, first.height], [320, 240])
        XCTAssertEqual([second.width, second.height], [240, 320])
        XCTAssertNil(try pump.nextFrame())
    }

    func testNextFrameReturnsNilAtEndOfStream() throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let pump = ScrcpyFramePump(reader: ScrcpyVideoReader(
            stream: FakeByteStream(bytes: protocolStream(encoded: encoded, width: 320, height: 240))
        ))

        _ = try pump.nextFrame()
        XCTAssertNil(try pump.nextFrame())
    }

    private func protocolStream(encoded: H264TestData.Encoded, width: UInt32, height: UInt32) -> Data {
        var bytes = Data([0x80, 0, 0, 0])
        bytes.appendBE32(width)
        bytes.appendBE32(height)

        let config = H264TestData.annexBParameterSets(sps: encoded.sps, pps: encoded.pps)
        bytes.append(mediaHeader(pts: 0, config: true, keyFrame: false, size: config.count))
        bytes.append(config)

        bytes.append(mediaHeader(pts: 1_000, config: false, keyFrame: true, size: encoded.annexB.count))
        bytes.append(encoded.annexB)
        return bytes
    }

    private func mediaHeader(pts: UInt64, config: Bool, keyFrame: Bool, size: Int) -> Data {
        var flags = pts
        if config { flags |= UInt64(1) << 62 }
        if keyFrame { flags |= UInt64(1) << 61 }
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((flags >> UInt64(shift)) & 0xFF))
        }
        data.appendBE32(UInt32(size))
        return data
    }
}

final class VideoSampleBufferTests: XCTestCase {
    func testWrapsDecodedFrameForDisplayLayer() throws {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            nil, &pixelBuffer
        )
        let frame = DecodedFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            pts: CMTime(value: 2_500, timescale: 1_000_000)
        )

        let sample = try VideoSampleBuffer.make(from: frame)

        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sample),
            CMTime(value: 2_500, timescale: 1_000_000)
        )
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(image), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 240)
    }
}
