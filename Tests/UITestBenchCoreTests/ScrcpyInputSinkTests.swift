import XCTest
@testable import UITestBenchCore

final class ScrcpyInputSinkTests: XCTestCase {
    private var stream: FakeByteStream!
    private var sink: ScrcpyInputSink!

    override func setUp() {
        super.setUp()
        stream = FakeByteStream(bytes: Data())
        sink = ScrcpyInputSink(stream: stream)
    }

    func testRefusesToInjectBeforeScreenSizeIsKnown() {
        XCTAssertThrowsError(try sink.tap(at: CGPoint(x: 10, y: 10))) { error in
            XCTAssertEqual(error as? ScrcpyInputError, .screenSizeUnknown)
        }
        XCTAssertTrue(stream.written.isEmpty)
    }

    func testTapSendsDownThenUpAtSamePoint() throws {
        sink.updateScreenSize(width: 1080, height: 2400)

        try sink.tap(at: CGPoint(x: 100, y: 200))

        XCTAssertEqual(stream.written.count, 2)
        let down = try TouchPacket(stream.written[0])
        let up = try TouchPacket(stream.written[1])
        XCTAssertEqual(down.action, 0)
        XCTAssertEqual(up.action, 1)
        XCTAssertEqual([down.x, down.y], [100, 200])
        XCTAssertEqual([up.x, up.y], [100, 200])
        XCTAssertEqual(down.pressure, 0xFFFF)
        XCTAssertEqual(up.pressure, 0)
        XCTAssertEqual(down.screenWidth, 1080)
        XCTAssertEqual(down.screenHeight, 2400)
    }

    func testDragSendsDownMoveMoveUpInOrder() throws {
        sink.updateScreenSize(width: 1080, height: 2400)

        try sink.touchDown(at: CGPoint(x: 10, y: 20))
        try sink.touchMove(to: CGPoint(x: 50, y: 60))
        try sink.touchMove(to: CGPoint(x: 90, y: 100))
        try sink.touchUp(at: CGPoint(x: 90, y: 100))

        let packets = try stream.written.map(TouchPacket.init)
        XCTAssertEqual(packets.map(\.action), [0, 2, 2, 1])
        XCTAssertEqual(packets.map(\.x), [10, 50, 90, 90])
        XCTAssertEqual(packets.map(\.y), [20, 60, 100, 100])
    }

    /// 滚动量是 [-16, 16] 的「轮齿数」，线上要乘 2048 变成 i16 定点数。
    /// 直接把齿数写进消息，服务端只会算出约等于 0 的滚动量（16/32768×16 = 0.0078）。
    func testScrollSendsFixedPointWheelNotches() throws {
        sink.updateScreenSize(width: 864, height: 1920)

        try sink.scroll(at: CGPoint(x: 432, y: 960), horizontal: 1, vertical: -2)

        XCTAssertEqual(stream.written.count, 2, "先悬停再把滚动消息发出去")
        let data = try XCTUnwrap(stream.written.last)
        XCTAssertEqual(data[0], 3)
        // 位置之后是屏宽高：864 = 0x0360，1920 = 0x0780。
        XCTAssertEqual(Array(data[9..<13]), [0x03, 0x60, 0x07, 0x80])
        // 1 × 2048 = 0x0800；-2 × 2048 = -4096 → 0xF000。
        XCTAssertEqual(Array(data[13..<15]), [0x08, 0x00])
        XCTAssertEqual(Array(data[15..<17]), [0xF0, 0x00])
    }

    /// 滚轮事件走 `SOURCE_MOUSE`，系统按鼠标指针的位置找窗口。没发过悬停事件时
    /// 指针位置是未知的，滚动会被丢到别处——表现就是「滚轮完全没反应」。
    /// 所以滚动前必须先把指针悬停到目标点（官方客户端靠鼠标移动顺带做了这件事）。
    func testScrollHoversThePointerAtThePointFirst() throws {
        sink.updateScreenSize(width: 864, height: 1920)

        try sink.scroll(at: CGPoint(x: 432, y: 960), horizontal: 0, vertical: -1)

        XCTAssertEqual(stream.written.count, 2)
        let hover = try TouchPacket(stream.written[0])
        XCTAssertEqual(hover.action, 7, "7 = ACTION_HOVER_MOVE")
        XCTAssertEqual([hover.x, hover.y], [432, 960])
        XCTAssertEqual(hover.pressure, 0xFFFF)
        XCTAssertEqual(stream.written[1][0], 3, "悬停之后才是滚动消息")
    }

    func testScrollIsClampedToTheProtocolRange() throws {
        sink.updateScreenSize(width: 864, height: 1920)

        try sink.scroll(at: CGPoint(x: 10, y: 10), horizontal: 0, vertical: 100)

        let data = try XCTUnwrap(stream.written.last)
        // 16 × 2048 = 32768 超出 i16 正数上限，按客户端的做法钳到 32767。
        XCTAssertEqual(Array(data[15..<17]), [0x7F, 0xFF])
    }

    func testBackKeySendsDownAndUp() throws {
        sink.updateScreenSize(width: 1080, height: 2400)

        try sink.pressKey(.back)

        XCTAssertEqual(stream.written.count, 2)
        XCTAssertEqual(stream.written[0], Data([0x00, 0x00, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(stream.written[1], Data([0x00, 0x01, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testTextSendsInjectTextMessage() throws {
        sink.updateScreenSize(width: 1080, height: 2400)

        try sink.sendText("hi")

        XCTAssertEqual(stream.written, [Data([0x01, 0, 0, 0, 2, 0x68, 0x69])])
    }

    /// 转屏后宽高互换，后续事件必须用新尺寸，否则服务端会把坐标按比例算错。
    func testScreenSizeUpdateAppliesToLaterEvents() throws {
        sink.updateScreenSize(width: 1080, height: 2400)
        try sink.tap(at: CGPoint(x: 1, y: 2))

        sink.updateScreenSize(width: 2400, height: 1080)
        try sink.tap(at: CGPoint(x: 3, y: 4))

        let packets = try stream.written.map(TouchPacket.init)
        XCTAssertEqual([packets[0].screenWidth, packets[0].screenHeight], [1080, 2400])
        XCTAssertEqual([packets[2].screenWidth, packets[2].screenHeight], [2400, 1080])
    }

    func testPointsOutsideTheScreenAreClamped() throws {
        sink.updateScreenSize(width: 100, height: 200)

        try sink.tap(at: CGPoint(x: -5, y: 500))

        let down = try TouchPacket(stream.written[0])
        XCTAssertEqual([down.x, down.y], [0, 199])
    }
}

/// 只解出测试关心的字段。
/// 布局：type(1) action(1) pointer(8) x(4) y(4) 屏宽(2) 屏高(2) 压力(2) …
private struct TouchPacket {
    let action: UInt8
    let x: Int
    let y: Int
    let screenWidth: Int
    let screenHeight: Int
    let pressure: Int

    init(_ data: Data) throws {
        XCTAssertEqual(data.count, 32)
        action = data[1]
        x = Int(data[10]) << 24 | Int(data[11]) << 16 | Int(data[12]) << 8 | Int(data[13])
        y = Int(data[14]) << 24 | Int(data[15]) << 16 | Int(data[16]) << 8 | Int(data[17])
        screenWidth = Int(data[18]) << 8 | Int(data[19])
        screenHeight = Int(data[20]) << 8 | Int(data[21])
        pressure = Int(data[22]) << 8 | Int(data[23])
    }
}
