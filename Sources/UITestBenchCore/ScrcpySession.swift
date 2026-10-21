import Foundation

public struct ScrcpySessionConfiguration: Equatable, Sendable {
    public var scid: UInt32
    public var videoPort: Int
    public var controlPort: Int
    public var maxSize: Int
    public var maxFPS: Int
    /// 服务端是异步起来的：`adb forward` 会先接住连接，设备端还没监听时立刻断开。
    /// 在这段时间里反复重连，直到握手读成功或超时。
    public var connectTimeout: TimeInterval
    public var retryInterval: TimeInterval

    public init(
        scid: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF),
        videoPort: Int = 27183,
        controlPort: Int = 27184,
        maxSize: Int = 1920,
        maxFPS: Int = 60,
        connectTimeout: TimeInterval = 10,
        retryInterval: TimeInterval = 0.1
    ) {
        // 服务端用 `Integer.parseInt(scid, 16)` 解析这个值：最高位为 1 时会抛
        // `NumberFormatException`，整个服务端进程直接退出。只发 31 位。
        self.scid = min(scid, 0x7FFF_FFFF)
        self.videoPort = videoPort
        self.controlPort = controlPort
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.connectTimeout = connectTimeout
        self.retryInterval = retryInterval
    }
}

public enum ScrcpySessionError: Error, Equatable {
    case pushFailed(String)
    case forwardFailed(String)
    case launchFailed(String)
    case notStarted
}

public protocol SocketConnecting: Sendable {
    func connect(port: UInt16, timeout: TimeInterval) throws -> ByteStream
}

public struct LocalSocketConnector: SocketConnecting {
    public init() {}

    public func connect(port: UInt16, timeout: TimeInterval) throws -> ByteStream {
        try SocketByteStream.connect(port: port, timeout: timeout)
    }
}

/// 负责把 scrcpy 服务端推到设备上、开端口转发、拉起进程、连视频 socket。
/// 视频与控制两个 channel 都归它管，`stop()` 一次收干净。
public final class ScrcpySession {
    public let adb: URL
    public let jar: URL
    public let serial: String
    public let configuration: ScrcpySessionConfiguration

    private let runner: CommandRunning
    private let launcher: ProcessLaunching
    private let connector: SocketConnecting

    private var serverHandle: BackgroundProcessHandle?
    private var videoStream: ByteStream?
    private var controlStream: ByteStream?
    private var hasForwards = false

    public private(set) var handshake: ScrcpyVideoHandshake?

    public init(
        adb: URL,
        jar: URL,
        serial: String,
        configuration: ScrcpySessionConfiguration = ScrcpySessionConfiguration(),
        runner: CommandRunning = ProcessCommandRunner(),
        launcher: ProcessLaunching = ProcessLauncher(),
        connector: SocketConnecting = LocalSocketConnector()
    ) {
        self.adb = adb
        self.jar = jar
        self.serial = serial
        self.configuration = configuration
        self.runner = runner
        self.launcher = launcher
        self.connector = connector
    }

    /// 推送 → 两条端口转发 → 拉起服务端 → 连视频 socket → 读握手。
    public func start() async throws -> ScrcpyVideoHandshake {
        if let handshake {
            return handshake
        }

        let push = try await runner.run(
            adb,
            ["-s", serial] + ScrcpyServerCommand.pushArguments(localJar: jar)
        )
        guard push.status == 0 else {
            throw ScrcpySessionError.pushFailed(Self.message(from: push.output))
        }

        for port in [configuration.videoPort, configuration.controlPort] {
            let result = try await runner.run(
                adb,
                ["-s", serial] + ScrcpyServerCommand.forwardArguments(
                    port: port,
                    scid: configuration.scid
                )
            )
            guard result.status == 0 else {
                await removeForwards()
                throw ScrcpySessionError.forwardFailed(Self.message(from: result.output))
            }
            hasForwards = true
        }

        do {
            serverHandle = try launcher.launch(
                executable: adb,
                arguments: ["-s", serial] + ScrcpyServerCommand.shellArguments(
                    scid: configuration.scid,
                    maxSize: configuration.maxSize,
                    maxFPS: configuration.maxFPS
                )
            )
        } catch {
            await removeForwards()
            throw ScrcpySessionError.launchFailed(String(describing: error))
        }

        do {
            let result = try await connectChannelsAndReadHandshake()
            handshake = result
            return result
        } catch {
            await stop()
            throw error
        }
    }

    /// 反复连，直到握手读完或超时。服务端刚被拉起时，端口转发已经能接受 TCP，
    /// 但设备端 socket 还没监听，此时读到的只有 EOF——这是正常现象，不是故障。
    ///
    /// 顺序不能换：服务端先等控制 socket 连上，之后才往视频 socket 写设备名与尺寸。
    /// 只连视频不连控制，就会一直卡在握手超时。
    private func connectChannelsAndReadHandshake() async throws -> ScrcpyVideoHandshake {
        let deadline = Date().addingTimeInterval(configuration.connectTimeout)
        while true {
            var video: ByteStream?
            var control: ByteStream?
            do {
                video = try connector.connect(
                    port: UInt16(configuration.videoPort),
                    timeout: 5
                )
                control = try connector.connect(
                    port: UInt16(configuration.controlPort),
                    timeout: 5
                )
                let result = try ScrcpyVideoHandshake.read(from: video!)
                videoStream = video
                controlStream = control
                return result
            } catch {
                video?.close()
                control?.close()
                if Date() >= deadline || Task.isCancelled {
                    throw error
                }
                if configuration.retryInterval > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(configuration.retryInterval * 1_000_000_000)
                    )
                }
            }
        }
    }

    /// 握手已经从视频 socket 上读走了，读取器从这里接着读媒体包。
    public func videoReader() throws -> ScrcpyVideoReader {
        guard let videoStream else {
            throw ScrcpySessionError.notStarted
        }
        return ScrcpyVideoReader(stream: videoStream)
    }

    /// 控制 socket 没有握手，连上就能写。
    public func openControlChannel() throws -> ByteStream {
        guard videoStream != nil else {
            throw ScrcpySessionError.notStarted
        }
        if let controlStream {
            return controlStream
        }
        let stream = try connector.connect(port: UInt16(configuration.controlPort), timeout: 5)
        controlStream = stream
        return stream
    }

    public func stop() async {
        videoStream?.close()
        videoStream = nil
        controlStream?.close()
        controlStream = nil
        serverHandle?.terminate()
        serverHandle = nil
        handshake = nil

        if hasForwards {
            hasForwards = false
            await removeForwards()
        }
    }

    private func removeForwards() async {
        for port in [configuration.videoPort, configuration.controlPort] {
            _ = try? await runner.run(
                adb,
                ["-s", serial] + ScrcpyServerCommand.removeForwardArguments(port: port)
            )
        }
    }

    private static func message(from output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
