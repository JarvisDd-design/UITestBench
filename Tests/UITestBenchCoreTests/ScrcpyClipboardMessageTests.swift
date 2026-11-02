import XCTest
@testable import UITestBenchCore

final class ScrcpyClipboardMessageTests: XCTestCase {
    private func bytes(_ message: ScrcpyControlMessage) -> [UInt8] {
        [UInt8](message.encoded())
    }

    func testSetClipboardEncodesSequencePasteFlagAndText() {
        let message = ScrcpyControlMessage.setClipboard(
            sequence: 0x0102_0304_0506_0708,
            paste: true,
            text: "汉"
        )

        XCTAssertEqual(bytes(message), [
            9,                          // TYPE_SET_CLIPBOARD
            1, 2, 3, 4, 5, 6, 7, 8,     // sequence，大端 u64
            1,                          // paste 标志
            0, 0, 0, 3,                 // 文本字节数，大端 u32
            0xE6, 0xB1, 0x89,           // "汉" 的 UTF-8
        ])
    }

    func testSetClipboardWithoutPasteFlag() {
        let message = ScrcpyControlMessage.setClipboard(sequence: 7, paste: false, text: "a")
        XCTAssertEqual(bytes(message), [9, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 1, 0x61])
    }

    func testSetClipboardWithEmptyText() {
        let message = ScrcpyControlMessage.setClipboard(sequence: 1, paste: true, text: "")
        XCTAssertEqual(bytes(message), [9, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0])
    }

    func testSetClipboardTruncatesOnUTF8Boundary() {
        let message = ScrcpyControlMessage.setClipboard(
            sequence: 1,
            paste: true,
            text: String(repeating: "汉", count: 3000)
        )
        let encoded = message.encoded()

        // type(1) + seq(8) + paste(1) + len(4)
        let length = textLength(in: encoded)
        XCTAssertEqual(encoded.count, 14 + length)
        XCTAssertLessThanOrEqual(length, ScrcpyControlMessage.clipboardTextMaxLength)
        XCTAssertEqual(length % 3, 0, "截断必须落在 UTF-8 边界上")

        let text = String(
            decoding: encoded.subdata(in: 14..<(14 + length)),
            as: UTF8.self
        )
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(text.count, length / 3)
    }

    func testSetClipboardKeepsShortTextIntact() {
        let message = ScrcpyControlMessage.setClipboard(sequence: 2, paste: true, text: "你好，验收台")
        let encoded = message.encoded()
        let length = textLength(in: encoded)
        XCTAssertEqual(
            String(decoding: encoded.subdata(in: 14..<(14 + length)), as: UTF8.self),
            "你好，验收台"
        )
    }

    func testPasteKeycodeIsTwoHundredSeventyNine() {
        XCTAssertEqual(AndroidKey.paste.rawValue, 279)
    }

    private func textLength(in encoded: Data) -> Int {
        let start = encoded.startIndex
        let raw = [UInt8](encoded[(start + 10)..<(start + 14)])
        return raw.reduce(0) { ($0 << 8) | Int($1) }
    }
}
