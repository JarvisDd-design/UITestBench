import SwiftUI

/// 在坞/胶囊上按下拖动时，移动手机窗口，整组面板跟着走。
///
/// 不能用 `isMovableByWindowBackground`：面板里的 SwiftUI 内容会把按下事件吃掉，
/// 系统拖动根本不会开始。手势只负责判断「这是一次拖动」；真正的位移由
/// `BenchWindowController` 里的定时器完成，原因见 `beginGroupDrag()`。
struct WindowDragArea: ViewModifier {
    let window: BenchWindowController

    func body(content: Content) -> some View {
        // simultaneousGesture：轻点仍然交给按钮，拖出 5pt 才开始移动窗口。
        content.simultaneousGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { _ in window.beginGroupDrag() }
                .onEnded { _ in window.endGroupDrag() }
        )
        .onDisappear { window.endGroupDrag() }
    }
}

extension View {
    /// 从这块视图按下拖动时，带着手机和全部吸附面板一起移动。
    func windowDragArea(_ window: BenchWindowController) -> some View {
        modifier(WindowDragArea(window: window))
    }
}
