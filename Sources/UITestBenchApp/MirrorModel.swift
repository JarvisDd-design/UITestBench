import AVFoundation
import Carbon
import Combine
import CoreMedia
import SwiftUI
import UITestBenchCore

/// 延迟 HUD 的一次取样。只在 ⌥⌘L 打开时刷新。
struct MirrorHUDReport: Equatable {
    var snapshot: MirrorLatencySnapshot = .empty
    var droppedFrames = 0
    var quality: MirrorQualityMode = .sharp
    /// 视频 socket 内核缓冲里堆着的字节数，反压诊断用。
    var backlogBytes = 0

    static let empty = MirrorHUDReport()
}

/// 管画面这一路：校验随包组件、建会话、起解码、把帧塞进显示层。
@MainActor
final class MirrorModel: ObservableObject {
    @Published private(set) var state: MirrorState = .idle
    /// 控制通道是否真的可用。画面在、输入通道单独失败时也必须为 false，
    /// 否则底胶囊的返回按钮看起来能点，实际什么都不会发生。
    @Published private(set) var canSendInput = false

    /// 用户亲手选过的档位；nil 表示没选过，按机型走默认。
    /// 单独发布一份是为了让设置面板的 Picker 能跟着刷新。
    @Published private(set) var storedQuality: MirrorQualityMode?

    /// 诊断浮层。隐藏功能，⌥⌘L 开合，不进正式界面。
    @Published private(set) var showsLatencyHUD = false
    @Published private(set) var hudReport = MirrorHUDReport.empty

    let display = MirrorDisplayView()

    private let adb: URL
    private let jar: URL
    private let qualityPreference = MirrorQualityPreference()
    private var engine: MirrorEngine?
    private var session: ScrcpySession?
    private var inputController: MirrorInputController?
    private var activeQuality: MirrorQualityMode = .sharp
    private var hudTask: Task<Void, Never>?

    init(sdkDirectory: URL) {
        self.adb = sdkDirectory
            .appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb")
        self.jar = AppResources.scrcpyServerJarURL ?? URL(fileURLWithPath: "/nonexistent/scrcpy-server.jar")
        self.storedQuality = qualityPreference.storedMode
    }

    // MARK: - 画质档位

    /// 当前机型该用哪一档：用户选过就听用户的，没选过大屏默认流畅。
    func quality(for profile: DeviceProfile) -> MirrorQualityMode {
        qualityPreference.mode(for: profile)
    }

    /// 只落盘，不负责重连——重连由调用方（AppModel）在设备跑着的时候发起。
    func setQuality(_ mode: MirrorQualityMode) {
        guard qualityPreference.storedMode != mode else { return }
        qualityPreference.storedMode = mode
        storedQuality = mode
    }

    // MARK: - 画面

