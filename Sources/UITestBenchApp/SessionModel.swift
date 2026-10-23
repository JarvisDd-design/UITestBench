import AppKit
import Foundation
import SwiftUI
import UITestBenchCore

/// 「退出即清」在界面层的门面。
///
/// 应用一出现就跑启动自检：上次若被强杀，`tmp/` 里会留着临时 APK，
/// 设备里也还装着被测应用。临时文件当场清掉；包得等模拟器起来才能卸。
@MainActor
final class SessionModel: ObservableObject {
    /// 上次异常退出留下的提示，处理完就清空。
    @Published private(set) var recoveryNotice: String?

    private let cleaner: SessionCleaner
    private var lifecycle: AppLifecycle?
    private var currentPackageName: String?
    private var pendingPackageName: String?

    private var didStart = false

    init(paths: AppPaths) {
        cleaner = SessionCleaner(supportDirectory: paths.supportDirectory)
    }

    /// 自检会删文件，不能放在 `init` 里：`StateObject` 的构造闭包
    /// 可能被求值多次，那样会把正在用的临时 APK 删掉。只跑一次。
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        guard let record = try? cleaner.recover() else { return }
        pendingPackageName = record.packageName
        recoveryNotice = "上次没有正常退出，临时文件已清理。设备启动后会卸载 \(record.packageName)。"
    }

    func attach(serial: String, sdkDirectory: URL) {
        lifecycle = AppLifecycle(sdkDirectory: sdkDirectory, serial: serial)
    }

    func detach() {
        lifecycle = nil
    }

    /// 设备刚启动时调用：把上次没卸掉的包补卸。
    func clearPendingInstallIfNeeded() async {
        guard let lifecycle, let pending = pendingPackageName else { return }
        do {
            try await lifecycle.uninstall(packageName: pending)
            pendingPackageName = nil
            recoveryNotice = nil
        } catch {
            // 卸不掉就留着记录，下次再来；不打断用户当前要做的事。
            recoveryNotice = "上次残留的应用没能卸载，退出时会再试一次。"
        }
    }

    /// 应用真的起来了才记录。装失败、启动失败都不必留痕。
    func recordLaunch(packageName: String) {
        currentPackageName = packageName
        try? cleaner.remember(packageName: packageName)
    }

    /// 停止设备前调用：快照里不能留着被测包；但会话还在继续，
    /// 已经下载好的 APK 要留给用户下次运行。
    func prepareForDeviceStop() async {
        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageName: currentPackageName
        ).run(clearsTemporaryData: false)
        if (try? cleaner.pendingPackageName()) == nil {
            currentPackageName = nil
        }
    }

    /// 退出前调用：先卸包再清文件，设备此时必须还活着。
    func shutdown() async {
        await SessionShutdown(
            cleaner: cleaner,
            lifecycle: lifecycle,
            packageName: currentPackageName
        ).run()
        currentPackageName = nil
        pendingPackageName = nil
    }
}

/// 退出钩子只能有一个入口：AppDelegate 收到「要退出了」时暂停退出，
/// 等清理跑完再放行。清理要几十秒时用户会看到窗口还开着，这是对的。
@MainActor
final class ShutdownCoordinator {
    static let shared = ShutdownCoordinator()

    var perform: (() async -> Void)?
    private(set) var isBusy = false

    func run() async {
        guard !isBusy, let perform else { return }
        isBusy = true
        await perform()
        self.perform = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var phoneWindow: PhoneWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profile = model.currentProfile
        let screen = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(
            PhoneLayoutCalculator.defaultScreenWidth,
            PhoneLayoutCalculator.maximumScreenWidth(
                visibleSize: screen.size,
                profile: profile
            )
        )
        let size = PhoneLayoutCalculator.frameSize(forScreenWidth: width, profile: profile)

        let window = PhoneWindow(
            contentRect: CGRect(
                x: screen.midX - size.width / 2,
                y: screen.maxY - size.height - 60,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: PhoneWindowView(app: model))
        model.window.attach(window, app: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        phoneWindow = window

        // 一秒后再允许设置窗口正常打开，避免误收用户主动打开的窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            LaunchBehavior.suppressSettingsWindow = false
        }
    }

    /// 手机窗口只是被隐藏时，点 Dock 图标回来；不要另开一个窗口。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        model.window.showPhone()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = ShutdownCoordinator.shared
        // 清理已经在跑：这次退出请求排队等它，别另起一轮。
        if coordinator.isBusy { return .terminateLater }
        guard coordinator.perform != nil else { return .terminateNow }
        Task { @MainActor in
            await coordinator.run()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 面板都是独立窗口，手机窗口也可能只是被隐藏，不能把「最后一个窗口关闭」
    /// 当成退出信号。退出统一走 ⌘W / 红点 / NSApp.terminate。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // 单窗口：不保存也不恢复窗口状态。否则从 1.2.0 升级的用户可能恢复出
    // 多个旧窗口，各自拉起一套 EmulatorController 抢同一台 AVD。
    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }
}
