import CoreGraphics
import Foundation

/// 用短拖动代替滚轮消息。
///
/// 为什么不用 `INJECT_SCROLL_EVENT`：在 Android 14 AOSP 镜像上实测，滚动消息确实注入了
/// （`dumpsys input` 的 RecentQueue 里能看到 `action=SCROLL`、坐标正确、没有被丢弃），
/// 但应用层不响应；同一个坐标换成触摸拖动立刻生效。滚轮是必须能用的功能，所以走这条
/// 一定能工作的路：按下 → 挪几步 → 抬起。
///
/// 为什么要有节拍：一开始这几步是连着写出去的，所有移动事件落在同一毫秒里，系统把它
/// 算成一次极快的甩动——实测滚一格，列表走了将近 2000 px（意图是 125 px）。所以每步
/// 之间留出间隔，并在抬手前停一下：最近 100 ms 没有位移，算出来的甩动速度就是 0。
///
/// 手势在串行队列上执行，不阻塞主线程；两段手势也不会交错（系统会当成两根手指）。
public final class DragScrollSink: MirrorInputSink {
    /// 一格滚轮换算成多少画面像素。参照 Android 列表项的高度，太少会被当成点击。
    public static let pointsPerNotch: CGFloat = 100

    /// 一次手势拆成几步移动。太少像瞬移，太多没必要。
    public static let steps = 6

    /// 每步之间的间隔。一格大约走 1000 px/s，接近人手指的速度。
    public static let defaultStepInterval: TimeInterval = 0.012

    /// 抬手前的停顿。这段时间里没有位移，系统算出的甩动速度趋近 0。
    public static let defaultSettleInterval: TimeInterval = 0.12

    private let base: MirrorInputSink
    private let queue: DispatchQueue
    private let stepInterval: TimeInterval
    private let settleInterval: TimeInterval

    /// 只由调用方（主线程）读写；手势参数在入队前就算好，队列里不碰这两个值。
    private var screenWidth = 0
    private var screenHeight = 0

    /// 还没走完的滚动位移（画面像素，正数向上滚）。触控板一划会连着来十几个
    /// 轮齿，每个轮齿单排一段约 0.2 秒的手势会让队列积压好几秒——用户早停手了
    /// 画面还在滚。攒在一起，一段手势走完。
    private let lock = NSLock()
    private var pendingDistance: CGFloat = 0
    private var pendingPoint: CGPoint = .zero
    private var pendingScreenHeight: CGFloat = 0
    /// 队列上是否已经有一个 drain 在跑；跑着的时候新滚动只往 pending 里加。
    private var isDraining = false

    public init(
        base: MirrorInputSink,
        queue: DispatchQueue = DispatchQueue(label: "com.uitestbench.drag-scroll"),
        stepInterval: TimeInterval = DragScrollSink.defaultStepInterval,
        settleInterval: TimeInterval = DragScrollSink.defaultSettleInterval
    ) {
        self.base = base
        self.queue = queue
        self.stepInterval = stepInterval
        self.settleInterval = settleInterval
    }

    public func updateScreenSize(width: Int, height: Int) {
        screenWidth = width
        screenHeight = height
        base.updateScreenSize(width: width, height: height)
    }

    public func touchDown(at point: CGPoint) throws {
        try base.touchDown(at: point)
    }

    public func touchMove(to point: CGPoint) throws {
        try base.touchMove(to: point)
    }

    public func touchUp(at point: CGPoint) throws {
        try base.touchUp(at: point)
    }

    public func tap(at point: CGPoint) throws {
        try base.tap(at: point)
    }

    public func pressKey(_ key: AndroidKey) throws {
        try base.pressKey(key)
    }

    public func sendText(_ text: String) throws {
        try base.sendText(text)
    }

    /// 正数向上滚（内容往下走）→ 手指往下拖；负数相反。
    ///
    /// 只把位移攒起来，由队列上的 drain 合并成手势：一批滚动一段手势，
    /// 而不是一个轮齿一段。
    public func scroll(at point: CGPoint, horizontal: Int, vertical: Int) throws {
        guard vertical != 0 else {
            // 只有横向滚动时没有可用的手势替代，原样交给下层。
            try base.scroll(at: point, horizontal: horizontal, vertical: vertical)
            return
        }
        guard screenWidth > 0, screenHeight > 0 else { return }

        lock.lock()
        pendingDistance += CGFloat(vertical) * Self.pointsPerNotch
        pendingPoint = point
        pendingScreenHeight = CGFloat(screenHeight)
        let shouldStart = !isDraining
        if shouldStart { isDraining = true }
        lock.unlock()

        if shouldStart {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// 队列上的唯一消费者：把攒下的位移一段段走完，没有新滚动就退出。
    private func drain() {
        while true {
            lock.lock()
            let distance = pendingDistance
            let point = pendingPoint
            let screenHeight = pendingScreenHeight
            pendingDistance = 0
            if distance == 0 || screenHeight <= 1 {
                isDraining = false
                lock.unlock()
                return
            }
            lock.unlock()
            performGesture(distance: distance, at: point, screenHeight: screenHeight)
        }
    }

    private func performGesture(distance: CGFloat, at point: CGPoint, screenHeight: CGFloat) {
        let maxY = screenHeight - 1
        // 一次手势最多走半屏，否则一滚就飞出天际。
        let magnitude = min(abs(distance), screenHeight / 2)
        let half = magnitude / 2
        // 整段手势要完整落在屏幕内：把中心点先夹到能容下它的范围里。
        let centerY = min(max(point.y, half), maxY - half)

        let downward = distance > 0
        let from = CGPoint(x: point.x, y: downward ? centerY - half : centerY + half)
        let to = CGPoint(x: point.x, y: downward ? centerY + half : centerY - half)

        let base = self.base
        let stepInterval = self.stepInterval
        let settleInterval = self.settleInterval
        // 手势途中出错不影响别的输入：通道断了会有重连负责，这里只把这一段放掉。
        try? base.touchDown(at: from)
        for step in 1...Self.steps {
            Thread.sleep(forTimeInterval: stepInterval)
            let t = CGFloat(step) / CGFloat(Self.steps)
            try? base.touchMove(to: CGPoint(x: from.x, y: from.y + (to.y - from.y) * t))
        }
        Thread.sleep(forTimeInterval: settleInterval)
        try? base.touchUp(at: to)
    }
}
