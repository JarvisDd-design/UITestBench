import CoreGraphics

/// 把视图里的鼠标动作翻译成控制消息。
///
/// 只负责「翻译」：坐标换算、黑边丢弃、拖动生命周期。字节怎么写到 socket 由
/// `MirrorInputSink` 的实现负责，因此这一层可以脱离设备单测。
///
/// 视图坐标原点在左上角（视图侧用 `isFlipped` 保证），设备坐标原点是画面左上角。
public final class MirrorInputController {
    private let sink: MirrorInputSink
    private var mapper: CoordinateMapper
    /// 鼠标左键是否按着。没按下就不该发 MOVE/UP，否则设备会收到莫名其妙的触摸。
    private var isPressed = false

    public init(sink: MirrorInputSink, viewSize: CGSize, videoSize: CGSize) {
        self.sink = sink
        self.mapper = CoordinateMapper(viewSize: viewSize, deviceSize: videoSize)
        pushScreenSize()
    }

    /// 窗口尺寸变化（用户拖分隔条、进全屏）。
    public func update(viewSize: CGSize) {
        mapper = CoordinateMapper(viewSize: viewSize, deviceSize: mapper.deviceSize)
    }

    /// 画面尺寸变化（转屏、换机型后重连）。
    public func update(videoSize: CGSize) {
        mapper = CoordinateMapper(viewSize: mapper.viewSize, deviceSize: videoSize)
        pushScreenSize()
    }

    public func mouseDown(at point: CGPoint) {
        guard let device = mapper.devicePoint(from: point) else { return }
        isPressed = true
        try? sink.touchDown(at: device)
    }

    public func mouseDragged(to point: CGPoint) {
        guard isPressed, let device = clampedDevicePoint(point) else { return }
        try? sink.touchMove(to: device)
    }

    public func mouseUp(at point: CGPoint) {
        guard isPressed else { return }
        isPressed = false
        // 松手一律夹到画面内再发：鼠标滑出窗口时手指仍在屏幕上，不发 UP 会让设备
        // 一直停在按下的状态，之后所有点击都变成拖动。
        guard let device = clampedDevicePoint(point) else { return }
        try? sink.touchUp(at: device)
    }

    /// 滚轮和点击不同：点击落在黑边上不该发生任何事，但滚轮是「对着这一屏滚」，
    /// 鼠标偏出画面一点仍然应当生效。
    ///
    /// 越界的那一轴落到画面中线，而不是贴到边缘——屏幕边缘常常是状态栏、
    /// 侧滑抽屉或者留白，手势落在那里要么没反应，要么误触。
    public func scroll(at point: CGPoint, horizontal: Int, vertical: Int) {
        let rect = mapper.contentRect
        guard rect.width > 0, rect.height > 0 else { return }

        let inFrame = CGPoint(
            x: point.x >= rect.minX && point.x <= rect.maxX ? point.x : rect.midX,
            y: point.y >= rect.minY && point.y <= rect.maxY ? point.y : rect.midY
        )
        guard let device = mapper.devicePoint(from: inFrame) else { return }
        try? sink.scroll(at: device, horizontal: horizontal, vertical: vertical)
    }

    public func pressKey(_ key: AndroidKey) {
        try? sink.pressKey(key)
    }

    public func sendText(_ text: String) {
        try? sink.sendText(text)
    }

    /// 服务端拿消息里的屏宽高和视频帧尺寸比对，不一致整条丢弃。所以只在这里更新，
    /// 保证它永远和坐标映射同源。
    private func pushScreenSize() {
        let size = mapper.deviceSize
        guard size.width > 0, size.height > 0 else { return }
        sink.updateScreenSize(width: Int(size.width), height: Int(size.height))
    }

    /// 拖动中鼠标可以跑出画面：坐标夹到画面边缘，而不是整条事件丢掉。
    private func clampedDevicePoint(_ point: CGPoint) -> CGPoint? {
        let rect = mapper.contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }

        let clamped = CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
        guard let device = mapper.devicePoint(from: clamped) else { return nil }

        // 画面右下角换算出的是 width/height 本身，设备那边最大的合法像素是 size-1。
        let size = mapper.deviceSize
        return CGPoint(
            x: min(max(device.x, 0), size.width - 1),
            y: min(max(device.y, 0), size.height - 1)
        )
    }
}
