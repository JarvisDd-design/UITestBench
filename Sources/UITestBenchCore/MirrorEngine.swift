import Foundation
import CoreMedia

public struct MirrorVideoSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum MirrorState: Equatable, Sendable {
    case idle
    case starting
    case streaming(width: Int, height: Int)
    case ended
    case failed(String)
}

/// 可替换的画面来源。真实现是 scrcpy，降级方案可以换成别的来源，
/// 引擎与界面都不动。
public protocol MirrorFrameSource: AnyObject {
    func start() async throws -> MirrorVideoSize
    func nextFrame() throws -> DecodedFrame?
    func stop() async
}

/// 断流后能自己重建的来源（scrcpy 重连就是换一条新会话）。引擎见到它才会重试。
public protocol MirrorRecoveringFrameSource: MirrorFrameSource {
    /// 重新拉起来源，返回新会话的画面尺寸。重复失败由引擎限制次数。
    func restart() async throws -> MirrorVideoSize
}

/// 把「读一帧 → 解码 → 包成 CMSampleBuffer」串起来，跑在后台队列上。
///
/// `onFrame` 在读取线程上调用（显示层入队是线程安全的）；
/// `onState` 也在发生线程上同步调用，由界面侧自己切回主线程。
public final class MirrorEngine {
    public typealias SampleBufferFactory = (DecodedFrame) throws -> CMSampleBuffer

    private let source: MirrorFrameSource
    private let makeSampleBuffer: SampleBufferFactory
    private let onFrame: (CMSampleBuffer) -> Void
    private let onState: (MirrorState) -> Void
    private let queue: DispatchQueue
    private let maxReconnectAttempts: Int
    private let reconnectDelay: TimeInterval

    private let lock = NSLock()
    private var stopRequested = false
    private var sourceStopped = false
    private var running = false
    /// 只在开始与镜像队列上读写；队列启动前已由 `start()` 赋值。
    private var currentSize: MirrorVideoSize?

    public init(
        source: MirrorFrameSource,
        makeSampleBuffer: @escaping SampleBufferFactory = VideoSampleBuffer.make,
        queue: DispatchQueue = DispatchQueue(label: "com.uitestbench.mirror"),
        maxReconnectAttempts: Int = 3,
        reconnectDelay: TimeInterval = 0.5,
        onFrame: @escaping (CMSampleBuffer) -> Void,
        onState: @escaping (MirrorState) -> Void
    ) {
        self.source = source
        self.makeSampleBuffer = makeSampleBuffer
        self.queue = queue
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
        self.onFrame = onFrame
        self.onState = onState
    }

    public func start() async throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        stopRequested = false
        sourceStopped = false
        lock.unlock()

        onState(.starting)
        let size: MirrorVideoSize
        do {
            size = try await source.start()
        } catch {
            await stopSourceOnce()
            running = false
            onState(.failed(Self.message(for: error)))
            throw error
        }

        currentSize = size
        onState(.streaming(width: size.width, height: size.height))
        queue.async { [weak self] in
            self?.runLoop()
        }
    }

    public func stop() async {
        lock.lock()
        stopRequested = true
        lock.unlock()
        await stopSourceOnce()
    }

    private enum RecoveryOutcome {
        case recovered
        case retry
        case giveUp(Error?)
        case notRecoverable
    }

    private func runLoop() {
        defer { finish() }

        var attempts = 0
        var lastError: Error?

        while !isStopRequested {
            do {
                guard let frame = try source.nextFrame() else {
                    if isStopRequested { return }
                    switch recover(attempts: &attempts, lastError: &lastError) {
                    case .recovered, .retry:
                        continue
                    case .giveUp(let error):
                        if let error {
                            onState(.failed(Self.reconnectMessage(for: error)))
                        } else {
                            onState(.ended)
                        }
                        return
                    case .notRecoverable:
                        onState(.ended)
                        return
                    }
                }

                // 转屏后解码出来的宽高会变；界面靠这个状态换长宽比。
                if frame.width != currentSize?.width || frame.height != currentSize?.height {
                    let size = MirrorVideoSize(width: frame.width, height: frame.height)
                    currentSize = size
                    onState(.streaming(width: size.width, height: size.height))
                }
                onFrame(try makeSampleBuffer(frame))
            } catch {
                if isStopRequested { return }
                switch recover(attempts: &attempts, lastError: &lastError) {
                case .recovered, .retry:
                    continue
                case .giveUp(let recoveryError):
                    if let recoveryError {
                        onState(.failed(Self.reconnectMessage(for: recoveryError)))
                    } else {
                        onState(.failed(Self.message(for: error)))
                    }
                    return
                case .notRecoverable:
                    onState(.failed(Self.message(for: error)))
                    return
                }
            }
        }
    }

    private func recover(attempts: inout Int, lastError: inout Error?) -> RecoveryOutcome {
        guard let recovering = source as? MirrorRecoveringFrameSource else {
            return .notRecoverable
        }
        guard attempts < maxReconnectAttempts else {
            return .giveUp(lastError)
        }
        attempts += 1

        if reconnectDelay > 0 {
            Thread.sleep(forTimeInterval: reconnectDelay)
        }

        switch runRestart(recovering) {
        case .success(let size):
            if size != currentSize {
                currentSize = size
                onState(.streaming(width: size.width, height: size.height))
            }
            return .recovered
        case .failure(let error):
            lastError = error
            return .retry
        }
    }

    /// 把异步的 `restart()` 等成同步结果。镜像线程阻塞在这里是安全的：
    /// 重连期间本来就没有帧，也不需要让它去处理别的事。
    private func runRestart(_ source: MirrorRecoveringFrameSource) -> Result<MirrorVideoSize, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do {
                box.value = .success(try await source.restart())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .failure(ScrcpySessionError.notStarted)
    }

    private func finish() {
        lock.lock()
        running = false
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.stopSourceOnce()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func stopSourceOnce() async {
        lock.lock()
        let alreadyStopped = sourceStopped
        sourceStopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        await source.stop()
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }

    private static func reconnectMessage(for error: Error) -> String {
        "画面中断后重连失败：\(message(for: error))"
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<MirrorVideoSize, Error>?

    var value: Result<MirrorVideoSize, Error>? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
