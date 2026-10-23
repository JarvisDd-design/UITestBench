import SwiftUI

/// 坞面板的根视图：只放胶囊本身，位置和尺寸由面板控制器负责。
struct DockPanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var panels: FloatingPanelsController

    var body: some View {
        PanelCard(onSizeChange: { size in
            DispatchQueue.main.async { panels.reportDockSize(size) }
        }) {
            DockRail(dock: app.dock, theme: app.theme, window: app.window)
        }
        .benchTheme(app.theme.mode)
        .windowDragArea(app.window)
        .onAppear { panels.drawerStateDidChange() }
        .onChange(of: app.dock.presented) { _ in panels.drawerStateDidChange() }
        .onChange(of: app.theme.mode) { mode in panels.applyTheme(mode) }
    }
}
