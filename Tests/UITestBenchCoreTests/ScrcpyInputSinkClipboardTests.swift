import XCTest
@testable import UITestBenchCore

final class ScrcpyInputSinkClipboardTests: XCTestCase {
    private var stream: FakeByteStream!
    private var sink: ScrcpyInputSink!

    override func setUp() {
        super.setUp()
        stream = FakeByteStream(bytes: Data())
        sink = ScrcpyInputSink(stream: stream)
    }

    private func flushed() -> [Data] {
        sink.flushPendingWrites()
        return stream.written
    }

    func testPasteWritesOneClipboardMessageAndNoExtraKey() throws {
        sink.updateScreenSize(width: 864, height: 1920)

        try sink.setClipboardAndPaste(text: "你好")

        // 只发一条 SET_CLIPBOARD：服务端收到 paste=1 会自己注入粘贴键。
        // 再补 KEYCODE_PASTE 就是粘两遍，「好的」变「好的好的」（真机复现过）。
        let packets = flushed()
        XCTAssertEqual(packets.count, 1)

        XCTAssertEqual(packets[0][0], 9)
        XCTAssertEqual(Array(packets[0][1..<9]), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(packets[0][9], 1)
        XCTAssertEqual(Array(packets[0][10..<14]), [0, 0, 0, 6])
        XCTAssertEqual(String(decoding: packets[0][14...], as: UTF8.self), "你好")
    }

    func testSequenceNumberIncrementsPerClipboardWrite() throws {
        try sink.setClipboardAndPaste(text: "一")
        try sink.setClipboardAndPaste(text: "二")

        let packets = flushed()
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(Array(packets[0][1..<9]), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(Array(packets[1][1..<9]), [0, 0, 0, 0, 0, 0, 0, 2])
    }

    func testEmptyTextWritesNothing() throws {
        try sink.setClipboardAndPaste(text: "")
        XCTAssertTrue(flushed().isEmpty)
    }
}
