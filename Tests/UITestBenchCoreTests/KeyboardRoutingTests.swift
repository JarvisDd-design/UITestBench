import XCTest
@testable import UITestBenchCore

final class KeyboardRoutingTests: XCTestCase {
    private func route(
        _ characters: String,
        modifiers: KeyboardInput.Modifiers = [],
        asciiSource: Bool,
        marked: Bool = false
    ) -> KeyboardRoute {
        KeyboardRouting.route(
            characters: characters,
            modifiers: modifiers,
            isASCIIInputSource: asciiSource,
            hasMarkedText: marked
        )
    }

    // MARK: - 直接打字

    func testASCIICharactersTakeTheFastPathOnAnASCIIInputSource() {
        XCTAssertEqual(route("a", asciiSource: true), .fastPath("a"))
        XCTAssertEqual(route("A", asciiSource: true), .fastPath("A"))
        XCTAssertEqual(route("\\", asciiSource: true), .fastPath("\\"))
    }

    func testASCIIInputSourceKeepsItsExistingMappings() {
        XCTAssertEqual(route("\r", asciiSource: true), .deviceKey(.enter))
        XCTAssertEqual(route("\u{1B}", asciiSource: true), .ignored)
        XCTAssertEqual(route("\u{7F}", asciiSource: true), .ignored)
        XCTAssertEqual(
            route("[", modifiers: .command, asciiSource: true),
            .deviceKey(.back)
        )
    }

    func testTabAndArrowKeysGoBackToAppKit() {
        XCTAssertEqual(route("\t", asciiSource: true), .system)
        XCTAssertEqual(route("\t", asciiSource: false), .system)
    }

    // MARK: - 中文输入法

    func testNonASCIIInputSourceComposesInsteadOfInjecting() {
        XCTAssertEqual(route("a", asciiSource: false), .compose)
        XCTAssertEqual(route("ni", asciiSource: false), .compose)
        XCTAssertEqual(route("\r", asciiSource: false), .compose, "回车先让输入法决定是否上屏")
        XCTAssertEqual(route("\u{7F}", asciiSource: false), .compose, "退格先删候选")
    }

    func testMarkedTextAlwaysBelongsToTheInputMethod() {
        XCTAssertEqual(route("a", asciiSource: true, marked: true), .compose)
        XCTAssertEqual(route("\r", asciiSource: true, marked: true), .compose)
    }

    func testCommandCombinationsStayWithAppKit() {
        XCTAssertEqual(route("c", modifiers: .command, asciiSource: false), .system)
    }

    // MARK: - 组好字之后

    func testShortASCIICommitUsesInjectText() {
        XCTAssertEqual(KeyboardRouting.routeCommittedText("abc"), .injectText("abc"))
        XCTAssertEqual(KeyboardRouting.routeCommittedText("!"), .injectText("!"))
    }

    func testChineseCommitGoesThroughTheClipboard() {
        XCTAssertEqual(KeyboardRouting.routeCommittedText("汉"), .clipboardPaste("汉"))
        XCTAssertEqual(KeyboardRouting.routeCommittedText("你好，验收台"), .clipboardPaste("你好，验收台"))
    }

    func testEmptyCommitDoesNothing() {
        XCTAssertEqual(KeyboardRouting.routeCommittedText(""), .nothing)
    }

    func testCommitWithNewlinesOrTooLongUsesTheClipboard() {
        XCTAssertEqual(
            KeyboardRouting.routeCommittedText("a\nb"),
            .clipboardPaste("a\nb")
        )
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(
            KeyboardRouting.routeCommittedText(long),
            .clipboardPaste(long),
            "控制通道的文字消息只送 300 字节，更长的走剪贴板"
        )
    }
}
