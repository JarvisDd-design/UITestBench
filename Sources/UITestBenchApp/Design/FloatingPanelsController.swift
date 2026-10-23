import AppKit
import SwiftUI
import UITestBenchCore

/// 创建并驱动吸附在手机窗口上的三个面板：坞、底胶囊、抽屉。
///
/// 面板全部 `addChildWindow` 到手机窗口：拖动手机时 AppKit 自动带走它们；
/// 手机缩放、换屏、显隐时由这里重排。面板自己不能拖动，也不需要。
@MainActor
final class FloatingPanelsController: ObservableObject {
    /// SwiftUI 卡片阴影画在面板内部，四周要留出不会被裁掉的空间。
    /// 阴影最远到「半径 + 纵向偏移」（抽屉约 30pt），留 40 才不会被窗口边缘
    /// 切出一条直边——那条直边就是之前看起来「断层」的来源。
    static let shadowPadding: CGFloat = 40

    static let dockWidth = DockMetrics.railWidth
    static let drawerWidth = DockMetrics.drawerWidth
    static let drawerMaxHeight = DockMetrics.cardMaxHeight
    /// 第一次打开某个模块时先用这个高度定位，等实测回来再修正。
    static let drawerFallbackHeight: CGFloat = 300

    let dockPanel = BenchPanel(role: "坞")
    let capsulePanel = BenchPanel(role: "操作胶囊")
    let drawerPanel = BenchPanel(role: "抽屉")

    /// 抽屉淡出期间仍要显示最后的内容，不能直接读 `dock.presented`。
    @Published private(set) var displayedModule: DockModule?

    private let app: AppModel
    private weak var phoneWindow: NSWindow?

    private var dockSize = CGSize(width: dockWidth, height: 444)
    private var drawerHeights: [DockModule: CGFloat] = [:]
    private var drawerVisible = false
    private var fadeToken = 0
    private var isShown = true
    private var wakeObserver: PanelWakeObserver?

    init(app: AppModel) {
        self.app = app
        dockPanel.setRootView(DockPanelView(app: app, panels: self))
        capsulePanel.setRootView(CapsulePanelView(app: app, panels: self))
        drawerPanel.setRootView(DrawerPanelView(app: app, panels: self))
    }

    deinit {
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
    }

    // MARK: - 挂载与布局

    func attach(to phone: NSWindow) {
        guard phoneWindow !== phone else { return }
        phoneWindow = phone
        for panel in [dockPanel, capsulePanel, drawerPanel] {
            phone.addChildWindow(panel, ordered: .above)
        }
        drawerPanel.orderOut(nil)
        layout()
        observeActivation()
    }

    /// 应用从后台回来、或者点了任何一块时，把整组重新抬到最前。
    ///
    /// 面板是手机窗口的子窗口，但 AppKit 只保证「父窗口被 order 时子窗口跟着」。
    /// 从别的应用后面点回来时，手机窗口会浮上来，几块面板却可能留在原层级。
    /// 于是表现为「得单独点每块面板才看得见」。
    private func observeActivation() {
        guard wakeObserver == nil, let phone = phoneWindow else { return }
        let observer = PanelWakeObserver(panels: self)
        let center = NotificationCenter.default
        center.addObserver(
            observer,
            selector: #selector(PanelWakeObserver.wake(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        for window in [phone, dockPanel, capsulePanel, drawerPanel] {
            center.addObserver(
                observer,
                selector: #selector(PanelWakeObserver.wake(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
        wakeObserver = observer
    }

    /// 先抬手机，再按「抽屉 > 胶囊 > 坞」的顺序把面板放回手机之上。
    /// 隐藏整组时手机不可见，这里直接不动，避免把面板从隐藏里拉出来。
    func raisePanels() {
        guard isShown, let phone = phoneWindow, phone.isVisible else { return }
        phone.orderFront(nil)
        if dockPanel.isVisible {
            dockPanel.orderFront(nil)
        }
        if shouldShowCapsule, capsulePanel.isVisible {
            capsulePanel.orderFront(nil)
        }
        if drawerVisible, drawerPanel.isVisible {
            drawerPanel.orderFront(nil)
        }
    }

    func refresh() {
        guard isShown else { return }
        layout()
    }

    func layout() {
        guard let phone = phoneWindow, let screen = phone.screen ?? NSScreen.main else { return }
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone.frame,
            dockSize: dockSize,
            capsuleHeight: PhoneLayoutCalculator.capsuleHeight,
            drawerSize: currentDrawerSize,
            visibleScreen: screen.visibleFrame
        )

        apply(frames.dock, to: dockPanel)
        apply(frames.capsule, to: capsulePanel)
        if let drawer = frames.drawer {
            apply(drawer, to: drawerPanel)
        }
        updateCapsuleVisibility()
    }

    /// Core 算的是可见卡片的矩形；面板要再向四周扩出阴影留白。
    private func apply(_ visible: CGRect, to panel: NSWindow) {
        let padded = visible.insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding)
        guard panel.frame != padded else { return }
        panel.setFrame(padded, display: false)
    }

