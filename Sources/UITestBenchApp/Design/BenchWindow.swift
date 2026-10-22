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
        // 空白处拖动可以移窗；画面是触摸面，那条由 MirrorDisplayView 自己关掉。
        window.isMovableByWindowBackground = true
        // 最小尺寸交给 SwiftUI 的 .frame(minWidth:minHeight:)。窗口坐标里标题栏还占 28pt，
        // 在这里再设一次会把内容挤出可见区域。

        // 系统交通灯全部隐藏，换成坞顶自绘的三枚圆点。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // 有存过的窗口位置就用存的；没有才给默认尺寸。用公开 API 恢复，
        // 不去读 "NSWindow Frame …" 这个实现细节。
        let autosaveName = "UITestBench.MainWindow"
        if !window.setFrameUsingName(autosaveName) {
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
        WindowProbe(onAttach: onAttach)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 真正挂进窗口时才报告，不用等下一个 runloop；只会触发一次。
private final class WindowProbe: NSView {
    private let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void) {
        self.onAttach = onAttach
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不提供 nib 加载")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach(window) }
    }
}
