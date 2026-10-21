import XCTest
@testable import UITestBenchCore

// 协议布局全部对着 scrcpy v5.0.1 源码：
//   app/src/demuxer.c        视频流包头与会话包
//   app/src/control_msg.c    控制消息字节布局
//   app/src/server.c         服务端启动参数与 socket 名

final class ScrcpyPacketHeaderTests: XCTestCase {
    func testParsesSessionPacket() {
        var data = Data([0x80, 0x00, 0x00, 0x00])
        data.appendBE32(1080)
        data.appendBE32(2400)

        XCTAssertEqual(
            ScrcpyProtocol.sessionHeader(data),
            ScrcpySessionHeader(width: 1080, height: 2400, clientResized: false)
        )
        XCTAssertNil(ScrcpyProtocol.mediaHeader(data), "会话包不是媒体包")
    }

    func testParsesClientResizedFlag() {
        var data = Data([0x80, 0x00, 0x00, 0x01])
        data.appendBE32(1440)
        data.appendBE32(3120)

        XCTAssertEqual(
            ScrcpyProtocol.sessionHeader(data),
            ScrcpySessionHeader(width: 1440, height: 3120, clientResized: true)
        )
    }

    func testParsesKeyFrameMediaPacket() {
        var ptsAndFlags = UInt64(123_456) | (UInt64(1) << 61)
        var data = Data()
        withUnsafeBytes(of: &ptsAndFlags) { data.append(contentsOf: $0.reversed()) }
        data.appendBE32(42)

        XCTAssertEqual(
            ScrcpyProtocol.mediaHeader(data),
            ScrcpyMediaHeader(pts: 123_456, isConfig: false, isKeyFrame: true, size: 42)
        )
        XCTAssertNil(ScrcpyProtocol.sessionHeader(data))
    }

    func testParsesConfigPacket() {
        var ptsAndFlags = UInt64(1) << 62
        var data = Data()
        withUnsafeBytes(of: &ptsAndFlags) { data.append(contentsOf: $0.reversed()) }
        data.appendBE32(8)

        XCTAssertEqual(
            ScrcpyProtocol.mediaHeader(data),
            ScrcpyMediaHeader(pts: 0, isConfig: true, isKeyFrame: false, size: 8)
        )
    }

    func testRejectsShortHeader() {
        XCTAssertNil(ScrcpyProtocol.sessionHeader(Data([0x80])))
        XCTAssertNil(ScrcpyProtocol.mediaHeader(Data([0x00])))
    }
}

final class ScrcpyVideoHandshakeTests: XCTestCase {
    private func makeStream(deviceName: String, codec: UInt32 = ScrcpyProtocol.codecIDH264,
                            width: UInt32 = 1080, height: UInt32 = 2400) -> FakeByteStream {
        var bytes = Data([0x00]) // dummy byte
        var name = Data(deviceName.utf8)
        name.append(Data(repeating: 0, count: ScrcpyProtocol.deviceNameLength - name.count))
        bytes.append(name)
        bytes.appendBE32(codec)
        var session = Data([0x80, 0, 0, 0])
        session.appendBE32(width)
        session.appendBE32(height)
        bytes.append(session)
        return FakeByteStream(bytes: bytes)
    }

    func testReadsDummyDeviceNameCodecAndSession() throws {
        let stream = makeStream(deviceName: "Pixel 7")

        let handshake = try ScrcpyVideoHandshake.read(from: stream)

        XCTAssertEqual(handshake.deviceName, "Pixel 7")
        XCTAssertEqual(handshake.codec, .h264)
        XCTAssertEqual(handshake.session, ScrcpySessionHeader(width: 1080, height: 2400, clientResized: false))
    }

    func testRejectsUnsupportedCodec() {
        let stream = makeStream(deviceName: "Pixel 7", codec: 0x00_7670_38) // vp8

        XCTAssertThrowsError(try ScrcpyVideoHandshake.read(from: stream)) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .unsupportedCodec(0x00_7670_38))
        }
    }

    func testRejectsUnexpectedFirstPacket() {
        var bytes = Data([0x00])
        bytes.append(Data(repeating: 0, count: 64))
        bytes.appendBE32(ScrcpyProtocol.codecIDH264)
        var media = Data()
        var pts = UInt64(0) | (UInt64(1) << 61)
        withUnsafeBytes(of: &pts) { media.append(contentsOf: $0.reversed()) }
        media.appendBE32(4)
        bytes.append(media)

        XCTAssertThrowsError(try ScrcpyVideoHandshake.read(from: FakeByteStream(bytes: bytes))) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .expectedSessionPacket)
        }
    }

    func testSurfacesEndOfStream() {
        XCTAssertThrowsError(try ScrcpyVideoHandshake.read(from: FakeByteStream(bytes: Data()))) { error in
            XCTAssertEqual(error as? ScrcpyProtocolError, .endOfStream)
        }
    }
}

