import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import UITestBenchCore

/// 捕获只需要屏幕的身份和几何信息，不需要 `NSScreen` 对象。
/// 用值类型跨到捕获层，既避免把 AppKit 对象带出主线程，也方便重建流。
struct CaptureScreen: Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScale: CGFloat

    init(_ screen: NSScreen) {
        displayID = screen.displayID
        frame = screen.frame
        backingScale = screen.backingScaleFactor
    }
}

/// 取景框移动后，捕获层给出的结论。
enum CaptureRegionUpdate {
    /// 已生效。
    case applied
    /// 捕获还没启动；`start` 完成后由调用方再对一次位置。
    case deferred
    /// 新区域在另一块屏上，只能停掉当前流再重建。
    case needsRestart
}

/// 捕获层的最小接口。`ScreenScannerModel` 只认这几个动作，
/// 测试与低版本系统都能把它换掉。
protocol ScreenCapturing: AnyObject {
    /// 是否已经收到过至少一帧有效画面。用来看「有权限但没画面」。
    var hasReceivedFrame: Bool { get }
    /// 流是否已经启动。拖动期间启动的捕获要等启动完成后才能计时。
    var isRunning: Bool { get }

    func start(
        region: CaptureRegion,
        screen: CaptureScreen,
        onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws

    /// 取景框移动后调用。同屏只改 `sourceRect`，跨屏交给调用方重建。
    func updateRegion(_ region: CaptureRegion, screen: CaptureScreen) async -> CaptureRegionUpdate

    /// 软暂停：样本回调直接丢弃，流还活着。拖动与命中时用。
    func pause()
    func resume()

    func stop() async
}

/// 只捕获取景框覆盖的那一小块屏幕。
///
/// 12.3 上只有 `SCStream`，`SCScreenshotManager` 是 14 才有的。永远不用
/// 截全屏再裁剪——飞书、浏览器里可能同时有多个二维码，也会白白耗 CPU。
///
/// `start` 要跨多个 `await`，其间用户可能按 Esc、超时或拖动重建。每个
/// 操作都推进 `generation`，在途的启动每到一次 `await` 后都核对代际；
/// 发现自己已经过期就停掉刚建好的流再退出，避免留下无人管理的捕获。
@available(macOS 12.3, *)
final class ScreenRegionCapture: NSObject, ScreenCapturing {
    enum CaptureError: LocalizedError {
        case displayNotFound
        case contentUnavailable(String)
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .displayNotFound:
                return "找不到取景框所在的显示器。"
            case let .contentUnavailable(reason):
                return "拿不到可捕获的屏幕内容：\(reason)"
            case let .startFailed(reason):
                return "屏幕捕获启动失败：\(reason)"
            }
        }
    }

    private let frameQueue = DispatchQueue(
        label: "com.uitestbench.scanner.frames",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var generation = 0
    private var paused = false
    private var receivedFrame = false

    private var stream: SCStream?
    private var display: SCDisplay?
    private var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    private var onFailure: ((Error) -> Void)?

    var hasReceivedFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedFrame
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    func start(
        region: CaptureRegion,
        screen: CaptureScreen,
        onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws {
        let (generation, previousStream) = beginStart(onFrame: onFrame, onFailure: onFailure)

        if let previousStream {
            try? await previousStream.stopCapture()
            try? previousStream.removeStreamOutput(self, type: .screen)
        }
        guard isCurrent(generation) else { throw CancellationError() }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // 权限类错误要原样抛给上层，包装后就认不出 TCC 拒绝了。
            if Self.isPermissionDeclined(error) { throw error }
            throw CaptureError.contentUnavailable(error.localizedDescription)
        }
        guard isCurrent(generation) else { throw CancellationError() }

        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }

        // 把自己的窗口排除在画面之外：取景框虽然透明，但边框和提示会挡住二维码。
        // 主窗口最小化后本应用可能暂时不在可共享列表里，那就只按显示器捕获；
        // 此时自己的窗口已经最小化，不会挡二维码，没必要因此让整次扫描失败。
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = makeConfiguration(region: region)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)

        do {
            try await stream.startCapture()
        } catch {
            try? stream.removeStreamOutput(self, type: .screen)
            if Self.isPermissionDeclined(error) { throw error }
            throw CaptureError.startFailed(error.localizedDescription)
        }

        // 启动期间若被取消、超时或被新一轮扫描顶替，这条流已经没人要了。
        // 校验和登记必须在同一个临界区：否则 stop() 可能正好在两者之间
        // 看到 `stream == nil`，随后这条流被登记进来却再也没人停。
        let accepted = lock.withLock { () -> Bool in
            guard generation == self.generation else { return false }
            self.stream = stream
            self.display = display
            return true
        }
        guard accepted else {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            throw CancellationError()
        }
    }

    func updateRegion(_ region: CaptureRegion, screen: CaptureScreen) async -> CaptureRegionUpdate {
        let (stream, display) = lock.withLock { () -> (SCStream?, SCDisplay?) in
            (self.stream, self.display)
        }

        // 启动还没完成：位置由启动完成后的第一次对齐负责，别把它当成失败。
        guard let stream, let display else { return .deferred }
        guard display.displayID == screen.displayID else { return .needsRestart }

        // 暂停/恢复由模型根据拖动状态决定；这里只改区域，避免迟到的
        // 更新把新一轮拖动重新解暂停。
        do {
            try await stream.updateConfiguration(makeConfiguration(region: region))
            return .applied
        } catch {
            // 旧区域还能继续用；调用方会决定重建还是提示。
            return .needsRestart
        }
    }

    func pause() {
        setPaused(true)
    }

    func resume() {
        setPaused(false)
    }

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            generation += 1
            paused = true
            let current = self.stream
            self.stream = nil
            display = nil
            onFrame = nil
            onFailure = nil
            return current
        }

        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
    }

    // MARK: - 启动与状态

    /// 取得本次启动的代际，并接管上一次的流（由调用方负责停掉）。
    private func beginStart(
        onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> (generation: Int, previousStream: SCStream?) {
        lock.lock()
        defer { lock.unlock() }

        generation += 1
        paused = false
        receivedFrame = false
        self.onFrame = onFrame
        self.onFailure = onFailure

        let previousStream = stream
        stream = nil
        display = nil
        return (generation, previousStream)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { generation == self.generation }
    }

    /// TCC 拒绝在获取内容、启动流两个阶段都可能出现，别包装它。
    private static func isPermissionDeclined(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamError.errorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func makeConfiguration(region: CaptureRegion) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = max(region.pixelWidth, 2)
        configuration.height = max(region.pixelHeight, 2)
        // 10 fps 足够扫码，又把解码和 Vision 的 CPU 压下来。
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 2
        configuration.scalesToFit = false
        return configuration
    }

    private func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    private func setReceivedFrame() {
        lock.lock()
        receivedFrame = true
        lock.unlock()
    }
}

