import Foundation

/// Android keycode 中本工具用到的几个。
public enum AndroidKey: UInt32, Equatable, Sendable {
    case home = 3
    case back = 4
    case enter = 66
    case appSwitch = 187
}

/// 取值与 Android `MotionEvent` 的 action 一致：0 down、1 up、2 move。
public enum ScrcpyControlAction: UInt8, Equatable, Sendable {
    case down = 0
    case up = 1
    case move = 2
    /// `MotionEvent.ACTION_HOVER_MOVE`：鼠标不按键时的移动。服务端据此把事件源
    /// 标成 `SOURCE_MOUSE`，并更新系统里鼠标指针的位置。
    case hoverMove = 7
}

/// 控制通道消息，布局对锁 scrcpy v5.0.1 的 `app/src/control_msg.c`。
public struct ScrcpyControlMessage: Equatable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public func encoded() -> Data {
        bytes
    }

    /// 32 字节：type, action, pointer_id u64, x u32, y u32, 屏宽 u16, 屏高 u16,
    /// 压力 u16 定点, action_button u32, buttons u32。
    public static func touch(
        action: ScrcpyControlAction,
        pointerID: UInt64,
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        pressure: Float,
        actionButton: Int = 0,
        buttons: Int = 0
    ) -> ScrcpyControlMessage {
        var data = Data()
        data.append(2) // SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT
        data.append(action.rawValue)
        data.appendBigEndian(pointerID)
        data.appendBigEndian(UInt32(truncatingIfNeeded: x))
        data.appendBigEndian(UInt32(truncatingIfNeeded: y))
        data.appendBigEndian(UInt16(truncatingIfNeeded: screenWidth))
        data.appendBigEndian(UInt16(truncatingIfNeeded: screenHeight))
        data.appendBigEndian(fixedPointUnsigned(pressure))
        data.appendBigEndian(UInt32(truncatingIfNeeded: actionButton))
        data.appendBigEndian(UInt32(truncatingIfNeeded: buttons))
        return ScrcpyControlMessage(bytes: data)
    }

    /// 14 字节：type, action, keycode u32, repeat u32, metastate u32。
    public static func keycode(
        action: ScrcpyControlAction,
        keycode: UInt32,
        repeat repeatCount: Int = 0,
        metastate: Int = 0
    ) -> ScrcpyControlMessage {
        var data = Data()
        data.append(0) // SC_CONTROL_MSG_TYPE_INJECT_KEYCODE
        data.append(action.rawValue)
        data.appendBigEndian(keycode)
        data.appendBigEndian(UInt32(truncatingIfNeeded: repeatCount))
        data.appendBigEndian(UInt32(truncatingIfNeeded: metastate))
        return ScrcpyControlMessage(bytes: data)
    }

    /// 21 字节：type, 位置 8, 屏宽高 4, 横向滚动 i16, 纵向滚动 i16, buttons u32。
    /// 输入按 scrcpy 约定取 [-16, 16]，先归一化到 [-1, 1] 再转定点。
    public static func scroll(
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        horizontal: Int,
        vertical: Int,
        buttons: Int = 0
    ) -> ScrcpyControlMessage {
        var data = Data()
        data.append(3) // SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT
        data.appendBigEndian(UInt32(truncatingIfNeeded: x))
        data.appendBigEndian(UInt32(truncatingIfNeeded: y))
        data.appendBigEndian(UInt16(truncatingIfNeeded: screenWidth))
        data.appendBigEndian(UInt16(truncatingIfNeeded: screenHeight))
        data.appendBigEndian(fixedPointSigned(normalizeScroll(horizontal)))
        data.appendBigEndian(fixedPointSigned(normalizeScroll(vertical)))
        data.appendBigEndian(UInt32(truncatingIfNeeded: buttons))
        return ScrcpyControlMessage(bytes: data)
    }

    /// type + u32 长度 + UTF-8 正文；超过 300 字节时按字符边界截断。
    public static func text(_ text: String) -> ScrcpyControlMessage {
        let utf8 = Data(text.utf8)
        let truncated = utf8.prefix(truncatingOnUTF8Boundary: 300)
        var data = Data()
        data.append(1) // SC_CONTROL_MSG_TYPE_INJECT_TEXT
        data.appendBigEndian(UInt32(truncated.count))
        data.append(truncated)
        return ScrcpyControlMessage(bytes: data)
    }

    /// 2 字节。
    public static func backOrScreenOn(action: ScrcpyControlAction) -> ScrcpyControlMessage {
        ScrcpyControlMessage(bytes: Data([4, action.rawValue]))
    }
}

/// 压力：0…1 映射到 u16 定点（`sc_float_to_u16fp`），1.0 取满 0xFFFF。
func fixedPointUnsigned(_ value: Float) -> UInt16 {
    let clamped = min(max(value, 0), 1)
    let scaled = UInt32(clamped * 0x1p16)
    return scaled >= 0xFFFF ? 0xFFFF : UInt16(scaled)
}

/// 滚动：-1…1 映射到 i16 定点（`sc_float_to_i16fp`），1.0 取 0x7FFF，-1.0 取 0x8000。
func fixedPointSigned(_ value: Float) -> Int16 {
    let clamped = min(max(value, -1), 1)
    let scaled = Int32(clamped * 0x1p15)
    return Int16(truncatingIfNeeded: scaled >= 0x7FFF ? 0x7FFF : scaled)
}

private func normalizeScroll(_ value: Int) -> Float {
    Float(value) / 16
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> Int(shift)) & 0xFF))
        }
    }

    mutating func appendBigEndian(_ value: Int16) {
        appendBigEndian(UInt16(bitPattern: value))
    }
}

private extension Data {
    /// 取前 `maxLength` 字节；若切在多字节字符中间，就退到该字符之前。
    func prefix(truncatingOnUTF8Boundary maxLength: Int) -> Data {
        guard count > maxLength, startIndex + maxLength < endIndex else { return self }

        let cut = startIndex + maxLength
        var characterStart = cut - 1
        while characterStart > startIndex, self[characterStart] & 0xC0 == 0x80 {
            characterStart -= 1
        }

        let needed: Int
        switch self[characterStart] & 0xF0 {
        case 0xF0: needed = 4
        case 0xE0: needed = 3
        case 0xC0: needed = 2
        default: needed = 1
        }

        // 这个字符完整落在上限内 -> 正好切在字符边界；否则切在它前面。
        return characterStart + needed <= cut
            ? prefix(maxLength)
            : prefix(characterStart - startIndex)
    }
}