    func start(serial: String, profile: DeviceProfile) {
        stop()

        do {
            try ScrcpyServerJar.validate(jar)
        } catch {
            state = .failed("画面组件缺失或已损坏，请重新安装应用。")
            return
        }

        let quality = self.quality(for: profile)
        activeQuality = quality

        var configuration = ScrcpySessionConfiguration()
        configuration.maxSize = quality.maxSize
        configuration.maxFPS = quality.maxFPS
        configuration.videoBitRate = quality.videoBitRate

        let session = ScrcpySession(adb: adb, jar: jar, serial: serial, configuration: configuration)
        self.session = session

        // 槽位深度 1：解码线程只管把「最新一帧」放进去，旧的直接覆盖。
        // 显示跟不上时丢的是过期的帧，而不是排队等着越拖越久。
        let slot = display.frameSlot
        let monitor = display.latencyMonitor
        let source = ScrcpyMirrorSource(session: session)
        // 帧字节收齐就打个点：它和解码完成之间的差值是解码耗时，
        // 和操作时刻之间的差值是「本机 → Android → 编码 → 回传」那一段。
        source.onMediaPacket = {
            monitor.recordFrameStart(at: ProcessInfo.processInfo.systemUptime)
        }
        let engine = MirrorEngine(
            source: source,
            onFrame: { sample in
                // 只落槽，不入队。入队由显示层的喂帧循环按需取走。
                monitor.recordArrival(at: ProcessInfo.processInfo.systemUptime)
                slot.store(sample)
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
        switch state {
        case let .streaming(width, height):
            // 转屏会换一组宽高；控制消息里带的尺寸必须跟着变，否则服务端直接丢弃。
            inputController?.update(videoSize: CGSize(width: width, height: height))
            display.startFeeding()
        case .ended, .failed:
            display.stopFeeding()
        case .idle, .starting:
            break
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
            let monitor = display.latencyMonitor
            controller.onInput = {
                monitor.recordInput(at: ProcessInfo.processInfo.systemUptime)
            }
            inputController = controller
            display.inputController = controller
            canSendInput = true
        } catch {
            inputController = nil
            display.inputController = nil
            canSendInput = false
        }
    }

    /// 设备按键：底胶囊的返回按钮和 ⌘[ 都走这里。
    func pressKey(_ key: AndroidKey) {
        inputController?.pressKey(key)
    }

    /// 中文提交：服务端没有输入法，只能借设备剪贴板再补一次粘贴键。
    func setClipboardAndPaste(_ text: String) {
        inputController?.setClipboardAndPaste(text)
    }

    func stop() {
        inputController = nil
        display.inputController = nil
        canSendInput = false
        session = nil
        display.stopFeeding()
        guard let engine else {
            state = .idle
            return
        }
        self.engine = nil
        state = .idle
        display.displayLayer.flush()
        Task { await engine.stop() }
    }

    // MARK: - 延迟 HUD

    func toggleLatencyHUD() {
        setShowsLatencyHUD(!showsLatencyHUD)
    }

    func setShowsLatencyHUD(_ visible: Bool) {
        guard visible != showsLatencyHUD else { return }
        showsLatencyHUD = visible
        hudTask?.cancel()
        hudTask = nil
        guard visible else {
            hudReport = .empty
            return
        }
        refreshHUD()
        hudTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.showsLatencyHUD else { return }
                self.refreshHUD()
            }
        }
    }

    private func refreshHUD() {
        let now = ProcessInfo.processInfo.systemUptime
        hudReport = MirrorHUDReport(
            snapshot: display.latencyMonitor.snapshot(now: now),
            droppedFrames: display.frameSlot.droppedFrameCount,
            quality: activeQuality,
            backlogBytes: session?.videoBacklogBytes ?? 0
        )
    }
}

/// 喂帧循环的开关。解码线程只碰槽位，开关只在主线程和喂帧队列之间挪，
/// 加锁是因为两边要读到同一个值。
final class MirrorFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }

}

