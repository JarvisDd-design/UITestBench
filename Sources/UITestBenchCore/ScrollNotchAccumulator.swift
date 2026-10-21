import CoreGraphics

/// 把滚轮与触控板的增量攒成离散的轮齿。
///
/// 触控板给的是像素级、带惯性的一长串小增量；来一条发一条，设备那边会收到几百个
/// 滚动消息。这里攒够一格才放行一个轮齿：正数向上、负数向下，与 scrcpy 的约定一致。
public struct ScrollNotchAccumulator {
    /// 攒够这么多点算一格。触控板一格大约这个量级，偏小会让滚动发飘。
    public static let pointsPerNotch: CGFloat = 30

    private var pending: CGFloat = 0

    public init() {}

    /// 返回本次应当发出的轮齿数；返回 0 表示还没攒够，不要发消息。
    public mutating func notches(delta: CGFloat, isPrecise: Bool) -> Int {
        guard isPrecise else {
            // 普通鼠标本来就是整格。
            return Int(delta.rounded())
        }

        pending += delta
        // 向零取整：攒了 0.9 格还没到一格，反向攒了 0.9 格也一样。
        let notches = Int((pending / Self.pointsPerNotch).rounded(.towardZero))
        if notches != 0 {
            // 只扣掉整格，余量留到下一次，否则慢慢滚会「丢格」。
            pending -= CGFloat(notches) * Self.pointsPerNotch
        }
        return notches
    }

    /// 手停下来时调用：把没攒满一格的零头也放出去。
    ///
    /// 慢慢滚的时候，一次增量可能只有几个点，照「攒满才发」的规则永远轮不到——
    /// 用户看到的就是「滚不动」。停下来后至少补一格，动作才有反馈。
    /// `minimumPoints` 以下的位移视为抖动，不发。
    public mutating func flush(minimumPoints: CGFloat = 3) -> Int {
        guard abs(pending) >= minimumPoints else {
            pending = 0
            return 0
        }
        var notches = Int((pending / Self.pointsPerNotch).rounded(.towardZero))
        if notches == 0 {
            notches = pending > 0 ? 1 : -1
        }
        pending = 0
        return notches
    }
}