@available(macOS 12.3, *)
extension ScreenRegionCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }

        // 只接受当前这条流的帧。停掉或重建后，旧流的迟到帧不能混进新一轮。
        lock.lock()
        guard !paused, let currentStream = self.stream, currentStream === stream else {
            lock.unlock()
            return
        }
        let handler = onFrame
        lock.unlock()
        guard let handler else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return }

        switch status {
        case .complete, .started:
            break
        case .idle:
            // 画面没变化时仍可能给最后一帧，继续尝试识别；没有图像缓冲区会自然跳过。
            break
        default:
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        setReceivedFrame()

        let timestamp = ProcessInfo.processInfo.systemUptime
        autoreleasepool {
            handler(pixelBuffer, timestamp)
        }
    }
}

@available(macOS 12.3, *)
extension ScreenRegionCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        // 正常 stop / 重建也会触发停止回调；只处理当前这条流的意外中断。
        guard let currentStream = self.stream, currentStream === stream else {
            lock.unlock()
            return
        }
        self.stream = nil
        display = nil
        paused = true
        generation += 1
        let failure = onFailure
        onFrame = nil
        onFailure = nil
        lock.unlock()

        failure?(error)
    }
}

extension NSScreen {
    /// ScreenCaptureKit 用 `CGDirectDisplayID` 认屏，不是 `NSScreen` 对象。
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

private extension NSLock {
    /// 让「加锁读一个值」不必在主路径上写 defer。
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
