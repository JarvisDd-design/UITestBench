import XCTest
@testable import UITestBenchCore

/// 滚轮改成合成拖动。
///
/// 真机验收证明：`ACTION_SCROLL` 注进去后系统接得住、应用却不响应（Android 14 AOSP
/// 镜像上如此），而同一个点的拖动立刻生效。所以滚轮走「按下 → 挪几下 → 抬起」。
final class DragScrollSinkTests: XCTestCase {
    private var base: RecordingInputSink!
    private var sink: DragScrollSink!
    private var queue: DispatchQueue!

    private let screen = CGSize(width: 864, height: 1920)

    override func setUp() {
        super.setUp()
        base = RecordingInputSink()
        // 手势在后台队列上按拍子发；测试里把拍子设成 0，再把队列排水（sync 空块），
        // 就能像同步调用一样断言，且不会因为真实时间而抖动。
        queue = DispatchQueue(label: "DragScrollSinkTests")
        sink = DragScrollSink(base: base, queue: queue, stepInterval: 0, settleInterval: 0)
        sink.updateScreenSize(width: Int(screen.width), height: Int(screen.height))
    }

    /// 发一次滚轮并等手势跑完。
    private func scroll(_ point: CGPoint, horizontal: Int = 0, vertical: Int) throws {
        try sink.scroll(at: point, horizontal: horizontal, vertical: vertical)
        queue.sync {}
    }

    /// 向下滚（内容往上走）等于手指往上拖，视觉上列表才跟着动。
    func testScrollDownDragsFingerUpwards() throws {
        try scroll(CGPoint(x: 400, y: 900), vertical: -1)

        XCTAssertEqual(base.events.first, .down(CGPoint(x: 400, y: 950)))
        XCTAssertEqual(base.events.last, .up(CGPoint(x: 400, y: 850)), "手指起点在下方，终点在上方")
        XCTAssertEqual(base.events.filter { if case .move = $0 { return true } else { return false } }.count, DragScrollSink.steps)
    }

    func testScrollUpDragsFingerDownwards() throws {
        try scroll(CGPoint(x: 400, y: 900), vertical: 1)

        XCTAssertEqual(base.events.first, .down(CGPoint(x: 400, y: 850)))
        XCTAssertEqual(base.events.last, .up(CGPoint(x: 400, y: 950)))
    }

    /// 一格滚轮走多远：太短达不到触摸阈值，会被当成点击。
    func testOneNotchMovesMoreThanTheTouchSlop() throws {
        try scroll(CGPoint(x: 400, y: 900), vertical: -1)

        let ys = base.events.compactMap { event -> CGFloat? in
            switch event {
            case let .down(point), let .move(point), let .up(point): return point.y
            default: return nil
            }
        }
        let travel = try XCTUnwrap(ys.max()) - (try XCTUnwrap(ys.min()))
        XCTAssertGreaterThan(travel, 20, "至少要越过系统的触摸阈值，否则会被当成点击")
    }

