import AppKit
import SwiftUI
import UITestBenchCore

/// 手机窗口的全部内容：机身里放镜像画面、待机屏或安装向导。
///
/// 坞、底胶囊、抽屉在独立面板里，不在这棵视图树中；这里只负责手机，
/// 以及需要「手机在就一直在」的生命周期编排。
struct PhoneWindowView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        GeometryReader { proxy in
            let layout = PhoneLayoutCalculator.layout(
                frameSize: proxy.size,
                profile: app.currentProfile
            )
            PhoneFrame(layout: layout) {
                if app.setup.phase == .ready {
                    screen
                } else {
                    SetupScreen(model: app.setup)
                }
            }
        }
        .background(Color.clear)
        .benchTheme(app.theme.mode)
        .animation(.easeInOut(duration: 0.2), value: app.theme.mode)
        // Esc 收起抽屉统一走 DockModel 的键盘监视器：抽屉多半不是 key 窗口，
        // 只挂在某个视图上的 onExitCommand 收不到按键。
        .onChange(of: app.device.state) { state in
            if case let .running(serial) = state {
                app.mirror.start(serial: serial)
                app.run.attach(serial: serial, sdkDirectory: app.paths.sdkDirectory)
                app.screenshot.attach(serial: serial, sdkDirectory: app.paths.sdkDirectory)
                app.session.attach(serial: serial, sdkDirectory: app.paths.sdkDirectory)
                Task { await app.session.clearPendingInstallIfNeeded() }
            } else {
                app.mirror.stop()
                app.run.detach()
                app.screenshot.detach()
                app.session.detach()
            }
        }
        .onChange(of: app.apk.state) { _ in
            app.run.reset()
        }
        .onChange(of: app.run.isRunning) { running in
            guard running, let name = app.apk.acquired?.info.packageName else { return }
            app.session.recordLaunch(packageName: name)
        }
        .onChange(of: app.theme.mode) { mode in
            app.scanner.setDarkAppearance(mode == .dark)
            app.window.applyTheme(mode)
        }
        .onChange(of: app.currentProfile) { profile in
            app.window.profileDidChange(profile)
        }
        .onChange(of: app.actionCapsuleState) { _ in
            app.window.refreshPanels()
        }
        .onChange(of: app.setup.phase) { _ in
            app.window.refreshPanels()
        }
        .onAppear {
            app.session.startIfNeeded()
            _ = app.setup.markReadyIfInstalled()
            app.scanner.onHit = { link in
                app.apk.presentScannedLink(link)
            }
            app.scanner.onFallback = {
                app.apk.chooseFile()
            }
            app.scanner.hideMainWindow = { [weak app] in
                app?.window.minimize()
            }
            app.scanner.showMainWindow = { [weak app] in
                app?.window.showPhone()
            }
            app.scanner.setDarkAppearance(app.theme.mode == .dark)
            app.window.applyTheme(app.theme.mode)
            app.dock.startEventMonitors { [weak app] window in
                app?.window.clickTarget(for: window) ?? .auxiliary
            }

            // 退出时先卸包、再关设备：设备关了 adb 就卸不掉了。
            ShutdownCoordinator.shared.perform = {
                app.scanner.shutdown()
                await app.session.shutdown()
                try? await app.device.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            app.scanner.shutdown()
        }
        .alert(
            "截图失败",
            isPresented: Binding(
                get: { app.screenshot.errorMessage != nil },
                set: { if !$0 { app.screenshot.clearError() } }
            )
        ) {
            Button("好") { app.screenshot.clearError() }
        } message: {
            Text(app.screenshot.errorMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { app.screenshot.editor != nil },
                set: { if !$0 { app.screenshot.closeEditor() } }
            )
        ) {
            if let editor = app.screenshot.editor {
                AnnotationEditorView(model: editor) {
                    app.screenshot.closeEditor()
                }
                .benchTheme(app.theme.mode)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        if case .streaming = app.mirror.state {
            VideoSurface(display: app.mirror.display)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("手机屏幕画面")
                .accessibilityAddTraits(.isImage)
        } else {
            StandbyScreen(
                device: app.device,
                apk: app.apk,
                mirror: app.mirror,
                onStartDevice: { app.toggleDevice() },
                onScan: { app.scanner.start(from: app.window.phoneWindow) },
                onChooseFile: { app.apk.chooseFile() },
                onReconnect: { app.mirror.start(serial: app.device.serial) }
            )
        }
    }
}
