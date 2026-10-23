import AppKit
import SwiftUI
import UITestBenchCore

@MainActor
final class DockModel: ObservableObject {
    /// 先做「点击钉住」。想退回纯 hover，把这里改成 false 即可。
    static let supportsPinning = true

    static let hoverDelay: TimeInterval = 0.15
    static let closeDelay: TimeInterval = 0.25

    @Published private(set) var state = DockDrawerState()

    private var hoverWork: DispatchWorkItem?
    private var pendingHover: DockModule?
    private var closeWork: DispatchWorkItem?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// 指针是否在抽屉里。离开轨道项的事件可能晚于进入抽屉的事件。
    private var drawerHovered = false

    var presented: DockModule? { state.presented }
    var pinned: DockModule? { state.pinned }

    func hover(_ module: DockModule, inside: Bool) {
        // sheet 是抽屉的子窗口，此时换模块会把 sheet 的宿主一起拆掉。
        guard !hasSheetAttached else { return }
        if inside {
            guard state.pinned == nil else { return }
            // 回到已经展开的那一项时取消收起，避免闪一下。
            if state.hovered == module { cancelClose() }
            hoverWork?.cancel()
            pendingHover = module
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hasSheetAttached,
                      self.pendingHover == module, self.state.pinned == nil else {
                    return
                }
                self.pendingHover = nil
                self.hoverWork = nil
                // 抽屉这一刻才真的展开，之前排的收起计时都不作数。
                self.cancelClose()
                self.state.hover(module)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
        } else {
            // 鼠标从 A 划到 B 时，A 的离开事件可能晚于 B 的进入事件。
            // 只清理属于自己的展开计时；收起计时则按「哪个模块」记账，
            // 见 scheduleClose(_:)。
            if pendingHover == module {
                hoverWork?.cancel()
                hoverWork = nil
                pendingHover = nil
            }
            guard state.pinned == nil, !drawerHovered else { return }
            if state.hovered == module {
                scheduleClose(module)
            }
        }
    }

    /// 鼠标进入抽屉时取消收起；离开时只有未钉住才收起。
    func drawerHover(_ inside: Bool) {
        drawerHovered = inside
        if inside {
            cancelClose()
        } else if state.pinned == nil, let shown = state.hovered {
            scheduleClose(shown)
        }
    }

    func togglePin(_ module: DockModule) {
        hoverWork?.cancel()
        hoverWork = nil
        pendingHover = nil
        cancelClose()
        // 键盘/读屏也能钉住，这时没有指针离开抽屉的事件。
        drawerHovered = false
        if Self.supportsPinning {
            state.pin(module)
        } else {
            state.hover(module)
        }
    }

    func dismiss() {
        hoverWork?.cancel()
        closeWork?.cancel()
        hoverWork = nil
        closeWork = nil
        pendingHover = nil
        // Esc 收起时视图可能直接消失，收不到 onHover(false)。
        drawerHovered = false
        state.dismiss()
    }

    /// 钉住后点手机才收起；坞、抽屉、扫码浮层、sheet、模态都不收起。
    /// 每个窗口是谁由面板控制器按身份判断，这里不再假设任何坐标。
    ///
    /// 同时挂 Esc：hover 打开的抽屉没有焦点，`onExitCommand` 收不到按键，
    /// 只能靠本 App 的事件监视器按 key 窗口判定。
    func startEventMonitors(classify: @escaping (NSWindow?) -> DockClickTarget) {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if self.state.shouldDismissOnClick(target: classify(event.window)) {
                self.dismiss()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            let target = classify(event.window)
            let foreign: Bool
            switch target {
            case .auxiliary, .sheet, .modal: foreign = true
            case .dock, .drawer, .phone: foreign = false
            }
            let isEditing = event.window?.firstResponder is NSTextView
            switch DockEscapePolicy.action(
                isPresented: self.presented != nil,
                isEditingText: isEditing,
                hasForeignKeyWindow: foreign
            ) {
            case .ignore:
                return event
            case .endEditing:
                // SwiftUI 的 TextField 不会自己结束编辑，先交还焦点。
                event.window?.makeFirstResponder(nil)
                return nil
            case .dismiss:
                self.dismiss()
                // 吞掉事件：Esc 收起抽屉后不要再传给别的响应者。
                return nil
            }
        }
    }

    func stopEventMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// 「关于」等 sheet 挂在抽屉上；只要还有可见 sheet，就不许抽屉换模块或自动收起。
    private var hasSheetAttached: Bool {
        NSApp.windows.contains { $0.isVisible && $0.sheetParent != nil }
    }

    /// 收起必须记住是给哪个模块排的：期间可能已经换到另一个抽屉，
    /// 到点再无条件 clearHover 会把新展开的抽屉关掉。
    private func scheduleClose(_ module: DockModule) {
        guard !hasSheetAttached else { return }
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hasSheetAttached {
                self.closeWork = nil
                return
            }
            guard self.state.pinned == nil, self.state.hovered == module else {
                return
            }
            self.state.clearHover()
            self.closeWork = nil
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}