final class ScrcpyControlMessageTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    func testTouchDownMatchesServerLayout() {
        let message = ScrcpyControlMessage.touch(
            action: .down,
            pointerID: ScrcpyProtocol.pointerIDMouse,
            x: 100,
            y: 200,
            screenWidth: 1080,
            screenHeight: 2400,
            pressure: 1
        )

        XCTAssertEqual(
            hex(message.encoded()),
            "02"                                        // INJECT_TOUCH_EVENT
            + "00"                                      // action down
            + "FFFFFFFFFFFFFFFF"                        // pointer id = -1（鼠标）
            + "00000064"                                // x = 100
            + "000000C8"                                // y = 200
            + "0438"                                    // 屏宽 1080
            + "0960"                                    // 屏高 2400
            + "FFFF"                                    // 压力 1.0
            + "00000000"                                // action button
            + "00000000"                                // buttons
        )
    }

    /// 拖动中的移动事件用 Android 的 ACTION_MOVE（2），不是 down/up。
    func testTouchMoveUsesActionTwo() {
        let message = ScrcpyControlMessage.touch(
            action: .move,
            pointerID: ScrcpyProtocol.pointerIDMouse,
            x: 1, y: 2, screenWidth: 3, screenHeight: 4, pressure: 1
        )

        XCTAssertEqual(message.encoded()[1], 2)
    }

    func testTouchUpUsesActionOne() {
        let message = ScrcpyControlMessage.touch(
            action: .up,
            pointerID: ScrcpyProtocol.pointerIDMouse,
            x: 1, y: 2, screenWidth: 3, screenHeight: 4, pressure: 0
        )

        XCTAssertEqual(
            hex(message.encoded()),
            "02" + "01" + "FFFFFFFFFFFFFFFF" + "00000001" + "00000002"
            + "0003" + "0004" + "0000" + "00000000" + "00000000"
        )
    }

    func testKeycodeMatchesServerLayout() {
        let message = ScrcpyControlMessage.keycode(action: .down, keycode: AndroidKey.back.rawValue)

        XCTAssertEqual(
            hex(message.encoded()),
            "00"                 // INJECT_KEYCODE
            + "00"               // action down
            + "00000004"         // KEYCODE_BACK
            + "00000000"         // repeat
            + "00000000"         // metastate
        )
    }

    /// 键码必须和 Android 的 `KeyEvent` 常量一致，错一个就是按错键。
    func testAndroidKeyRawValuesMatchAndroidKeycodes() {
        XCTAssertEqual(AndroidKey.home.rawValue, 3)
        XCTAssertEqual(AndroidKey.back.rawValue, 4)
        XCTAssertEqual(AndroidKey.enter.rawValue, 66)
        XCTAssertEqual(AndroidKey.appSwitch.rawValue, 187)
    }

    func testScrollNormalizesToFixedPoint() {
        let message = ScrcpyControlMessage.scroll(
            x: 540, y: 1200,
            screenWidth: 1080, screenHeight: 2400,
            horizontal: 0, vertical: 16
        )

        XCTAssertEqual(
            hex(message.encoded()),
            "03"                 // INJECT_SCROLL_EVENT
            + "0000021C"         // x = 540
            + "000004B0"         // y = 1200
            + "0438"             // 屏宽
            + "0960"             // 屏高
            + "0000"             // 横向滚 0
            + "7FFF"             // 纵向滚满 (+1.0 → 32767)
            + "00000000"         // buttons
        )
    }

    func testScrollClampsOutOfRangeValues() {
        let message = ScrcpyControlMessage.scroll(
            x: 0, y: 0, screenWidth: 1, screenHeight: 1,
            horizontal: -100, vertical: 100
        )

        XCTAssertEqual(
            hex(message.encoded()),
            "03" + "00000000" + "00000000" + "0001" + "0001"
            + "8000" + "7FFF" + "00000000"
        )
    }

    func testTextMatchesServerLayout() {
        XCTAssertEqual(hex(ScrcpyControlMessage.text("hi").encoded()), "01" + "00000002" + "6869")
    }

    func testTextIsTruncatedOnUTF8Boundary() {
        let encoded = ScrcpyControlMessage.text(String(repeating: "验", count: 200)).encoded()

        XCTAssertEqual(encoded[0], 0x01)
        let length = Int(encoded[1]) << 24 | Int(encoded[2]) << 16 | Int(encoded[3]) << 8 | Int(encoded[4])
        XCTAssertLessThanOrEqual(length, 300)
        XCTAssertEqual(length % 3, 0, "每个汉字占 3 字节，不能截半个字")
        XCTAssertEqual(encoded.count, 5 + length)
    }

    func testBackOrScreenOnMatchesServerLayout() {
        XCTAssertEqual(hex(ScrcpyControlMessage.backOrScreenOn(action: .down).encoded()), "04" + "00")
    }
}

