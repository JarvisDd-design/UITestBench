import XCTest
import CoreMedia
@testable import UITestBenchCore

final class ScrcpyMirrorSourceTests: XCTestCase {
    private let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")
    private let jar = URL(fileURLWithPath: "/app/scrcpy-server.jar")
    private let serial = "emulator-5554"

    func testStartReportsDeviceSizeAndPumpsFirstFrame() async throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let runner = FakeCommandRunner()
        let session = ScrcpySession(
            adb: adb,
            jar: jar,
            serial: serial,
            configuration: ScrcpySessionConfiguration(scid: 0xABCD),
            runner: runner,
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [
                FakeByteStream(bytes: handshakeBytes() + videoBytes(encoded: encoded)),
                FakeByteStream(bytes: Data())
            ])
        )
        let source = ScrcpyMirrorSource(session: session)

        let size = try await source.start()
        let frame = try source.nextFrame()

        XCTAssertEqual(size, MirrorVideoSize(width: 1080, height: 2400))
        XCTAssertEqual(frame?.width, 320)
        XCTAssertEqual(frame?.height, 240)
        XCTAssertEqual(frame?.pts, CMTime(value: 1_000, timescale: 1_000_000))
        XCTAssertNil(try source.nextFrame())
    }

    func testStopTearsDownTheSession() async throws {
        let encoded = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let session = ScrcpySession(
            adb: adb,
            jar: jar,
            serial: serial,
            configuration: ScrcpySessionConfiguration(scid: 0xABCD),
            runner: runner,
            launcher: launcher,
            connector: FakeSocketConnector(streams: [
                FakeByteStream(bytes: handshakeBytes() + videoBytes(encoded: encoded)),
                FakeByteStream(bytes: Data())
            ])
        )
        let source = ScrcpyMirrorSource(session: session)
        _ = try await source.start()

        await source.stop()

        XCTAssertTrue(launcher.handle.terminateCalled)
        let calls = await runner.calls
        XCTAssertEqual(Array(calls.suffix(2).map(\.arguments)), [
            ["-s", serial, "forward", "--remove", "tcp:27183"],
            ["-s", serial, "forward", "--remove", "tcp:27184"]
        ])
    }

    /// 断流后重连 = 换一条新连接重新握手。旧服务端与端口转发要收干净，新会话要从头播。
    func testRestartReconnectsAndPumpsFromNewSession() async throws {
        let first = try H264TestData.encodeSolidFrame(width: 320, height: 240)
        let second = try H264TestData.encodeSolidFrame(width: 240, height: 320)
        let runner = FakeCommandRunner()
        let session = ScrcpySession(
            adb: adb,
            jar: jar,
            serial: serial,
            configuration: ScrcpySessionConfiguration(scid: 0xABCD),
            runner: runner,
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [
                FakeByteStream(bytes: handshakeBytes() + videoBytes(encoded: first)),
                FakeByteStream(bytes: Data()),
                FakeByteStream(bytes: handshakeBytes(width: 2400, height: 1080) + videoBytes(encoded: second)),
                FakeByteStream(bytes: Data())
            ])
        )
        let source = ScrcpyMirrorSource(session: session)
        _ = try await source.start()
        XCTAssertEqual(try source.nextFrame()?.width, 320)
        XCTAssertNil(try source.nextFrame())

        let size = try await source.restart()

        XCTAssertEqual(size, MirrorVideoSize(width: 2400, height: 1080))
        let frame = try XCTUnwrap(try source.nextFrame())
        XCTAssertEqual([frame.width, frame.height], [240, 320])
        XCTAssertNil(try source.nextFrame())
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.arguments.contains("push") }.count, 2, "重连要重新推一次服务端")
    }

    private func handshakeBytes(width: UInt32 = 1080, height: UInt32 = 2400) -> Data {
        var bytes = Data([0x00])
        bytes.append(Data(repeating: 0, count: ScrcpyProtocol.deviceNameLength))
        bytes.appendBE32(ScrcpyProtocol.codecIDH264)
        bytes.append(Data([0x80, 0, 0, 0]))
        bytes.appendBE32(width)
        bytes.appendBE32(height)
        return bytes
    }

    private func videoBytes(encoded: H264TestData.Encoded) -> Data {
        var bytes = Data()
        let config = H264TestData.annexBParameterSets(sps: encoded.sps, pps: encoded.pps)
        bytes.append(mediaHeader(pts: 0, config: true, size: config.count))
        bytes.append(config)
        bytes.append(mediaHeader(pts: 1_000, config: false, size: encoded.annexB.count))
        bytes.append(encoded.annexB)
        return bytes
    }

    private func mediaHeader(pts: UInt64, config: Bool, size: Int) -> Data {
        var flags = pts
        if config { flags |= UInt64(1) << 62 } else { flags |= UInt64(1) << 61 }
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((flags >> UInt64(shift)) & 0xFF))
        }
        data.appendBE32(UInt32(size))
        return data
    }
}