    /// 靠近屏幕边缘时整段手势要往里挪，不能一半落在屏幕外。
    func testGestureStaysInsideTheScreen() throws {
        try scroll(CGPoint(x: 400, y: 1910), vertical: -1)

        for case let point in base.events.compactMap(pointsOf) {
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.y, screen.height - 1)
        }
        // 向下滚 → 手指往上走，起点在下、终点在上。
        let points = base.events.compactMap(pointsOf)
        XCTAssertGreaterThan(try XCTUnwrap(points.first).y, try XCTUnwrap(points.last).y)
    }

    /// 一次滚多格，走的距离要按格数放大。
    func testMultipleNotchesScaleTheDistance() throws {
        try scroll(CGPoint(x: 400, y: 900), vertical: -3)

        let start = try XCTUnwrap(base.events.first.flatMap(pointsOf))
        let end = try XCTUnwrap(base.events.last.flatMap(pointsOf))
        XCTAssertEqual(start.y - end.y, DragScrollSink.pointsPerNotch * 3, accuracy: 0.5)
    }

    /// 单次手势再大也不能超过半屏，否则一滚就飞出去。
    func testDistanceIsCapped() throws {
        try scroll(CGPoint(x: 400, y: 900), vertical: -50)

        let start = try XCTUnwrap(base.events.first.flatMap(pointsOf))
        let end = try XCTUnwrap(base.events.last.flatMap(pointsOf))
        XCTAssertLessThanOrEqual(abs(start.y - end.y), screen.height / 2)
    }

    /// 触控板一划会连着来一长串轮齿。如果每个轮齿排一段约 0.2 秒的手势，
    /// 队列会积压好几秒：用户早停手了，画面还在自己滚，看起来就像「滚不动」。
    /// 同一批滚动必须合成一段手势。
    func testBurstOfNotchesIsCoalescedIntoOneGesture() throws {
        // 在队列自己的块里连发三条：串行队列上的手势任务要等这个块结束才能跑，
        // 三条一定先攒在一起——与主线程上连续的 scrollWheel 事件同构。
        queue.sync {
            for _ in 0..<3 {
                try? sink.scroll(at: CGPoint(x: 400, y: 900), horizontal: 0, vertical: -1)
            }
        }
        queue.sync {}

        let downs = base.events.filter { event in
            if case .down = event { return true }
            return false
        }
        XCTAssertEqual(downs.count, 1, "同一批滚动应当只合成一段手势")

        let start = try XCTUnwrap(base.events.first.flatMap(pointsOf))
        let end = try XCTUnwrap(base.events.last.flatMap(pointsOf))
        XCTAssertEqual(start.y - end.y, DragScrollSink.pointsPerNotch * 3, accuracy: 0.5)
    }

    /// 只有横向滚动时不合成手势，原样交给下层。
    func testHorizontalOnlyScrollIsForwarded() throws {
        try scroll(CGPoint(x: 400, y: 900), horizontal: 2, vertical: 0)

        XCTAssertEqual(base.events, [.scroll(CGPoint(x: 400, y: 900), 2, 0)])
    }

    /// 点击、拖动、按键都不能被这一层吞掉。
    func testOtherEventsPassThrough() throws {
        try sink.touchDown(at: CGPoint(x: 1, y: 2))
        try sink.touchMove(to: CGPoint(x: 3, y: 4))
        try sink.touchUp(at: CGPoint(x: 5, y: 6))
        try sink.tap(at: CGPoint(x: 7, y: 8))
        try sink.pressKey(.back)
        try sink.sendText("hi")

        XCTAssertEqual(base.events, [
            .down(CGPoint(x: 1, y: 2)),
            .move(CGPoint(x: 3, y: 4)),
            .up(CGPoint(x: 5, y: 6)),
            .down(CGPoint(x: 7, y: 8)),
            .up(CGPoint(x: 7, y: 8)),
            .key(.back),
            .text("hi"),
        ])
    }

    /// 连续滚两格时两段手势必须首尾相接，不能交错——系统会把它当成两根手指。
    func testConsecutiveScrollsDoNotInterleave() throws {
        try sink.scroll(at: CGPoint(x: 400, y: 900), horizontal: 0, vertical: -1)
        try sink.scroll(at: CGPoint(x: 400, y: 900), horizontal: 0, vertical: -1)
        queue.sync {}

        var gesture = 0
        for event in base.events {
            switch event {
            case .down:
                gesture += 1
                XCTAssertEqual(gesture, 1, "上一段手势还没抬手就又按下了")
            case .up:
                XCTAssertEqual(gesture, 1)
                gesture = 0
            default:
                break
            }
        }
        XCTAssertEqual(gesture, 0, "最后一段手势没有抬手")
    }

    private func pointsOf(_ event: RecordingInputSink.Event) -> CGPoint? {
        switch event {
        case let .down(point), let .move(point), let .up(point): return point
        default: return nil
        }
    }
}
