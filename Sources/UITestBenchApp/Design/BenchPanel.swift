import AppKit
import SwiftUI

/// 吸附在手机窗口旁边的悬浮面板。
///
/// 无边框、透明、自身不画阴影（阴影由 SwiftUI 卡片画）。可以成为 key，
/// 这样抽屉里的输入框能正常输入；但永远不是 main，主窗口身份留给手机。
@MainActor
final class BenchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(role: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        title = role
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        collectionBehavior = [.ignoresCycle]
        // 点按钮不抢手机窗口的键盘焦点；点输入框时才成为 key。
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    func setRootView<Content: View>(_ view: Content) {
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

/// 量出卡片内容的实际尺寸，回报给面板控制器。
/// 只量卡片本身；面板四周的阴影留白由控制器统一加。
struct PanelSizeReporter: View {
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onSizeChange(proxy.size) }
                .onChange(of: proxy.size) { onSizeChange($0) }
        }
    }
}

/// 拿到 SwiftUI 视图所在的 NSWindow；窗口切换时也会再报一次。
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowAccessorView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowAccessorView: NSView {
        private let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("不提供 nib 加载")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

/// 面板根视图的统一外形：卡片 + 阴影留白，铺满整个面板。
struct PanelCard<Content: View>: View {
    let onSizeChange: (CGSize) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(PanelSizeReporter(onSizeChange: onSizeChange))
            .padding(FloatingPanelsController.shadowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