    private var currentDrawerSize: CGSize? {
        guard let module = displayedModule else { return nil }
        return CGSize(
            width: Self.drawerWidth,
            height: drawerHeights[module] ?? Self.drawerFallbackHeight
        )
    }


    // MARK: - 坞与胶囊

    func reportDockSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - dockSize.width) > 0.5
                || abs(size.height - dockSize.height) > 0.5 else { return }
        dockSize = size
        layout()
    }

    /// 坞面板的可见宽度，手机窗口夹位置时要用它给左侧留空间。
    var visibleDockWidth: CGFloat { dockSize.width }

    private var shouldShowCapsule: Bool {
        app.setup.phase == .ready && app.actionCapsuleState != .hidden
    }

    private func updateCapsuleVisibility() {
        let shouldShow = shouldShowCapsule
        if shouldShow {
            if isShown, !capsulePanel.isVisible {
                capsulePanel.orderFront(nil)
            }
        } else if capsulePanel.isVisible {
            capsulePanel.orderOut(nil)
        }
    }

    // MARK: - 抽屉

    func drawerStateDidChange() {
        let target = app.dock.presented
        if let target {
            fadeToken += 1
            if drawerHeights[target] == nil {
                drawerHeights[target] = Self.drawerFallbackHeight
            }
            let moduleChanged = displayedModule != target
            displayedModule = target
            // 位置变化不做动画：卡片只淡入，避免高度测量期间上下跳。
            layout()
            if !drawerVisible {
                drawerVisible = true
                drawerPanel.alphaValue = 0
                drawerPanel.orderFront(nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    drawerPanel.animator().alphaValue = 1
                }
            } else if drawerPanel.alphaValue < 1 {
                drawerPanel.alphaValue = 1
            } else if moduleChanged {
                drawerPanel.alphaValue = 1
            }
        } else if drawerVisible {
            fadeOutDrawer()
        }
    }

    private func fadeOutDrawer() {
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            drawerPanel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.fadeToken == token,
                  self.app.dock.presented == nil else { return }
            self.drawerPanel.orderOut(nil)
            self.drawerVisible = false
            self.displayedModule = nil
        }
    }

    func reportDrawerSize(_ size: CGSize) {
        guard let module = displayedModule, size.height > 1 else { return }
        let height = min(size.height, Self.drawerMaxHeight)
        if let known = drawerHeights[module], abs(known - height) <= 0.5 {
            return
        }
        drawerHeights[module] = height
        layout()
    }

    // MARK: - 主题、层级、显隐

    func applyTheme(_ mode: ThemeMode) {
        let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        for panel in [dockPanel, capsulePanel, drawerPanel] {
            panel.appearance = appearance
        }
    }

    func setLevel(_ level: NSWindow.Level) {
        for panel in [dockPanel, capsulePanel, drawerPanel] {
            panel.level = level
        }
    }

    func hide() {
        isShown = false
        fadeToken += 1
        drawerPanel.alphaValue = 0
        for panel in [dockPanel, capsulePanel, drawerPanel] {
            panel.orderOut(nil)
        }
    }

    func show() {
        isShown = true
        layout()
        dockPanel.orderFront(nil)
        updateCapsuleVisibility()
        if drawerVisible {
            drawerPanel.alphaValue = 1
            drawerPanel.orderFront(nil)
        }
    }

    /// 给外点监视器用的窗口身份判断。
    func clickTarget(for window: NSWindow?) -> DockClickTarget {
        if NSApp.modalWindow != nil { return .modal }
        guard let window else { return .auxiliary }
        if window.sheetParent != nil { return .sheet }
        if window === phoneWindow { return .phone }
        if window === dockPanel { return .dock }
        if window === drawerPanel { return .drawer }
        return .auxiliary
    }
}

/// 只做一件事：应用激活或某个窗口成为 key 时，把整组面板抬回最前。
///
/// 用选择器注册而不是闭包：闭包要跨隔离边界捕获控制器，在 12.3 的
/// 语言模式下只能写成 `@unchecked Sendable`；这里通知本来就在主线程发。
@MainActor
private final class PanelWakeObserver: NSObject {
    private weak var panels: FloatingPanelsController?

    init(panels: FloatingPanelsController) {
        self.panels = panels
        super.init()
    }

    @objc func wake(_ notification: Notification) {
        panels?.raisePanels()
    }
}
