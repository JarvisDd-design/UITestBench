import CoreGraphics
import Foundation

public enum ScrcpyInputError: Error, Equatable {
    case screenSizeUnknown
}

/// 把鼠标与键盘事件变成 scrcpy 控制消息，写进常驻的控制 socket。
///
/// 坐标是**画面坐标系**（解码出来的帧尺寸），不是设备物理分辨率：
/// 开了 `max_size` 之后两者不同，服务端会按消息里带的宽高自行换算。
///
/// 写操作排在一条串行队列上：点击来自主线程，拖动与滚轮也可能来自别的线程，
/// 一条消息被从中间劈开就全乱了；把写挪出主线程，socket 一慢也不会卡住界面。
/// 锁只保护屏宽高和剪贴板序号，不跨 IO 持有。
public protocol MirrorInputSink: AnyObject {
    func updateScreenSize(width: Int, height: Int)
    func touchDown(at point: CGPoint) throws
    func touchMove(to point: CGPoint) throws
    func touchUp(at point: CGPoint) throws
    func tap(at point: CGPoint) throws
    func scroll(at point: CGPoint, horizontal: Int, vertical: Int) throws
    func pressKey(_ key: AndroidKey) throws
    func sendText(_ text: String) throws
    /// 把文字写进设备剪贴板，再补一次粘贴键。中文只能走这条路。
    func setClipboardAndPaste(text: String) throws
    /// 等排队中的写操作全部落盘；停止和测试用。
    func flushPendingWrites()
}

public final class ScrcpyInputSink: MirrorInputSink {
    private let stream: ByteStream
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.uitestbench.control.write")
    private var screenWidth = 0
    private var screenHeight = 0
    private var clipboardSequence: UInt64 = 0

    public init(stream: ByteStream) {
        self.stream = stream
    }

    public func updateScreenSize(width: Int, height: Int) {
        lock.lock()
        screenWidth = max(0, width)
        screenHeight = max(0, height)
        lock.unlock()
    }

    public func touchDown(at point: CGPoint) throws {
        try touch(.down, at: point, pressure: 1)
    }

    public func touchMove(to point: CGPoint) throws {
        try touch(.move, at: point, pressure: 1)
    }

    public func touchUp(at point: CGPoint) throws {
        try touch(.up, at: point, pressure: 0)
    }

    public func tap(at point: CGPoint) throws {
        try touchDown(at: point)
        try touchUp(at: point)
    }

    public func scroll(at point: CGPoint, horizontal: Int, vertical: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard screenWidth > 0, screenHeight > 0 else {
            throw ScrcpyInputError.screenSizeUnknown
        }
        let x = clamp(point.x, upperBound: screenWidth)
        let y = clamp(point.y, upperBound: screenHeight)
        // 滚轮事件是 SOURCE_MOUSE，系统按鼠标指针位置找窗口。我们从不移动真实指针，
        // 不先发一条悬停消息的话，指针位置是未知的，滚动会被丢到别处——表现就是
        // 「滚轮完全没反应」。官方客户端靠鼠标移动顺带做了这件事，这里显式补上。
        let hover = ScrcpyControlMessage.touch(
            action: .hoverMove,
            pointerID: ScrcpyProtocol.pointerIDMouse,
            x: x,
            y: y,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            pressure: 1
        )
        let scroll = ScrcpyControlMessage.scroll(
            x: x,
            y: y,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            horizontal: horizontal,
            vertical: vertical
        )
        enqueue([hover.encoded(), scroll.encoded()])
    }

    public func pressKey(_ key: AndroidKey) throws {
        enqueue(keyPress(key))
    }

    public func sendText(_ text: String) throws {
        enqueue([ScrcpyControlMessage.text(text).encoded()])
    }

    public func setClipboardAndPaste(text: String) throws {
        guard !text.isEmpty else { return }

        lock.lock()
        clipboardSequence &+= 1
        let sequence = clipboardSequence
        lock.unlock()

        // `paste: true` 就够：服务端收到这一条会自己写剪贴板再注入粘贴键。
        // 再补一次 KEYCODE_PASTE 会粘两遍（「好的」变「好的好的」），实测确认过。
        enqueue([ScrcpyControlMessage.setClipboard(sequence: sequence, paste: true, text: text).encoded()])
    }

    public func flushPendingWrites() {
        writeQueue.sync {}
    }

    private func keyPress(_ key: AndroidKey) -> [Data] {
        [
            ScrcpyControlMessage.keycode(action: .down, keycode: key.rawValue).encoded(),
            ScrcpyControlMessage.keycode(action: .up, keycode: key.rawValue).encoded(),
        ]
    }

    /// 排进写队列，立刻返回。写失败只意味着这条消息没送出去，和之前 `try?`
    /// 吞掉错误的表现一致；界面不会因为控制通道抖动而卡住。
    private func enqueue(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        writeQueue.async { [stream] in
            for payload in payloads {
                do {
                    try stream.write(payload)
                } catch {
                    return
                }
            }
        }
    }

    private func touch(_ action: ScrcpyControlAction, at point: CGPoint, pressure: Float) throws {
        lock.lock()
        defer { lock.unlock() }
        guard screenWidth > 0, screenHeight > 0 else {
            throw ScrcpyInputError.screenSizeUnknown
        }
        let message = ScrcpyControlMessage.touch(
            action: action,
            pointerID: ScrcpyProtocol.pointerIDMouse,
            x: clamp(point.x, upperBound: screenWidth),
            y: clamp(point.y, upperBound: screenHeight),
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            pressure: pressure
        )
        enqueue([message.encoded()])
    }

    /// 取整并夹到 `0...upperBound-1`：点在边缘上时不能越界，否则服务端会丢事件。
    private func clamp(_ value: CGFloat, upperBound: Int) -> Int {
        let rounded = Int(value.rounded())
        return min(max(rounded, 0), upperBound - 1)
    }
}
