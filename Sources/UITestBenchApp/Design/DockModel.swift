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
    private var outsideMonitor: Any?
    /// 指针是否在抽屉里。离开轨道项的事件可能晚于进入抽屉的事件。
    private var drawerHovered = false

    var presented: DockModule? { state.presented }
    var pinned: DockModule? { state.pinned }

    func hover(_ module: DockModule, inside: Bool) {
        if inside {
            guard state.pinned == nil else { return }
            // 回到已经展开的那一项时取消收起，避免闪一下。
            if state.hovered == module { cancelClose() }
            hoverWork?.cancel()
            pendingHover = module
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingHover == module, self.state.pinned == nil else {
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

    /// 钉住后点窗口其他位置取消。坞列固定从窗口左边缘算 372pt。
    func startOutsideClickMonitor(dockWidth: CGFloat) {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let isSheet = event.window?.sheetParent != nil
            if self.state.shouldDismissOnClick(
                atX: event.locationInWindow.x,
                dockWidth: dockWidth,
                isSheet: isSheet
            ) {
                self.dismiss()
            }
            return event
        }
    }

    func stopOutsideClickMonitor() {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        outsideMonitor = nil
    }

    /// 收起必须记住是给哪个模块排的：期间可能已经换到另一个抽屉，
    /// 到点再无条件 clearHover 会把新展开的抽屉关掉。
    /// 「关于」等 sheet 挂在抽屉上；指针移到 sheet 上不算离开抽屉。
    private var hasSheetAttached: Bool {
        NSApp.keyWindow?.sheetParent != nil
    }

    private func scheduleClose(_ module: DockModule) {
        guard !hasSheetAttached else { return }
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasSheetAttached,
                  self.state.pinned == nil, self.state.hovered == module else {
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
