import XCTest
import CoreMedia
import VideoToolbox
@testable import UITestBenchCore

final class H264DecoderTests: XCTestCase {
    func testDecodesEncodedKeyFrameAtSourceSize() throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let decoder = H264Decoder()
        try decoder.configure(sps: encoded.sps, pps: encoded.pps)

        let pixelBuffer = try XCTUnwrap(
            try decoder.decode(
                encoded.annexB,
                pts: CMTime(value: 0, timescale: 1_000_000),
                isKeyFrame: true
            )
        )

        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 240)
    }

    func testConfigureRejectsGarbageParameterSets() {
        let decoder = H264Decoder()

        XCTAssertThrowsError(try decoder.configure(sps: Data([0x00]), pps: Data([0x00]))) { error in
            XCTAssertEqual(error as? H264DecoderError, .invalidParameterSets)
        }
    }

    func testDecodeBeforeConfigureFails() {
        let decoder = H264Decoder()

        XCTAssertThrowsError(
            try decoder.decode(Data([0, 0, 0, 1, 0x65]), pts: .zero, isKeyFrame: true)
        ) { error in
            XCTAssertEqual(error as? H264DecoderError, .notConfigured)
        }
    }
}

final class ScrcpyDecoderTests: XCTestCase {
    func testDecodesFirstFrameFromProtocolEvents() throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let decoder = ScrcpyDecoder()

        XCTAssertNil(try decoder.consume(.session(
            ScrcpySessionHeader(width: 320, height: 240, clientResized: false)
        )))
        XCTAssertNil(try decoder.consume(.media(
            ScrcpyMediaHeader(pts: 0, isConfig: true, isKeyFrame: false, size: 0),
            H264TestData.annexBParameterSets(sps: encoded.sps, pps: encoded.pps)
        )))

        let frame = try XCTUnwrap(try decoder.consume(.media(
            ScrcpyMediaHeader(pts: 5_000, isConfig: false, isKeyFrame: true, size: 0),
            encoded.annexB
        )))

        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 240)
        XCTAssertEqual(frame.pts, CMTime(value: 5_000, timescale: 1_000_000))
    }

    func testMediaBeforeConfigurationIsRejected() {
        let decoder = ScrcpyDecoder()

        XCTAssertThrowsError(try decoder.consume(.media(
            ScrcpyMediaHeader(pts: 0, isConfig: false, isKeyFrame: true, size: 0),
            Data([0, 0, 0, 1, 0x65])
        ))) { error in
            XCTAssertEqual(error as? ScrcpyDecodeError, .missingConfiguration)
        }
    }

    func testMalformedConfigPacketIsRejected() {
        let decoder = ScrcpyDecoder()

        XCTAssertThrowsError(try decoder.consume(.media(
            ScrcpyMediaHeader(pts: 0, isConfig: true, isKeyFrame: false, size: 0),
            Data([0, 0, 0, 1, 0x65, 0x01])
        ))) { error in
            XCTAssertEqual(error as? ScrcpyDecodeError, .missingParameterSets)
        }
    }
}

// MARK: - 用系统编码器造一段真实的 H.264

enum H264TestData {
    struct Encoded {
        let sps: Data
        let pps: Data
        let annexB: Data
    }

    static func annexBParameterSets(sps: Data, pps: Data) -> Data {
        var data = Data([0, 0, 0, 1])
        data.append(sps)
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(pps)
        return data
    }

    static func encodeSolidFrame(width: Int, height: Int) throws -> Encoded {
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            throw NSError(domain: "H264TestData", code: Int(createStatus))
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTCompressionSessionPrepareToEncodeFrames(session)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard let pixelBuffer else {
            throw NSError(domain: "H264TestData", code: -1, userInfo: [NSLocalizedDescriptionKey: "建像素缓冲失败"])
        }
        fill(pixelBuffer, width: width, height: height)

        var output: CMSampleBuffer?
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 1_000_000),
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            if status == noErr, let sampleBuffer {
                output = sampleBuffer
            }
        }
        guard encodeStatus == noErr else {
            throw NSError(domain: "H264TestData", code: Int(encodeStatus))
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let output, let format = CMSampleBufferGetFormatDescription(output) else {
            throw NSError(domain: "H264TestData", code: -2, userInfo: [NSLocalizedDescriptionKey: "编码器没有输出"])
        }

        var headerLength: Int32 = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &headerLength
        )

        let sps = try parameterSet(format, index: 0)
        let pps = try parameterSet(format, index: 1)
        let avcc = try sampleData(output)
        let annexB = try avccToAnnexB(avcc, headerLength: Int(headerLength))

        return Encoded(sps: sps, pps: pps, annexB: annexB)
    }

    private static func fill(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = row + x * 4
                pixel[0] = 32   // B
                pixel[1] = 48   // G
                pixel[2] = 200  // R
                pixel[3] = 255  // A
            }
        }
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) throws -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer, size > 0 else {
            throw NSError(domain: "H264TestData", code: Int(status))
        }
        return Data(bytes: pointer, count: size)
    }

    private static func sampleData(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(domain: "H264TestData", code: -3)
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer, length > 0 else {
            throw NSError(domain: "H264TestData", code: Int(status))
        }
        return Data(bytes: pointer, count: length)
    }

    private static func avccToAnnexB(_ data: Data, headerLength: Int) throws -> Data {
        guard headerLength > 0 else {
            throw NSError(domain: "H264TestData", code: -4)
        }
        var output = Data()
        var index = data.startIndex

        while index + headerLength <= data.endIndex {
            var length = 0
            for offset in 0..<headerLength {
                length = (length << 8) | Int(data[index + offset])
            }
            index += headerLength
            guard length > 0, index + length <= data.endIndex else { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[index..<index + length])
            index += length
        }

        guard !output.isEmpty else {
            throw NSError(domain: "H264TestData", code: -5)
        }
        return output
    }
}
