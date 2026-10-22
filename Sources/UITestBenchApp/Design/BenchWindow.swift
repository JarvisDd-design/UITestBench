import AppKit
import SwiftUI

@MainActor
final class BenchWindowController: ObservableObject {
    @Published private(set) var isAlwaysOnTop = false

    private weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 700)

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // 系统交通灯全部隐藏，换成坞顶自绘的三枚圆点。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // 第一次启动给默认尺寸；之后交给系统的 frame autosave。
        let autosaveName = "UITestBench.MainWindow"
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        if UserDefaults.standard.string(forKey: autosaveKey) == nil {
            window.setContentSize(NSSize(width: 1120, height: 780))
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
    }

    func close() {
        // 走 AppDelegate 的清理流程：先卸包、停模拟器，再退出。
        NSApp.terminate(nil)
    }

    func minimize() {
        window?.miniaturize(nil)
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        window?.level = isAlwaysOnTop ? .floating : .normal
    }
}

/// 把 SwiftUI 视图下方的 NSWindow 交给控制器。
struct WindowConfigurator: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onAttach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onAttach(window) }
        }
    }
}
