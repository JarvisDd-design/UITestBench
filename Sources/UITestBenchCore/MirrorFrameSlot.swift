import CoreMedia
import Foundation

/// 只留最新一帧的显示槽位。
///
/// 解码线程往槽里写，显示线程从槽里取；写永远不阻塞，槽里已经有一帧就直接覆盖。
/// 这是官方 scrcpy 客户端的做法：解码跟不上时宁可少显示几帧，也不能让帧排队
/// 等下去——排队意味着延迟随时间累积，手感会越来越「不跟手」。
public final class MirrorFrameSlot {
    public struct Entry {
        public let sample: CMSampleBuffer
        /// 这一帧解码完成的时刻（`ProcessInfo.systemUptime` 口径的秒）。
        public let arrival: TimeInterval

        public init(sample: CMSampleBuffer, arrival: TimeInterval) {
            self.sample = sample
            self.arrival = arrival
        }
    }

    private let lock = NSCondition()
    private var entry: Entry?
    private var dropped = 0

    public init() {}

    /// 存一帧。返回 true 表示覆盖掉了还没被取走的旧帧（也就是丢了一帧）。
    @discardableResult
    public func store(
        _ sample: CMSampleBuffer,
        arrival: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let replaced = entry != nil
        if replaced { dropped += 1 }
        entry = Entry(sample: sample, arrival: arrival)
        lock.broadcast()
        return replaced
    }

    /// 取走当前帧并清空槽位；没有帧返回 nil。
    public func take() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        let taken = entry
        entry = nil
        return taken
    }

    /// 等一帧到货，最多等 `timeout` 秒。
    ///
    /// 显示层空闲时用它代替空转轮询：来了新帧立刻返回，没来就等到超时。
    public func waitForEntry(timeout: TimeInterval) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        if entry == nil {
            _ = lock.wait(until: Date(timeIntervalSinceNow: timeout))
        }
        let taken = entry
        entry = nil
        return taken
    }

    /// 丢掉槽里的帧，用于停止、重连这类场景；不计入丢帧数。
    public func flush() {
        lock.lock()
        entry = nil
        lock.unlock()
    }

    public var isOccupied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entry != nil
    }

    /// 因覆盖丢掉的帧数。显示层一直追不上时这个数会持续涨，HUD 靠它判断。
    public var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func resetDroppedFrameCount() {
        lock.lock()
        dropped = 0
        lock.unlock()
    }
}
