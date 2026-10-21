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
/// 写操作由一把锁串行化——点击来自主线程，拖动与滚轮也可能来自别的线程，
/// 一条消息被从中间劈开就全乱了。
public protocol MirrorInputSink: AnyObject {
    func updateScreenSize(width: Int, height: Int)
    func touchDown(at point: CGPoint) throws
    func touchMove(to point: CGPoint) throws
    func touchUp(at point: CGPoint) throws
    func tap(at point: CGPoint) throws
    func scroll(at point: CGPoint, horizontal: Int, vertical: Int) throws
    func pressKey(_ key: AndroidKey) throws
    func sendText(_ text: String) throws
}

public final class ScrcpyInputSink: MirrorInputSink {
    private let stream: ByteStream
    private let lock = NSLock()
    private var screenWidth = 0
    private var screenHeight = 0

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
        try stream.write(
            ScrcpyControlMessage.touch(
                action: .hoverMove,
                pointerID: ScrcpyProtocol.pointerIDMouse,
                x: x,
                y: y,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                pressure: 1
            ).encoded()
        )
        let message = ScrcpyControlMessage.scroll(
            x: x,
            y: y,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            horizontal: horizontal,
            vertical: vertical
        )
        try stream.write(message.encoded())
    }

    public func pressKey(_ key: AndroidKey) throws {
        lock.lock()
        defer { lock.unlock() }
        let down = ScrcpyControlMessage.keycode(action: .down, keycode: key.rawValue)
        let up = ScrcpyControlMessage.keycode(action: .up, keycode: key.rawValue)
        try stream.write(down.encoded())
        try stream.write(up.encoded())
    }

    public func sendText(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try stream.write(ScrcpyControlMessage.text(text).encoded())
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
        try stream.write(message.encoded())
    }

    /// 取整并夹到 `0...upperBound-1`：点在边缘上时不能越界，否则服务端会丢事件。
    private func clamp(_ value: CGFloat, upperBound: Int) -> Int {
        let rounded = Int(value.rounded())
        return min(max(rounded, 0), upperBound - 1)
    }
}
