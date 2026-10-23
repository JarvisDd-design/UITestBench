import AppKit
import SwiftUI
import UITestBenchCore

/// 手机窗口：无边框、可等比缩放。坞、底胶囊、抽屉都是它的子面板。
///
/// 无边框窗口默认不能成为 key/main，必须由子类打开，否则镜像画面收不到键盘。
@MainActor
final class PhoneWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 手机窗口的生命周期、尺寸、缩放与置顶。
///
/// 面板由 `FloatingPanelsController` 创建并挂成子窗口；这里只负责手机本身，
/// 以及在手机尺寸/屏幕变化后通知面板重排。
@MainActor
final class BenchWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let autosaveName = "UITestBench.PhoneWindow"

    @Published private(set) var isAlwaysOnTop = false
    @Published private(set) var isFittedToScreen = false

    private(set) weak var phoneWindow: NSWindow?
    private(set) var panels: FloatingPanelsController?

    private weak var app: AppModel?
    private var storedFitFrame: CGRect?
    private var isApplyingFrame = false
    private var clampWork: DispatchWorkItem?
    private var isGroupDragging = false
    private var dragTimer: Timer?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 挂载

    func attach(_ window: NSWindow, app: AppModel) {
        guard phoneWindow !== window else { return }
        phoneWindow = window
        self.app = app
        window.delegate = self
        configure(window)

        restoreFrame(in: window, profile: app.currentProfile)

        let panels = FloatingPanelsController(app: app)
        self.panels = panels
        panels.attach(to: window)
        panels.applyTheme(app.theme.mode)

        updateLimits(for: app.currentProfile, in: window)
        panels.refresh()
    }

    private func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.resizable)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.autosaveName)

        // 系统交通灯全部隐藏，换成坞顶自绘的三枚圆点。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - 尺寸

    private var fallbackScreen: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func restoreFrame(in window: NSWindow, profile: DeviceProfile) {
        let screen = window.screen?.visibleFrame ?? fallbackScreen
        let restored = window.setFrameUsingName(Self.autosaveName)
        var frame = window.frame
        let hasUsableFrame = restored && frame.width > 40 && frame.height > 40

        if !hasUsableFrame {
            let width = min(
                PhoneLayoutCalculator.defaultScreenWidth,
                PhoneLayoutCalculator.maximumScreenWidth(visibleSize: screen.size, profile: profile)
            )
            let size = PhoneLayoutCalculator.frameSize(forScreenWidth: width, profile: profile)
            frame = CGRect(
                x: screen.midX - size.width / 2,
                y: screen.maxY - size.height - 60,
                width: size.width,
                height: size.height
            )
        }

        // 旧版本保存的大窗、换屏幕后的越界位置都夹回来；宽度不动，高度按当前机型重算。
        frame = normalizedFrame(frame, profile: profile, screen: screen, keepTopEdge: hasUsableFrame)
        apply(frame, to: window)
    }

    private func normalizedFrame(
        _ frame: CGRect,
        profile: DeviceProfile,
        screen: CGRect,
        keepTopEdge: Bool
    ) -> CGRect {
        let size = fittedFrameSize(forWidth: frame.width, profile: profile, screen: screen)
        var result = CGRect(origin: frame.origin, size: size)
        if keepTopEdge {
            result.origin.y = frame.maxY - size.height
        }
        return clamped(result, screen: screen)
    }

    /// 保持宽度、按机型比例重算高度；宽度本身夹在最小值与当前屏幕能放下的最大值之间。
    private func fittedFrameSize(
        forWidth width: CGFloat,
        profile: DeviceProfile,
        screen: CGRect
    ) -> CGSize {
        let minSize = PhoneLayoutCalculator.frameSize(
            forScreenWidth: PhoneLayoutCalculator.minScreenWidth,
            profile: profile
        )
        let maxSize = PhoneLayoutCalculator.frameSize(
            forScreenWidth: PhoneLayoutCalculator.maximumScreenWidth(
                visibleSize: screen.size,
                profile: profile
            ),
            profile: profile
        )
        guard minSize.width > 0, maxSize.width > 0 else { return CGSize(width: 314, height: 680) }
        let width = min(max(width, minSize.width), maxSize.width)
        let size = PhoneLayoutCalculator.frameSize(
            forScreenWidth: width - PhoneLayoutCalculator.bezel * 2,
            profile: profile
        )
        return size.width > 0 ? size : minSize
    }

    private func clamped(_ frame: CGRect, screen: CGRect) -> CGRect {
        FloatingPanelLayoutCalculator.clampedPhoneFrame(
            frame,
            dockWidth: panels?.visibleDockWidth ?? DockMetrics.railWidth,
            capsuleHeight: PhoneLayoutCalculator.capsuleHeight,
            visibleScreen: screen
        )
    }

    private func updateLimits(for profile: DeviceProfile, in window: NSWindow) {
        let screen = window.screen?.visibleFrame ?? fallbackScreen
        let minSize = PhoneLayoutCalculator.frameSize(
            forScreenWidth: PhoneLayoutCalculator.minScreenWidth,
            profile: profile
        )
        let maxSize = PhoneLayoutCalculator.frameSize(
            forScreenWidth: PhoneLayoutCalculator.maximumScreenWidth(
                visibleSize: screen.size,
                profile: profile
            ),
            profile: profile
        )
        if minSize.width > 0, minSize.height > 0 {
            window.minSize = minSize
        }
        if maxSize.width > 0, maxSize.height > 0 {
            window.maxSize = maxSize
        }
        if window.frame.width > 0, window.frame.height > 0 {
            window.contentAspectRatio = window.frame.size
        }
    }

    private func apply(_ frame: CGRect, to window: NSWindow, display: Bool = true) {
        guard window.frame.integral != frame.integral else { return }
        isApplyingFrame = true
        window.setFrame(frame, display: display)
        isApplyingFrame = false
    }

    /// 换机型/自定义分辨率后，保持上边缘不动，从顶部往下长或缩。
    func profileDidChange(_ profile: DeviceProfile) {
        guard let window = phoneWindow else { return }
        let screen = window.screen?.visibleFrame ?? fallbackScreen
        let top = window.frame.maxY
        let size = fittedFrameSize(forWidth: window.frame.width, profile: profile, screen: screen)
        var frame = CGRect(
            x: window.frame.minX,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
        frame = clamped(frame, screen: screen)

        window.contentAspectRatio = frame.size
        apply(frame, to: window)
        updateLimits(for: profile, in: window)
        isFittedToScreen = false
        storedFitFrame = nil
        panels?.refresh()
    }

    func toggleFitToScreen() {
        guard let window = phoneWindow, let app else { return }
        let screen = window.screen?.visibleFrame ?? fallbackScreen

        if isFittedToScreen, let stored = storedFitFrame {
            let frame = normalizedFrame(stored, profile: app.currentProfile, screen: screen, keepTopEdge: true)
            apply(frame, to: window)
            panels?.refresh()
            storedFitFrame = nil
            isFittedToScreen = false
            return
        }

        storedFitFrame = window.frame
        let profile = app.currentProfile
        let maxWidth = PhoneLayoutCalculator.maximumScreenWidth(visibleSize: screen.size, profile: profile)
        let size = PhoneLayoutCalculator.frameSize(forScreenWidth: maxWidth, profile: profile)
        var frame = CGRect(
            x: window.frame.midX - size.width / 2,
            y: window.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        frame = clamped(frame, screen: screen)
        apply(frame, to: window)
        panels?.refresh()
        isFittedToScreen = true
    }

    // MARK: - 显隐与退出

    func close() {
        // 走 AppDelegate 的清理流程：先卸包、停模拟器，再退出。
        NSApp.terminate(nil)
    }

    /// 无边框窗口没有可用的最小化；黄点改为隐藏窗口，点 Dock 图标回来。
    func minimize() {
        panels?.hide()
        phoneWindow?.orderOut(nil)
    }

    func showPhone() {
        guard let window = phoneWindow else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panels?.show()
    }

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        let level: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
        phoneWindow?.level = level
        panels?.setLevel(level)
    }

    // MARK: - 整组拖动

    var phoneWindowOrigin: CGPoint? {
        phoneWindow?.frame.origin
    }

    /// 开始整组拖动：记下鼠标与手机原点，然后由定时器按固定节奏移动。
    ///
    /// 不用 SwiftUI 的手势事件逐帧移动：窗口跟着鼠标走之后，视图坐标系
    /// 也在动，手势拿到的位移会越来越小，窗口表现为一顿一顿的。
    func beginGroupDrag() {
        guard dragTimer == nil, let window = phoneWindow else { return }
        isGroupDragging = true
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(dragTick(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0
        // `.common` 包含事件跟踪模式，拖动期间也会照常触发。
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    @objc private func dragTick(_ timer: Timer) {
        // 鼠标已经在别处松开就自己收尾，不依赖手势的 onEnded。
        guard NSEvent.pressedMouseButtons & 0x1 != 0, let window = phoneWindow else {
            endGroupDrag()
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = CGPoint(
            x: dragStartOrigin.x + (mouse.x - dragStartMouse.x),
            y: dragStartOrigin.y + (mouse.y - dragStartMouse.y)
        )
        // 鼠标没动的帧不要重设窗口，免得白发一遍 move 通知与夹取任务。
        guard target != window.frame.origin else { return }
        // 子面板由 AppKit 跟随父窗口；这里只动手机。
        window.setFrameOrigin(target)
    }

    func endGroupDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        guard isGroupDragging else { return }
        isGroupDragging = false
        scheduleClamp()
    }

    func applyTheme(_ mode: ThemeMode) {
        panels?.applyTheme(mode)
    }

    func refreshPanels() {
        panels?.refresh()
    }

    func clickTarget(for window: NSWindow?) -> DockClickTarget {
        panels?.clickTarget(for: window) ?? .auxiliary
    }

    // MARK: - 窗口代理

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        panels?.hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame else { return }
        // 整组拖动期间每一帧都会走到这里；等手势结束再排一次夹取就够了。
        guard !isGroupDragging else { return }
        // 拖动期间不夹，停手 0.25s 后再把整组拉回安全区。
        scheduleClamp()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingFrame else { return }
        isFittedToScreen = false
        storedFitFrame = nil
        panels?.refresh()
        scheduleClamp()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = phoneWindow, let app else { return }
        updateLimits(for: app.currentProfile, in: window)
        clampNow()
    }

    @objc private func screenParametersDidChange() {
        guard let window = phoneWindow, let app else { return }
        updateLimits(for: app.currentProfile, in: window)
        clampNow()
    }

    private func scheduleClamp() {
        clampWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.clampNow() }
        }
        clampWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clampNow() {
        guard let window = phoneWindow, !isApplyingFrame else { return }
        let screen = window.screen?.visibleFrame ?? fallbackScreen
        apply(clamped(window.frame, screen: screen), to: window)
        panels?.refresh()
    }
}