/// 干两件事：把 CMSampleBuffer 交给 AVSampleBufferDisplayLayer，
/// 以及把键盘事件翻译成控制消息（含中文组字）。
final class MirrorDisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// 待显示的最新一帧。深度 1，显示跟不上就覆盖旧的。
    let frameSlot = MirrorFrameSlot()
    /// 显示层的时间轴，见 init 里的注释。
    private var displayTimebase: CMTimebase?
    /// HUD 用的延迟统计。
    let latencyMonitor = MirrorLatencyMonitor()

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

    /// 喂帧线程：这里只做「取帧 → 入队」，不碰解码。
    private let feedQueue = DispatchQueue(label: "com.uitestbench.display.feed")
    private let feedState = MirrorFeedState()
    /// 槽里没帧时最多等这么久（来了新帧会被立刻叫醒），别把 CPU 烧在空转上。
    private static let feedIdleWait: TimeInterval = 0.05
    /// 显示层时钟跟设备时钟差超过这么多秒，就重锚一次。
    private static let clockResyncThreshold: TimeInterval = 0.25

    /// 组字中的拼音/候选文字。只做提示，真正上屏的是输入法提交的结果。
    private let compositionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.isHidden = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        return label
    }()
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var lastClickPoint = CGPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        // 显示层必须有一个自己走的时间轴，否则它会拿帧的设备时间戳去跟内部时钟比：
        // 设备时钟跟主机时钟差着几小时，帧就全被排到「未来」或者「过去」，队列越攒越长，
        // 画面停住、点哪儿都不刷新（切档 flush 一下才跳到当时的画面）。
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let timebase {
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
            self.displayTimebase = timebase
        }
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        addSubview(compositionLabel)
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

    // MARK: - 喂帧

    /// 收到第一帧、画面尺寸定下来之后再开喂帧循环，免得空等一下午。
    func startFeeding() {
        guard !feedState.isActive else { return }
        feedState.setActive(true)
        frameSlot.resetDroppedFrameCount()
        latencyMonitor.reset()
        startFeedLoop()
    }

    func stopFeeding() {
        feedState.setActive(false)
        displayLayer.stopRequestingMediaData()
        frameSlot.flush()
    }

    private func startFeedLoop() {
        let slot = frameSlot
        let monitor = latencyMonitor
        let state = feedState
        let layer = displayLayer
        let timebase = displayTimebase
        feedQueue.async {
            Self.runFeedLoop(
                slot: slot,
                monitor: monitor,
                state: state,
                layer: layer,
                timebase: timebase
            )
        }
    }

    /// 喂帧循环：拿到一帧就塞给显示层，**不看 `isReadyForMoreMediaData`**。
    ///
    /// 这个标志在 `AVSampleBufferDisplayLayer` 上不可靠：实测它会一直报 false，
    /// 跟着它走就是 1.5.0 之前那版的黑屏 + 冻结；只在它说 false 时丢帧，
    /// 真机上 6 秒也进不了 2 帧（老大的机器上实测 1.2fps），画面自然又卡又糊。
    /// 1.4.3 能用的原因就是「有帧就塞」，这里回到那条路上来，
    /// 只在显示层自己报错（`.failed`）时清一次。
    private static func runFeedLoop(
        slot: MirrorFrameSlot,
        monitor: MirrorLatencyMonitor,
        state: MirrorFeedState,
        layer: AVSampleBufferDisplayLayer,
        timebase: CMTimebase?
    ) {
        var anchorPTS = CMTime.invalid
        var anchorWall: TimeInterval = 0
        while state.isActive {
            guard let entry = slot.waitForEntry(timeout: feedIdleWait) else { continue }
            if layer.status == .failed {
                layer.flush()
            }
            let now = ProcessInfo.processInfo.systemUptime
            let pts = CMSampleBufferGetPresentationTimeStamp(entry.sample)
            if let timebase, pts.isValid, pts.isNumeric {
                if !anchorPTS.isValid {
                    // 把显示层的时钟对到第一帧上，两边从此一起走。
                    CMTimebaseSetTime(timebase, time: pts)
                    anchorPTS = pts
                    anchorWall = now
                } else {
                    let streamElapsed = CMTimeGetSeconds(pts) - CMTimeGetSeconds(anchorPTS)
                    let wallElapsed = now - anchorWall
                    // 设备时钟跟主机时钟会跑偏，偏多了就把时间轴重新对一次。
                    // 不 flush：积压的旧帧会立刻变成「过期」，显示层自己会跳过它们，
                    // 不会黑一下。
                    if abs(streamElapsed - wallElapsed) > clockResyncThreshold {
                        CMTimebaseSetTime(timebase, time: pts)
                        anchorPTS = pts
                        anchorWall = now
                    }
                }
            }
            let enqueueStarted = ProcessInfo.processInfo.systemUptime
            layer.enqueue(entry.sample)
            // 入队本身不在这条链路的计时里，但它一旦变慢就会拖住下一帧的取用，
            // 所以单独记一笔，出问题时能直接排掉显示层。
            monitor.recordEnqueue(ProcessInfo.processInfo.systemUptime - enqueueStarted)
            monitor.recordDisplay(arrival: entry.arrival, at: now)
        }
    }

    // MARK: - 鼠标与键盘

    override var acceptsFirstResponder: Bool { true }

    /// 画面是触摸面：拖拽要交给设备做滑动，不能变成拖窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 窗口没激活时的第一次点击也要算数，否则要「点两下才有反应」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastClickPoint = convert(event.locationInWindow, from: nil)
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
        // 分流规则在 KeyboardRouting 里单测；这里只负责把 NSEvent 拆成字符和修饰键。
        let route = KeyboardRouting.route(
            characters: event.characters ?? "",
            modifiers: KeyboardInput.Modifiers(event: event),
            isASCIIInputSource: Self.isASCIIInputSource,
            hasMarkedText: hasMarkedText()
        )

        switch route {
        case let .fastPath(text):
            inputController?.sendText(text)
        case let .deviceKey(key):
            inputController?.pressKey(key)
        case .compose:
            // 交给输入法：组字中或中文键盘下的按键都要走这一条，
            // 提交结果再由 insertText 决定送文字还是走剪贴板。
            interpretKeyEvents([event])
        case .ignored:
            // Esc 仍然要能把坞抽屉收起来；交给响应链上的 cancelOperation。
            if event.keyCode == 53 {
                NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: self)
            }
        case .system:
            // Tab、⌘ 系列、方向键等交给 AppKit，保持 Mac 上应有的行为。
            super.keyDown(with: event)
        }
    }

    /// 当前键盘是不是纯 ASCII 输入源。中文/日文之类的输入法要交给组字流程，
    /// 不能把 `characters` 直接当文字发出去（那时候拿到的是拼音字母）。
    static var isASCIIInputSource: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return true
        }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return true
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private func syncViewSize() {
        inputController?.update(viewSize: bounds.size)
    }

    /// AppKit 的事件坐标原点在左下角，画面坐标原点在左上角。
    private func imagePoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func updateCompositionLabel() {
        guard !markedText.isEmpty else {
            compositionLabel.isHidden = true
            return
        }
        compositionLabel.stringValue = markedText
        compositionLabel.sizeToFit()
        var size = compositionLabel.frame.size
        size.width = min(size.width + 10, max(bounds.width - 8, 10))
        size.height = max(size.height, 16)
        var origin = CGPoint(x: lastClickPoint.x - 2, y: lastClickPoint.y + 6)
        origin.x = max(2, min(origin.x, bounds.width - size.width - 2))
        origin.y = max(2, min(origin.y, bounds.height - size.height - 2))
        compositionLabel.frame = NSRect(origin: origin, size: size)
        compositionLabel.isHidden = false
    }
}

