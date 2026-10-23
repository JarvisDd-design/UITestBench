import SwiftUI
import UITestBenchCore

/// 抽屉面板的根视图。
///
/// 内容由控制器记住的「最后一个模块」驱动：收起时先淡出，
/// 淡出期间卡片不会提前变空。位置由 Core 算在坞的左侧。
struct DrawerPanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var panels: FloatingPanelsController

    var body: some View {
        Group {
            if let module = panels.displayedModule {
                DockDrawer(module: module, app: app)
                    .background(
                        PanelSizeReporter { size in
                            DispatchQueue.main.async {
                                panels.reportDrawerSize(size)
                            }
                        }
                    )
            } else {
                Color.clear
            }
        }
        .padding(FloatingPanelsController.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .benchTheme(app.theme.mode)
        // Esc 不在这里处理：输入框里的 Esc 属于「取消编辑」，
        // 收起抽屉由 DockModel 的键盘监视器按 first responder 判定。
    }
}
