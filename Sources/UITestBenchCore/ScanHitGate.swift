import Foundation

/// 决定「什么时候算真的扫到了」。
///
/// 单帧误读很常见：视频压缩、运动模糊、码只露出一半都会让某帧读出错误内容。
/// 同一个链接连续出现两帧才命中，既过滤了误读，视觉上也还是「立刻」。
public final class ScanHitGate {
    public struct Configuration: Equatable, Sendable {
        public var requiredConfirmations: Int
        public var confirmationWindow: TimeInterval
        public var notALinkThrottle: TimeInterval

        public init(
            requiredConfirmations: Int = 2,
            confirmationWindow: TimeInterval = 0.35,
            notALinkThrottle: TimeInterval = 1.5
        ) {
            self.requiredConfirmations = requiredConfirmations
            self.confirmationWindow = confirmationWindow
            self.notALinkThrottle = notALinkThrottle
        }
    }

    private let configuration: Configuration
    private var pendingPayload: String?
    private var pendingCount = 0
    private var pendingLastTime: TimeInterval = 0
    private var emitted: Set<String> = []
    private var lastNotALinkTime: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 返回 true 表示这一帧应当触发下载确认。同一个链接一轮扫描只触发一次。
    public func register(link: DownloadLink, at timestamp: TimeInterval) -> Bool {
        let payload = link.url.absoluteString
        guard !emitted.contains(payload) else { return false }

        if pendingPayload == payload,
           timestamp - pendingLastTime <= configuration.confirmationWindow {
            pendingCount += 1
        } else {
            pendingPayload = payload
            pendingCount = 1
        }
        pendingLastTime = timestamp

        guard pendingCount >= configuration.requiredConfirmations else {
            return false
        }

        emitted.insert(payload)
        pendingPayload = nil
        pendingCount = 0
        return true
    }

    /// 这一帧没有任何码：连续计数归零。
    public func registerNoCode() {
        pendingPayload = nil
        pendingCount = 0
    }

    /// 返回 true 表示底部提示应当刷新；同一句话不会每帧闪一次。
    public func registerNotALink(at timestamp: TimeInterval) -> Bool {
        registerNoCode()

        if let last = lastNotALinkTime,
           timestamp - last < configuration.notALinkThrottle {
            return false
        }
        lastNotALinkTime = timestamp
        return true
    }

    public func reset() {
        pendingPayload = nil
        pendingCount = 0
        pendingLastTime = 0
        emitted.removeAll()
        lastNotALinkTime = nil
    }
}
