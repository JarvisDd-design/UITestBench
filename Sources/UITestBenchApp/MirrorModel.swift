import AVFoundation
import Combine
import CoreMedia
import SwiftUI
import UITestBenchCore

/// 管画面这一路：校验随包组件、建会话、起解码、把帧塞进显示层。
@MainActor
final class MirrorModel: ObservableObject {
    @Published private(set) var state: MirrorState = .idle

    let display = MirrorDisplayView()

    private let adb: URL
    private let jar: URL
    private var engine: MirrorEngine?
    private var session: ScrcpySession?
    private var inputController: MirrorInputController?

    init(sdkDirectory: URL) {
        self.adb = sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        self.jar = AppResources.scrcpyServerJarURL ?? URL(fileURLWithPath: "/nonexistent/scrcpy-server.jar")
    }

    func start(serial: String) {
        stop()

        do {
            try ScrcpyServerJar.validate(jar)
        } catch {
            state = .failed("画面组件缺失或已损坏，请重新安装应用。")
            return
        }

        let session = ScrcpySession(adb: adb, jar: jar, serial: serial)
        self.session = session
        let layer = display.displayLayer
        let engine = MirrorEngine(
            source: ScrcpyMirrorSource(session: session),
            onFrame: { sample in
                // 显示层允许在任意线程入队，省掉每帧一次主线程跳跃。
                MirrorDisplayView.enqueue(sample, to: layer)
            },
            onState: { [weak self] state in
                DispatchQueue.main.async {
                    self?.apply(state)
                }
            }
        )
        self.engine = engine
        state = .starting

        Task {
            do {
                try await engine.start()
                attachInput(session: session)
            } catch {
                // 失败状态已由引擎回报，这里只需要吞掉异常。
            }
        }
    }

    private func apply(_ state: MirrorState) {
        self.state = state
        if case let .streaming(width, height) = state {
            // 转屏会换一组宽高；控制消息里带的尺寸必须跟着变，否则服务端直接丢弃。
            inputController?.update(videoSize: CGSize(width: width, height: height))
        }
    }

    /// 画面跑起来之后才能开控制通道——服务端要先接受连接。
    ///
    /// 控制通道连不上不影响看画面，只是点不动，所以这里不把整个启动判为失败。
    private func attachInput(session: ScrcpySession) {
        guard session === self.session, let handshake = session.handshake else { return }
        do {
            // 滚轮不用 INJECT_SCROLL_EVENT：Android 14 AOSP 镜像上实测，滚动消息确实进了
            // 分派器（坐标正确、没有丢弃日志），应用层却不响应；同一坐标换成拖动立刻生效。
            // 所以滚轮走「按下 → 挪几步 → 抬起」这条一定能工作的路。
            let sink = DragScrollSink(base: ScrcpyInputSink(stream: try session.openControlChannel()))
            let controller = MirrorInputController(
                sink: sink,
                viewSize: display.bounds.size,
                videoSize: CGSize(
                    width: Int(handshake.session.width),
                    height: Int(handshake.session.height)
                )
            )
            inputController = controller
            display.inputController = controller
        } catch {
            inputController = nil
            display.inputController = nil
        }
    }

    /// 设备按键：画面下方的返回/主页/多任务按钮。
    func pressKey(_ key: AndroidKey) {
        inputController?.pressKey(key)
    }

    func stop() {
        inputController = nil
        display.inputController = nil
        session = nil
        guard let engine else {
            state = .idle
            return
        }
        self.engine = nil
        state = .idle
        display.displayLayer.flush()
        Task { await engine.stop() }
    }
}

/// 只干一件事：把 CMSampleBuffer 交给 AVSampleBufferDisplayLayer。
final class MirrorDisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// 鼠标事件交给它翻译成控制消息。画面还没连上时是 nil，点了不会有反应。
    var inputController: MirrorInputController? {
        didSet { syncViewSize() }
    }

    /// 触控板的像素增量要攒成轮齿，否则一次轻扫会发出几十条消息。
    private var scrollAccumulator = ScrollNotchAccumulator()
    /// 手停下来后把没攒满一格的零头放出去（慢慢滚的人不能一直没反应）。
    private var scrollFlush: DispatchWorkItem?
    private var lastScrollPoint = CGPoint.zero
    private static let scrollFlushDelay: TimeInterval = 0.12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不提供 nib 加载")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        syncViewSize()
    }

    // MARK: - 鼠标与键盘

    override var acceptsFirstResponder: Bool { true }

    /// 窗口没激活时的第一次点击也要算数，否则要「点两下才有反应」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputController?.mouseDown(at: imagePoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        inputController?.mouseDragged(to: imagePoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        inputController?.mouseUp(at: imagePoint(for: event))
    }

    override func scrollWheel(with event: NSEvent) {
        let point = imagePoint(for: event)
        lastScrollPoint = point

        let notches = scrollAccumulator.notches(
            delta: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas
        )
        guard notches != 0 else {
            scheduleScrollFlush()
            return
        }

        scrollFlush?.cancel()
        scrollFlush = nil
        sendScroll(notches: notches, at: point)
    }

    private func sendScroll(notches: Int, at point: CGPoint) {
        let direction = notches > 0 ? 1 : -1
        for _ in 0..<abs(notches) {
            inputController?.scroll(at: point, horizontal: 0, vertical: direction)
        }
    }

    /// 慢慢滚时一次增量可能只有几个点，永远攒不满一格。停手 120 ms 后
    /// 把零头放出去，至少滚一格——否则用户会觉得「滚轮没反应」。
    private func scheduleScrollFlush() {
        scrollFlush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollFlush = nil
            let notches = self.scrollAccumulator.flush()
            guard notches != 0 else { return }
            self.sendScroll(notches: notches, at: self.lastScrollPoint)
        }
        scrollFlush = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollFlushDelay, execute: item)
    }

    override func keyDown(with event: NSEvent) {
        // 翻译规则在 KeyboardInput 里单测；这里只负责把 NSEvent 拆成字符和修饰键。
        guard let action = KeyboardInput.action(
            for: event.characters ?? "",
            modifiers: Self.keyboardModifiers(for: event)
        ) else {
            // Tab、⌘ 系列、方向键等交给 AppKit，保持 Mac 上应有的行为。
            super.keyDown(with: event)
            return
        }

        switch action {
        case let .text(text):
            inputController?.sendText(text)
        case let .key(key):
            inputController?.pressKey(key)
        case .ignored:
            // Esc 仍然要能把坞抽屉收起来；交给响应链上的 cancelOperation。
            if event.keyCode == 53 {
                NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: self)
            }
            return
        }
    }

    private static func keyboardModifiers(for event: NSEvent) -> KeyboardInput.Modifiers {
        var modifiers: KeyboardInput.Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    private func syncViewSize() {
        inputController?.update(viewSize: bounds.size)
    }

    /// AppKit 的事件坐标原点在左下角，画面坐标原点在左上角。
    private func imagePoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    static func enqueue(_ sample: CMSampleBuffer, to layer: AVSampleBufferDisplayLayer) {
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sample)
    }
}

struct VideoSurface: NSViewRepresentable {
    let display: MirrorDisplayView

    func makeNSView(context: Context) -> MirrorDisplayView {
        display
    }

    func updateNSView(_ nsView: MirrorDisplayView, context: Context) {}
}
