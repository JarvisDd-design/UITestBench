import Foundation

/// 请求一开始就挂住，直到被取消；用来测「清单拉取进行中取消」。
final class HangingURLProtocol: URLProtocol {
    /// 在 `startLoading` 时回调一次（清单会并发拉两份，只通知第一份）。
    static var onStart: (() -> Void)?

    private static let lock = NSLock()
    private static var didNotify = false

    static func reset() {
        lock.lock()
        onStart = nil
        didNotify = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let shouldNotify = !Self.didNotify
        Self.didNotify = true
        let onStart = Self.onStart
        Self.lock.unlock()
        if shouldNotify {
            onStart?()
        }
    }

    override func stopLoading() {}
}
