import Foundation

/// 一次按键在设备上的归宿：输入一段文字，或者按一个系统键。
public enum KeyboardAction: Equatable, Sendable {
    case text(String)
    case key(AndroidKey)
}

/// 把 Mac 键盘的按键翻译成设备动作。
///
/// 只送 ASCII 可见字符：控制通道的文字注入最终要变成设备上的按键事件，中文没有
/// 对应的按键，送过去也只会被丢掉。这是已知限制，界面上会说明。
public enum KeyboardInput {
    /// 只关心会改变含义的修饰键；Shift 已经体现在字符本身（`A` 就是 `A`）。
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)

        /// 这些组合是 Mac 自己的快捷方式，不能漏给设备。
        public static let shortcuts: Modifiers = [.command, .control, .option]
    }

    /// 返回 nil 表示这条按键不归设备管，交给 AppKit 继续处理（Tab 切焦点、
    /// ⌘ 系列快捷键等）。
    public static func action(for characters: String, modifiers: Modifiers) -> KeyboardAction? {
        guard !characters.isEmpty, modifiers.intersection(.shortcuts).isEmpty else {
            return nil
        }

        switch characters {
        case "\r", "\n", "\u{3}":
            // 主键盘回车、换行、小键盘回车（ETX）。
            return .key(.enter)
        case "\u{7F}", "\u{8}", "\u{1B}":
            // 删除有两种编码（DEL / BS），Esc 一并当作返回。
            return .key(.back)
        default:
            break
        }

        // 0x20…0x7E：可打印 ASCII。Tab、方向键、私有区字符都落在这里面之外。
        guard characters.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            return nil
        }
        return .text(characters)
    }
}
