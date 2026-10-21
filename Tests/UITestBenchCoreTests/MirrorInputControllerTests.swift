import XCTest
@testable import UITestBenchCore

/// 视图里的鼠标动作 → 控制消息。这里只验证「翻译」这一层：
/// 坐标换算、黑边丢弃、拖动生命周期。字节布局由 `ScrcpyInputSinkTests` 负责。
final class MirrorInputControllerTests: XCTestCase {
    private var sink: RecordingInputSink!
    private var controller: MirrorInputController!

    /// 视图 480×960，画面 864×1920：等比缩到 0.5 倍，正好铺满，没有黑边。
    private let fullView = CGSize(width: 432, height: 960)

    override func setUp() {
        super.setUp()
        sink = RecordingInputSink()
        controller = MirrorInputController(
            sink: sink,
            viewSize: fullView,
            videoSize: CGSize(width: 864, height: 1920)
        )
    }

    func testClickIsScaledIntoVideoCoordinates() {
        controller.mouseDown(at: CGPoint(x: 100, y: 200))
        controller.mouseUp(at: CGPoint(x: 100, y: 200))

        XCTAssertEqual(sink.events, [
            .down(CGPoint(x: 200, y: 400)),
            .up(CGPoint(x: 200, y: 400)),
        ])
    }

    /// 画面等比缩放后四周会有黑边。点在黑边上不应该变成「点到了屏幕边缘」。
    func testClickInTheLetterboxIsIgnored() {
        // 视图 300×960 装 864×1920：缩放 0.347，画面宽 300、高 667，上下各留 146.5。
        controller.update(viewSize: CGSize(width: 300, height: 960))

        controller.mouseDown(at: CGPoint(x: 150, y: 50))
        controller.mouseUp(at: CGPoint(x: 150, y: 50))

        XCTAssertEqual(sink.events, [], "点在黑边上不产生点击")
    }

    func testDragKeepsSendingMovesAndEndsWithUp() {
        controller.mouseDown(at: CGPoint(x: 100, y: 400))
        controller.mouseDragged(to: CGPoint(x: 120, y: 300))
        controller.mouseDragged(to: CGPoint(x: 140, y: 200))
        controller.mouseUp(at: CGPoint(x: 140, y: 200))

        XCTAssertEqual(sink.events, [
            .down(CGPoint(x: 200, y: 800)),
            .move(CGPoint(x: 240, y: 600)),
            .move(CGPoint(x: 280, y: 400)),
            .up(CGPoint(x: 280, y: 400)),
        ])
    }

    /// 拖到画面外时坐标夹在边缘（手指滑出屏幕，Android 收到的仍是屏幕内的点）。
    /// 松手必须发出去，否则设备会一直停在「按着」的状态。
    func testDragOutsideTheContentClampsAndStillReleases() {
        controller.mouseDown(at: CGPoint(x: 100, y: 400))
        controller.mouseDragged(to: CGPoint(x: -50, y: 2000))
        controller.mouseUp(at: CGPoint(x: -50, y: 2000))

        XCTAssertEqual(sink.events, [
            .down(CGPoint(x: 200, y: 800)),
            .move(CGPoint(x: 0, y: 1919)),
            .up(CGPoint(x: 0, y: 1919)),
        ])
    }

    /// 没按下就移动（单纯划过画面）不发触摸事件。
    func testMoveWithoutPressSendsNothing() {
        controller.mouseDragged(to: CGPoint(x: 100, y: 100))

        XCTAssertEqual(sink.events, [])
    }

    func testReleaseWithoutPressSendsNothing() {
        controller.mouseUp(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(sink.events, [])
    }

    func testScrollIsMappedLikeAClick() {
        controller.scroll(at: CGPoint(x: 100, y: 200), horizontal: 0, vertical: -2)

        XCTAssertEqual(sink.events, [.scroll(CGPoint(x: 200, y: 400), 0, -2)])
    }

    /// 滚轮和点击不一样：点击落在黑边上什么都不该发生，但滚轮是「对着这一屏
    /// 滚」，鼠标偏到画面外一点点仍然应当滚。坐标夹到画面内，别把整条事件丢掉。
    func testScrollInTheLetterboxClampsToTheContent() {
        controller.update(viewSize: CGSize(width: 300, height: 960))

        controller.scroll(at: CGPoint(x: 150, y: 50), horizontal: 0, vertical: -1)

        guard case let .scroll(point, _, _)? = sink.events.first else {
            return XCTFail("黑边上的滚轮也应当发出去，实际：\(sink.events)")
        }
        XCTAssertEqual(point.x, 432, accuracy: 0.5, "横向在画面内，保留鼠标位置")
        XCTAssertEqual(point.y, 960, accuracy: 0.5, "纵向越界，落到画面中线而不是贴边")
    }

    /// 转屏后画面宽高互换，同一视图点应当落到新的坐标上。
    func testRotationRemapsLaterEvents() {
        controller.update(videoSize: CGSize(width: 1920, height: 864))
        controller.update(viewSize: CGSize(width: 960, height: 432))

        controller.mouseDown(at: CGPoint(x: 100, y: 200))
        controller.mouseUp(at: CGPoint(x: 100, y: 200))

        XCTAssertEqual(sink.events, [
            .down(CGPoint(x: 200, y: 400)),
            .up(CGPoint(x: 200, y: 400)),
        ])
    }

    func testBackKeyIsPassedThrough() {
        controller.pressKey(.back)

        XCTAssertEqual(sink.events, [.key(.back)])
    }

    /// 控制消息里带着屏宽高，服务端拿它和视频尺寸比对，不一致就整条丢掉。
    /// 所以屏幕尺寸必须和坐标映射用同一份数据，不能由调用方各自维护。
    func testInitialVideoSizeReachesTheSink() {
        XCTAssertEqual(sink.screenSizes, [CGSize(width: 864, height: 1920)])
    }

    func testVideoSizeChangeReachesTheSink() {
        controller.update(videoSize: CGSize(width: 1920, height: 864))

        XCTAssertEqual(sink.screenSizes, [
            CGSize(width: 864, height: 1920),
            CGSize(width: 1920, height: 864),
        ])
    }
}

/// 记录调用顺序的假 sink，不关心字节。
final class RecordingInputSink: MirrorInputSink {
    enum Event: Equatable {
        case down(CGPoint)
        case move(CGPoint)
        case up(CGPoint)
        case scroll(CGPoint, Int, Int)
        case key(AndroidKey)
        case text(String)
    }

    private(set) var events: [Event] = []
    private(set) var screenSizes: [CGSize] = []

    func updateScreenSize(width: Int, height: Int) {
        screenSizes.append(CGSize(width: width, height: height))
    }

    func touchDown(at point: CGPoint) throws {
        events.append(.down(point))
    }

    func touchMove(to point: CGPoint) throws {
        events.append(.move(point))
    }

    func touchUp(at point: CGPoint) throws {
        events.append(.up(point))
    }

    func tap(at point: CGPoint) throws {
        events.append(.down(point))
        events.append(.up(point))
    }

    func scroll(at point: CGPoint, horizontal: Int, vertical: Int) throws {
        events.append(.scroll(point, horizontal, vertical))
    }

    func pressKey(_ key: AndroidKey) throws {
        events.append(.key(key))
    }

    func sendText(_ text: String) throws {
        events.append(.text(text))
    }
}
