import XCTest
@testable import UITestBenchCore

final class ScrcpySessionTests: XCTestCase {
    private let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")
    private let jar = URL(fileURLWithPath: "/app/scrcpy-server.jar")
    private let serial = "emulator-5554"

    private func makeSession(
        runner: FakeCommandRunner,
        launcher: FakeProcessLauncher,
        connector: FakeSocketConnector,
        configuration: ScrcpySessionConfiguration = ScrcpySessionConfiguration(scid: 0xABCD)
    ) -> ScrcpySession {
        ScrcpySession(
            adb: adb,
            jar: jar,
            serial: serial,
            configuration: configuration,
            runner: runner,
            launcher: launcher,
            connector: connector
        )
    }

    /// `adb forward` 会先接住 TCP 连接，设备端的服务还没监听时立刻断开——
    /// 这时读握手只能读到 EOF。真实 scrcpy 客户端会重连，我们也必须等。
    /// 每条连接都是「先视频、后控制」，控制通道开了才会读到握手。
    func testStartRetriesWhenDeviceServerIsNotListeningYet() async throws {
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: Data()),
            FakeByteStream(bytes: Data()),
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7")),
            FakeByteStream(bytes: Data())
        ])
        let session = makeSession(
            runner: FakeCommandRunner(),
            launcher: FakeProcessLauncher(),
            connector: connector,
            configuration: ScrcpySessionConfiguration(
                scid: 0xABCD,
                connectTimeout: 1,
                retryInterval: 0.01
            )
        )

        let handshake = try await session.start()

        XCTAssertEqual(handshake.deviceName, "Pixel 7")
        XCTAssertEqual(connector.requestedPorts, [27183, 27184, 27183, 27184])
    }

    /// 服务端用 `Integer.parseInt(scid, 16)` 解析 scid，最高位是 1 时直接抛
    /// `NumberFormatException`，进程根本起不来。随机 scid 必须限制在 31 位。
    func testScidNeverExceedsTheServersSignedIntParse() {
        XCTAssertEqual(ScrcpySessionConfiguration(scid: 0x8000_0000).scid, 0x7FFF_FFFF)
        XCTAssertEqual(ScrcpySessionConfiguration(scid: 0xFFFF_FFFF).scid, 0x7FFF_FFFF)
        XCTAssertEqual(ScrcpySessionConfiguration(scid: 0xABCD).scid, 0xABCD)

        for _ in 0..<200 {
            let scid = ScrcpySessionConfiguration().scid
            XCTAssertTrue((1...0x7FFF_FFFF).contains(scid), "默认 scid 越界：\(scid)")
        }
    }

    func testStartGivesUpAfterConnectTimeoutAndCleansUp() async {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let session = makeSession(
            runner: runner,
            launcher: launcher,
            connector: FakeSocketConnector(streams: []),
            configuration: ScrcpySessionConfiguration(
                scid: 0xABCD,
                connectTimeout: 0.05,
                retryInterval: 0.01
            )
        )

        do {
            _ = try await session.start()
            XCTFail("服务端一直连不上应当失败")
        } catch {
            XCTAssertTrue(error is SocketError, "应当把连接错误原样抛出：\(error)")
        }
        XCTAssertTrue(launcher.handle.terminateCalled)
        let calls = await runner.calls
        XCTAssertEqual(Array(calls.suffix(2).map(\.arguments)), [
            ["-s", serial, "forward", "--remove", "tcp:27183"],
            ["-s", serial, "forward", "--remove", "tcp:27184"]
        ])
    }

    func testStartPushesForwardsLaunchesAndReadsHandshake() async throws {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7")),
            FakeByteStream(bytes: Data())
        ])
        let session = makeSession(runner: runner, launcher: launcher, connector: connector)

        let handshake = try await session.start()

        XCTAssertEqual(handshake.deviceName, "Pixel 7")
        XCTAssertEqual(handshake.session, ScrcpySessionHeader(width: 1080, height: 2400, clientResized: false))

        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [
            ["-s", serial, "push", jar.path, "/data/local/tmp/scrcpy-server.jar"],
            ["-s", serial, "forward", "tcp:27183", "localabstract:scrcpy_0000abcd"],
            ["-s", serial, "forward", "tcp:27184", "localabstract:scrcpy_0000abcd"]
        ])
        XCTAssertEqual(calls[0].executable, adb)

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].executable, adb)
        XCTAssertEqual(
            launcher.launches[0].arguments,
            ["-s", serial] + ScrcpyServerCommand.shellArguments(scid: 0xABCD, maxSize: 1920, maxFPS: 60)
        )

        XCTAssertEqual(connector.requestedPorts, [27183, 27184])
    }

    func testStartFailsWithoutLaunchingWhenPushFails() async {
        let runner = FakeCommandRunner(defaultOutput: "adb: device offline", status: 1)
        let launcher = FakeProcessLauncher()
        let connector = FakeSocketConnector(streams: [])
        let session = makeSession(runner: runner, launcher: launcher, connector: connector)

        do {
            _ = try await session.start()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? ScrcpySessionError, .pushFailed("adb: device offline"))
        }
        XCTAssertTrue(launcher.launches.isEmpty, "推送失败就不该启动服务端")
        XCTAssertTrue(connector.requestedPorts.isEmpty)
    }

    func testStartTwiceReusesRunningSession() async throws {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7")),
            FakeByteStream(bytes: Data())
        ])
        let session = makeSession(runner: runner, launcher: launcher, connector: connector)

        _ = try await session.start()
        let second = try await session.start()

        XCTAssertEqual(second.deviceName, "Pixel 7")
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(connector.requestedPorts, [27183, 27184])
    }

    /// 服务端会先等控制 socket 连上，再发设备名与尺寸；控制通道必须在读握手之前打开，
    /// 否则客户端会一直卡在握手超时。
    func testControlChannelIsOpenBeforeHandshakeIsRead() async throws {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let control = FakeByteStream(bytes: Data())
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7")),
            control
        ])
        let session = makeSession(runner: runner, launcher: launcher, connector: connector)

        _ = try await session.start()

        XCTAssertEqual(connector.requestedPorts, [27183, 27184])
        let stream = try session.openControlChannel()
        try stream.write(ScrcpyControlMessage.backOrScreenOn(action: .down).encoded())
        XCTAssertEqual(control.written, [Data([4, 0])], "控制通道应在 start() 里连好并复用")
    }

    /// 控制通道连不上时不能装死：整个会话要收干净再报错。
    func testStartFailsAndCleansUpWhenControlChannelCannotConnect() async {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7"))
        ])
        let session = makeSession(
            runner: runner,
            launcher: launcher,
            connector: connector,
            configuration: ScrcpySessionConfiguration(
                scid: 0xABCD,
                connectTimeout: 0.05,
                retryInterval: 0.01
            )
        )

        do {
            _ = try await session.start()
            XCTFail("控制通道连不上应当失败")
        } catch {
            XCTAssertTrue(error is SocketError)
        }
        XCTAssertTrue(launcher.handle.terminateCalled)
        let calls = await runner.calls
        XCTAssertEqual(Array(calls.suffix(2).map(\.arguments)), [
            ["-s", serial, "forward", "--remove", "tcp:27183"],
            ["-s", serial, "forward", "--remove", "tcp:27184"]
        ])
    }

    func testOpenControlChannelBeforeStartFails() {
        let session = makeSession(
            runner: FakeCommandRunner(),
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [])
        )

        XCTAssertThrowsError(try session.openControlChannel()) { error in
            XCTAssertEqual(error as? ScrcpySessionError, .notStarted)
        }
    }

    func testStopTerminatesServerAndRemovesForwards() async throws {
        let runner = FakeCommandRunner()
        let launcher = FakeProcessLauncher()
        let connector = FakeSocketConnector(streams: [
            FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7")),
            FakeByteStream(bytes: Data())
        ])
        let session = makeSession(runner: runner, launcher: launcher, connector: connector)
        _ = try await session.start()

        await session.stop()

        XCTAssertTrue(launcher.handle.terminateCalled)
        let calls = await runner.calls
        XCTAssertEqual(Array(calls.suffix(2).map(\.arguments)), [
            ["-s", serial, "forward", "--remove", "tcp:27183"],
            ["-s", serial, "forward", "--remove", "tcp:27184"]
        ])
    }

    func testStopIsSafeBeforeStart() async {
        let runner = FakeCommandRunner()
        let session = makeSession(
            runner: runner,
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [])
        )

        await session.stop()

        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testVideoReaderBeforeStartFails() {
        let session = makeSession(
            runner: FakeCommandRunner(),
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [])
        )

        XCTAssertThrowsError(try session.videoReader()) { error in
            XCTAssertEqual(error as? ScrcpySessionError, .notStarted)
        }
    }

    func testVideoReaderContinuesFromWhereHandshakeEnded() async throws {
        let tail = Data([0x80, 0, 0, 0, 0, 0, 0x04, 0x38, 0, 0, 0x09, 0x60])
        let stream = FakeByteStream(bytes: handshakeBytes(deviceName: "Pixel 7") + tail)
        let session = makeSession(
            runner: FakeCommandRunner(),
            launcher: FakeProcessLauncher(),
            connector: FakeSocketConnector(streams: [stream, FakeByteStream(bytes: Data())])
        )
        _ = try await session.start()

        let event = try session.videoReader().nextEvent()

        guard case let .session(header)? = event else {
            return XCTFail("应当读到会话包，实际 \(String(describing: event))")
        }
        XCTAssertEqual(header, ScrcpySessionHeader(width: 1080, height: 2400, clientResized: false))
    }

    private func handshakeBytes(deviceName: String) -> Data {
        var bytes = Data([0x00])
        var name = Data(deviceName.utf8)
        name.append(Data(repeating: 0, count: ScrcpyProtocol.deviceNameLength - name.count))
        bytes.append(name)
        bytes.appendBE32(ScrcpyProtocol.codecIDH264)
        var session = Data([0x80, 0, 0, 0])
        session.appendBE32(1080)
        session.appendBE32(2400)
        bytes.append(session)
        return bytes
    }
}

final class FakeSocketConnector: SocketConnecting, @unchecked Sendable {
    private var streams: [ByteStream]
    private(set) var requestedPorts: [Int] = []
    var error: Error?

    init(streams: [ByteStream]) {
        self.streams = streams
    }

    func connect(port: UInt16, timeout: TimeInterval) throws -> ByteStream {
        requestedPorts.append(Int(port))
        if let error { throw error }
        guard !streams.isEmpty else {
            throw SocketError.connectFailed("没有可用的假连接")
        }
        return streams.removeFirst()
    }
}
