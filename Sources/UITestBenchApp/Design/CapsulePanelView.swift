import SwiftUI

/// 底胶囊面板的根视图。宽度由控制器锁成手机外框宽，内容自己铺满。
struct CapsulePanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var panels: FloatingPanelsController

    var body: some View {
        ActionCapsule(
            state: app.actionCapsuleState,
            device: app.device,
            run: app.run,
            screenshot: app.screenshot,
            onRun: { app.runCurrentAPK() },
            onResume: { app.resumeCurrentAPK() },
            onRestartClearing: { app.restartClearingCurrentAPK() },
            onReinstall: { app.reinstallCurrentAPK() },
            canSendBack: app.mirror.canSendInput,
            onBack: { app.backButtonPressed() }
        )
        .padding(FloatingPanelsController.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .benchTheme(app.theme.mode)
        .windowDragArea(app.window)
    }
}
