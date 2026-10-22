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

    var presented: DockModule? { state.presented }
    var pinned: DockModule? { state.pinned }

    func hover(_ module: DockModule, inside: Bool) {
        if inside {
            closeWork?.cancel()
            closeWork = nil
            guard state.pinned == nil else { return }
            hoverWork?.cancel()
            pendingHover = module
            let work = DispatchWorkItem { [weak self] in
                self?.pendingHover = nil
                self?.state.hover(module)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
        } else {
            // 鼠标从 A 划到 B 时，A 的离开事件可能晚于 B 的进入事件。
            // 只清理属于 A 的计时，否则会把 B 刚排好的展开也取消掉。
            if pendingHover == module {
                hoverWork?.cancel()
                hoverWork = nil
                pendingHover = nil
            }
            guard state.pinned == nil else { return }
            if state.hovered == module {
                scheduleClose()
            }
        }
    }

    /// 鼠标进入抽屉时取消收起；离开时只有未钉住才收起。
    func drawerHover(_ inside: Bool) {
        if inside {
            closeWork?.cancel()
            closeWork = nil
        } else if state.pinned == nil {
            scheduleClose()
        }
    }

    func togglePin(_ module: DockModule) {
        hoverWork?.cancel()
        hoverWork = nil
        pendingHover = nil
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
        state.dismiss()
    }

    /// 钉住后点窗口其他位置取消。坞列固定从窗口左边缘算 372pt。
    func startOutsideClickMonitor(dockWidth: CGFloat) {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.state.pinned != nil else { return event }
            if event.locationInWindow.x > dockWidth {
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

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.state.clearHover()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }
}