final class ScrcpyServerCommandTests: XCTestCase {
    func testSocketNameMatchesServer() {
        XCTAssertEqual(ScrcpyServerCommand.socketName(scid: 0xABCD), "scrcpy_0000abcd")
    }

    func testShellArgumentsMatchClient() {
        let arguments = ScrcpyServerCommand.shellArguments(scid: 0xABCD, maxSize: 1920, maxFPS: 60)

        XCTAssertEqual(arguments, [
            "shell",
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            "5.0.1",
            "scid=0000abcd",
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "control=true",
            "cleanup=false",
            "max_size=1920",
            "max_fps=60"
        ])
    }

    /// 服务端会先等控制 socket 连上再发设备名与尺寸，所以控制通道必须显式打开。
    func testEnablesControlChannel() {
        let arguments = ScrcpyServerCommand.shellArguments(scid: 0xABCD)

        XCTAssertTrue(arguments.contains("control=true"))
    }

    /// 服务端默认退出时删掉 `/data/local/tmp/scrcpy-server.jar`，而清理是异步的：
    /// 上一次会话的清理可能晚一步，把下一次刚推上去的 jar 删掉，新服务端起不来。
    /// jar 的生死由我们管，服务端只负责用。
    func testDisablesServerSideJarCleanup() {
        XCTAssertTrue(ScrcpyServerCommand.shellArguments(scid: 0xABCD).contains("cleanup=false"))
    }

    func testPushAndForwardArguments() {
        XCTAssertEqual(
            ScrcpyServerCommand.pushArguments(localJar: URL(fileURLWithPath: "/tmp/scrcpy-server.jar")),
            ["push", "/tmp/scrcpy-server.jar", "/data/local/tmp/scrcpy-server.jar"]
        )
        XCTAssertEqual(
            ScrcpyServerCommand.forwardArguments(port: 27183, scid: 0xABCD),
            ["forward", "tcp:27183", "localabstract:scrcpy_0000abcd"]
        )
        XCTAssertEqual(
            ScrcpyServerCommand.removeForwardArguments(port: 27183),
            ["forward", "--remove", "tcp:27183"]
        )
    }
}

final class H264AnnexBTests: XCTestCase {
    func testSplitsFourByteStartCodes() {
        var data = Data([0, 0, 0, 1, 0x67, 0x42])
        data.append(contentsOf: [0, 0, 0, 1, 0x68, 0xCE])

        XCTAssertEqual(
            H264.splitNALUnits(data),
            [Data([0x67, 0x42]), Data([0x68, 0xCE])]
        )
    }

    func testSplitsThreeByteStartCodes() {
        let data = Data([0, 0, 1, 0x65, 0xAA, 0xBB, 0, 0, 1, 0x41, 0xCC])

        XCTAssertEqual(
            H264.splitNALUnits(data),
            [Data([0x65, 0xAA, 0xBB]), Data([0x41, 0xCC])]
        )
    }

    func testTreatsDataWithoutStartCodeAsSingleNAL() {
        XCTAssertEqual(H264.splitNALUnits(Data([0x65, 0x01])), [Data([0x65, 0x01])])
    }

    func testConvertsToAVCCWithFourByteLengths() {
        let annexB = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68])

        XCTAssertEqual(
            H264.avcc(fromAnnexB: annexB),
            Data([0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 1, 0x68])
        )
    }

    func testFindsSPSAndPPSInConfigPacket() {
        let config = Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E, 0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80])

        let parameterSets = H264.parameterSets(in: config)

        XCTAssertEqual(parameterSets?.sps, Data([0x67, 0x42, 0x00, 0x1E]))
        XCTAssertEqual(parameterSets?.pps, Data([0x68, 0xCE, 0x3C, 0x80]))
    }
}

// MARK: - 夹具

final class FakeByteStream: ByteStream {
    private var bytes: Data
    private(set) var written: [Data] = []
    var closed = false

    init(bytes: Data) {
        self.bytes = bytes
    }

    func readExactly(_ count: Int) throws -> Data {
        guard bytes.count >= count else {
            throw ScrcpyProtocolError.endOfStream
        }
        let chunk = bytes.prefix(count)
        bytes.removeFirst(count)
        return Data(chunk)
    }

    func write(_ data: Data) throws {
        written.append(data)
    }

    func close() {
        closed = true
    }
}

extension Data {
    mutating func appendBE32(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}
