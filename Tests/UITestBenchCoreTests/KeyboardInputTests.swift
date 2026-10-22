import XCTest
@testable import UITestBenchCore

/// 键盘按键 → 设备动作的翻译规则。
///
/// 这一层不碰 AppKit：视图只负责把 `NSEvent` 的字符和修饰键交进来，
/// 规则在这里单测，改起来不用担心界面。
final class KeyboardInputTests: XCTestCase {
    private func action(
        _ characters: String,
        _ modifiers: KeyboardInput.Modifiers = []
    ) -> KeyboardAction? {
        KeyboardInput.action(for: characters, modifiers: modifiers)
    }

    func testPrintableCharactersBecomeText() {
        XCTAssertEqual(action("a"), .text("a"))
        XCTAssertEqual(action("A"), .text("A"))
        XCTAssertEqual(action("1"), .text("1"))
        XCTAssertEqual(action("!"), .text("!"))
        XCTAssertEqual(action(" "), .text(" "))
    }

    /// 输入法可能一次给出多个字符（组合输入），能一起送就一起送。
    func testSeveralPrintableCharactersAreSentTogether() {
        XCTAssertEqual(action("ab"), .text("ab"))
    }

    /// 回车在搜索框里要能提交，所以发 KEYCODE_ENTER，而不是当成文字。
    func testReturnPressesEnter() {
        XCTAssertEqual(action("\r"), .key(.enter))
        XCTAssertEqual(action("\n"), .key(.enter))
        XCTAssertEqual(action("\u{3}"), .key(.enter), "小键盘的回车是 ETX")
    }

    /// 1.3.0 起不再把删除/Esc 当返回：这些键会被吞掉，
    /// 既不触发设备返回，也不在 Mac 上发出提示音。
    func testDeleteAndEscapeAreSwallowedButDoNotPressBack() {
        XCTAssertEqual(action("\u{7F}"), .ignored)
        XCTAssertEqual(action("\u{8}"), .ignored)
        XCTAssertEqual(action("\u{1B}"), .ignored)
    }

    /// ⌘C、⌃A、⌥a 这些是 Mac 自己的快捷键，不能漏给设备。
    func testShortcutModifiersAreNotSwallowed() {
        XCTAssertNil(action("c", .command))
        XCTAssertNil(action("a", .control))
        XCTAssertNil(action("a", .option))
        XCTAssertNil(action("v", [.command, .option]))
        // 被吞掉的键也不能抢走 Mac 的快捷键。
        XCTAssertNil(action("\u{7F}", .command))
        XCTAssertNil(action("\u{1B}", .command))
        XCTAssertNil(action("\u{1B}", .control))
    }

    /// 控制通道只送 ASCII：中文没有对应的按键事件，服务端也注入不进去。
    func testNonASCIIIsIgnored() {
        XCTAssertNil(action("中"))
        XCTAssertNil(action("é"))
        XCTAssertNil(action("😀"))
    }

    /// Tab 要在 Mac 上切换焦点，不能被设备吃掉。
    func testTabIsLeftToAppKit() {
        XCTAssertNil(action("\t"))
    }

    func testEmptyInputIsIgnored() {
        XCTAssertNil(action(""))
    }
}
