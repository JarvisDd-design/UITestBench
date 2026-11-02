import Foundation

/// 一次按键的去向。
///
/// `MirrorDisplayView` 拿到按键后先问这里，再决定是直接注入、交给输入法组字，
/// 还是还给 AppKit。判定规则放在 Core 里，好单测。
public enum KeyboardRoute: Equatable, Sendable {
    /// ASCII 快路径：直接发 `INJECT_TEXT`，和 1.4.x 的手感完全一致。
    case fastPath(String)
    case deviceKey(AndroidKey)
    /// 交给画面上的输入法上下文（`NSTextInputClient`）组字。
    case compose
    /// 画面吞掉，不发设备也不给 AppKit（避免提示音）。
    case ignored
    /// 不归画面管，还给 AppKit（Tab 切焦点、⌘ 系列快捷键等）。
    case system
}

/// 组好字之后怎么送到设备上。
public enum CommittedTextRoute: Equatable, Sendable {
    case injectText(String)
    case clipboardPaste(String)
    case nothing
}

public enum KeyboardRouting {
    /// - Parameters:
    ///   - isASCIIInputSource: 当前输入法是不是 ASCII 键盘。中文输入法开着时，
    ///     敲出来的字母要先交给输入法组字，不能当 ASCII 直接注入。
    ///   - hasMarkedText: 画面上已经有组字中的文本（拼音串、候选未上屏）。
    public static func route(
        characters: String,
        modifiers: KeyboardInput.Modifiers,
        isASCIIInputSource: Bool,
        hasMarkedText: Bool
    ) -> KeyboardRoute {
        if hasMarkedText { return .compose }

        guard let action = KeyboardInput.action(for: characters, modifiers: modifiers) else {
            return .system
        }
        guard !isASCIIInputSource else {
            switch action {
            case .text(let text): return .fastPath(text)
            case .key(let key): return .deviceKey(key)
            case .ignored: return .ignored
            }
        }

        // 中文输入法：字母、回车、退格都先让输入法处理（选词、上屏、删候选）。
        // ⌘ 系列在 `KeyboardInput.action` 里已经是 nil，不会走到这里。
        return .compose
    }

    /// 输入法提交一段文字后，选最快的送达方式：短 ASCII 走文字注入，
    /// 中文等非 ASCII 和超长文本走「写剪贴板 + 粘贴键」。
    public static func routeCommittedText(_ text: String) -> CommittedTextRoute {
        guard !text.isEmpty else { return .nothing }

        let isPrintableASCII = text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        if isPrintableASCII, text.utf8.count <= ScrcpyControlMessage.textMaxLength {
            return .injectText(text)
        }
        return .clipboardPaste(text)
    }
}
