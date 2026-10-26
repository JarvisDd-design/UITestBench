import AppKit
import Combine
import SwiftUI
import UITestBenchCore

/// 全应用唯一的模型与状态容器。
///
/// 手机窗口、坞面板、抽屉面板、底胶囊面板各自是独立的 `NSHostingView`，
/// 不能再用 `@StateObject` + `@Binding` 在视图树里传递状态，所以统一放这里。
@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths

    let setup: SetupModel
    let theme = ThemeStore()
    let window = BenchWindowController()
    let dock = DockModel()
    let device: EmulatorController
    let mirror: MirrorModel
    let apk: APKPanelModel
    let scanner = ScreenScannerModel()
    let run = RunModel()
    let screenshot = ScreenshotModel()
    let session: SessionModel

    @Published var profileIndex = 1
    @Published var customWidth = "1080"
    @Published var customHeight = "2400"
    @Published var customDensity = "420"
    @Published var showsCustomResolution = false
    @Published var actionError: String?

    /// 把各个子模型的变化转成 AppModel 自己的变化。
    ///
    /// 手机窗口和三个面板是四棵独立的视图树，每棵只观察 AppModel。
    /// 不转发的话，`@ObservedObject var app` 收不到 `app.device.state` 这类
    /// 子模型更新，`.onChange` 也不会触发。
    private var cancellables = Set<AnyCancellable>()

    init() {
        let paths = AppPaths.standard
        self.paths = paths
        setup = SetupModel(paths: paths)
        device = EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: AVDStore(root: paths.avdDirectory),
            launcher: ProcessLauncher(outputURL: paths.emulatorLogURL),
            provisioner: TeamDeviceKeyProvisioner(sdkDirectory: paths.sdkDirectory)
        )
        mirror = MirrorModel(sdkDirectory: paths.sdkDirectory)
        apk = APKPanelModel(paths: paths)
        session = SessionModel(paths: paths)

        // 机型选择不落盘，重开应用后默认是「主流」。磁盘上已有「大屏」或
        // 自定义分辨率的设备时，把界面同步回来，手机外框才不会按错比例留黑边。
        if let existing = device.adoptExistingProfile() {
            syncProfileSelection(with: existing)
        }

        forwardChanges(from: setup)
        forwardChanges(from: theme)
        forwardChanges(from: window)
        forwardChanges(from: dock)
        forwardChanges(from: device)
        forwardChanges(from: mirror)
        forwardChanges(from: apk)
        forwardChanges(from: scanner)
        forwardChanges(from: run)
        forwardChanges(from: screenshot)
        forwardChanges(from: session)
    }

    private func forwardChanges<Object: ObservableObject>(from object: Object) {
        object.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var backKeyMonitor: Any?

    /// 应用级 ⌘[：手机、坞、抽屉、底胶囊是 key 时都能发返回；
    /// 输入框编辑和 sheet / 模态上不抢键。判定规则在 Core 的
    /// `DeviceBackShortcutPolicy` 里单测，这里只负责把 NSEvent 递进去。
    func startBackKeyMonitor() {
        guard backKeyMonitor == nil else { return }
        backKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.mirror.canSendInput else { return event }

            let modifiers = KeyboardInput.Modifiers(event: event)
            let action = KeyboardInput.action(
                // ⌘[ 用 charactersIgnoringModifiers 判定，避免中文输入法
                // 或大写锁定改变字符；Shift 已单独记在 modifiers 里。
                for: event.charactersIgnoringModifiers ?? event.characters ?? "",
                modifiers: modifiers
            )
            let decision = DeviceBackShortcutPolicy.decision(
                action: action,
                modifiers: modifiers,
                isEditingText: event.window?.firstResponder is NSTextView,
                target: self.window.clickTarget(for: event.window)
            )
            guard decision == .send else { return event }

            self.sendBackKey()
            return nil
        }
    }

    func sendBackKey() {
        mirror.pressKey(.back)
    }

    /// 点底胶囊的返回图标后，把键盘焦点还给手机画面；
    /// 下一次 ⌘[ 或直接敲键盘都不用再点一次手机。
    func backButtonPressed() {
        sendBackKey()
        guard let phone = window.phoneWindow, phone.isVisible else { return }
        phone.makeKey()
        _ = phone.makeFirstResponder(mirror.display)
    }

    /// 底胶囊该显示什么，由手机窗口和胶囊面板共用，避免两处各算一遍。
    var actionCapsuleState: ActionCapsuleState {
        ActionCapsuleResolver.resolve(
            ActionCapsuleInput(
                hasAPK: apk.acquired?.compatibility.isCompatible == true,
                deviceRunning: device.isRunning,
                isRunning: run.isRunning,
                isBusy: run.isBusy || screenshot.isCapturing,
                busyText: run.isBusy
                    ? run.statusText
                    : (screenshot.isCapturing ? "正在截图…" : nil)
            )
        )
    }

    var currentProfile: DeviceProfile {
        if profileIndex >= 0, DeviceProfile.presets.indices.contains(profileIndex) {
            return DeviceProfile.presets[profileIndex]
        }
        if let width = Int(customWidth),
           let height = Int(customHeight),
           let density = Int(customDensity),
           width > 0, height > 0, density > 0 {
            return DeviceProfile(name: "自定义", width: width, height: height, density: density)
        }
        return .standard
    }

    private func syncProfileSelection(with profile: DeviceProfile) {
        if let index = DeviceProfile.presetIndex(matching: profile) {
            profileIndex = index
            showsCustomResolution = false
        } else {
            profileIndex = -1
            customWidth = String(profile.width)
            customHeight = String(profile.height)
            customDensity = String(profile.density)
            showsCustomResolution = true
        }
    }

    func toggleDevice() {
        actionError = nil
        let shouldStop = device.isRunning
        Task {
            do {
                if shouldStop {
                    // 卸载要用设备活着时的 adb，必须在 stop 之前。
                    await session.prepareForDeviceStop()
                    try await device.stop()
                } else {
                    try await device.start()
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func switchToPreset(_ index: Int) {
        actionError = nil
        let profile = DeviceProfile.presets[index]
        Task {
            do {
                try await device.switchProfile(to: profile)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func runCurrentAPK() {
        guard let acquired = apk.acquired else { return }
        run.run(acquired)
    }

    func resumeCurrentAPK() {
        guard let acquired = apk.acquired else { return }
        run.resume(acquired)
    }

    func restartClearingCurrentAPK() {
        guard let acquired = apk.acquired else { return }
        run.restartClearingData(acquired)
    }

    func reinstallCurrentAPK() {
        guard let acquired = apk.acquired else { return }
        run.reinstall(acquired)
    }

    func applyCustomResolution() {
        guard let width = Int(customWidth),
              let height = Int(customHeight),
              let density = Int(customDensity),
              width > 0, height > 0, density > 0
        else { return }

        actionError = nil
        profileIndex = -1
        let profile = DeviceProfile(name: "自定义", width: width, height: height, density: density)
        Task {
            do {
                try await device.switchProfile(to: profile)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
