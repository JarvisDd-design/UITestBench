import AppKit
import SwiftUI
import UITestBenchCore

/// SwiftUI 在只有 Settings 场景时会把它当作首个窗口自动打开。
/// 启动后一秒内出现的设置窗口直接收回；之后用户从菜单打开不受影响。
enum LaunchBehavior {
    static var suppressSettingsWindow = true
}

@main
struct UITestBenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 主窗口由 AppDelegate 手工创建（无边框 + 可缩放），这里只保留
        // SwiftUI 的菜单命令与一个设置窗口，避免 SwiftUI 再建一个普通窗口。
        Settings {
            SettingsWindowView(app: appDelegate.model)
        }
        .commands {
            // 空组会把「关闭」一起删掉，⌘W 就没了；显式补回退出。
            CommandGroup(replacing: .newItem) {
                Button("关闭窗口") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("显示手机窗口") {
                    appDelegate.model.window.showPhone()
                }
            }
        }
    }
}

/// 设置窗口现在只是补充入口；主要设置仍在坞的「设置」抽屉里。
struct SettingsWindowView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UI验收台")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)

            Toggle("深色外观", isOn: Binding(
                get: { app.theme.mode == .dark },
                set: { app.theme.set($0 ? .dark : .light) }
            ))
            Toggle("窗口置顶", isOn: Binding(
                get: { app.window.isAlwaysOnTop },
                set: { if app.window.isAlwaysOnTop != $0 { app.window.toggleAlwaysOnTop() } }
            ))
            Button("适应屏幕") {
                if !app.window.isFittedToScreen {
                    app.window.toggleFitToScreen()
                }
            }
            .disabled(app.window.isFittedToScreen)

            Text("更多设置请在左侧坞的「设置」里调整。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .benchTheme(app.theme.mode)
        .background(
            WindowAccessor { window in
                guard LaunchBehavior.suppressSettingsWindow else { return }
                LaunchBehavior.suppressSettingsWindow = false
                DispatchQueue.main.async {
                    window?.orderOut(nil)
                }
            }
        )
    }
}
