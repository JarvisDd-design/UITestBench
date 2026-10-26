import Foundation

/// 一次按键在设备上的归宿：输入一段文字、按一个系统键，或者被画面吞掉。
public enum KeyboardAction: Equatable, Sendable {
    case text(String)
    case key(AndroidKey)
    /// 这个键由画面吞掉，不发给设备，也不映射成任何设备动作。
    case ignored
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
        /// Shift 不参与文字翻译（`A` 就是 `A`），只用来区分 ⌘⇧[ 这类组合。
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// 这些组合是 Mac 自己的快捷方式，不能漏给设备。
        public static let shortcuts: Modifiers = [.command, .control, .option]
    }

    /// 返回 nil 表示这条按键不归设备管，交给 AppKit 继续处理（Tab 切焦点、
    /// ⌘ 系列快捷键等）。
    public static func action(for characters: String, modifiers: Modifiers) -> KeyboardAction? {
        // ⌘[ 是 macOS 的「后退」。只认精确的 ⌘，⌘⇧[ 不映射，
        // 否则监视器用 charactersIgnoringModifiers 时会把两个组合混在一起。
        if characters == "[", modifiers == .command {
            return .key(.back)
        }

        guard !characters.isEmpty, modifiers.intersection(.shortcuts).isEmpty else {
            return nil
        }

        switch characters {
        case "\r", "\n", "\u{3}":
            // 主键盘回车、换行、小键盘回车（ETX）。
            return .key(.enter)
        case "\u{7F}", "\u{8}", "\u{1B}":
            // 删除/Esc 不再当返回；吞掉是为了避免 AppKit 发出提示音。
            return .ignored
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

/// 应用级 ⌘[ 是否应该转成设备返回键。
public enum DeviceBackShortcutDecision: Equatable, Sendable {
    case send
    case ignore
}

/// 判断一个已经翻译过的按键该不该由应用级监视器接管。
///
/// 和 `KeyboardInput.action` 分开：翻译只管「字符 → 设备动作」，
/// 这里再决定「这个动作在当前窗口 / 编辑状态下要不要发」。
public enum DeviceBackShortcutPolicy {
    public static func decision(
        action: KeyboardAction?,
        modifiers: KeyboardInput.Modifiers,
        isEditingText: Bool,
        target: DockClickTarget
    ) -> DeviceBackShortcutDecision {
        guard action == .key(.back), modifiers == .command else {
            return .ignore
        }
        guard !isEditingText else {
            return .ignore
        }
        switch target {
        case .sheet, .modal:
            return .ignore
        case .phone, .dock, .drawer, .auxiliary:
            return .send
        }
    }
}