// MARK: - NSTextInputClient

extension MirrorDisplayView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(from: string)
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        compositionLabel.isHidden = true

        switch KeyboardRouting.routeCommittedText(text) {
        case let .injectText(ascii):
            inputController?.sendText(ascii)
        case let .clipboardPaste(payload):
            inputController?.setClipboardAndPaste(payload)
        case .nothing:
            break
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            inputController?.pressKey(.enter)
        case #selector(NSResponder.cancelOperation(_:)):
            // 组字中第一次 Esc 只取消组字，真的取消搜索/抽屉还留给响应链。
            if hasMarkedText() {
                markedText = ""
                markedSelection = NSRange(location: 0, length: 0)
                compositionLabel.isHidden = true
                return
            }
            NSApp.sendAction(selector, to: nil, from: self)
        default:
            // 退格、方向键在设备端没有对应消息，组字过程中的编辑由输入法自己处理。
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plainText(from: string)
        markedSelection = selectedRange
        updateCompositionLabel()
    }

    func unmarkText() {
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        compositionLabel.isHidden = true
    }

    func selectedRange() -> NSRange {
        markedSelection
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let anchor = convert(
            NSRect(x: lastClickPoint.x, y: lastClickPoint.y - 18, width: 1, height: 18),
            to: nil
        )
        return window.convertToScreen(anchor)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    static func plainText(from string: Any) -> String {
        if let attributed = string as? NSAttributedString {
            return attributed.string
        }
        if let plain = string as? String {
            return plain
        }
        return ""
    }
}

struct VideoSurface: NSViewRepresentable {
    let display: MirrorDisplayView

    func makeNSView(context: Context) -> MirrorDisplayView {
        display
    }

    func updateNSView(_ nsView: MirrorDisplayView, context: Context) {}
}

extension KeyboardInput.Modifiers {
    /// 把 NSEvent 的修饰键转成翻译层用的集合。Shift 也记下来，
    /// 只用来区分 ⌘⇧[ 这类组合；文字大小写仍由 `characters` 决定。
    init(event: NSEvent) {
        var modifiers: KeyboardInput.Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
