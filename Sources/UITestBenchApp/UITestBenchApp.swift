import AppKit
import SwiftUI
import UITestBenchCore

@main
struct UITestBenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("UI验收台") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 空组会把「关闭」一起删掉，⌘W 就没了；这里显式补回关闭。
            CommandGroup(replacing: .newItem) {
                Button("关闭窗口") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    private let paths = AppPaths.standard

    @StateObject private var setup: SetupModel
    @StateObject private var theme = ThemeStore()
    @StateObject private var window = BenchWindowController()
    @StateObject private var dock = DockModel()
    @StateObject private var device: EmulatorController
    @StateObject private var mirror: MirrorModel
    @StateObject private var apk: APKPanelModel
    @StateObject private var scanner = ScreenScannerModel()
    @StateObject private var run = RunModel()
    @StateObject private var screenshot = ScreenshotModel()
    @StateObject private var session: SessionModel

    @State private var profileIndex = 1
    @State private var customWidth = "1080"
    @State private var customHeight = "2400"
    @State private var customDensity = "420"
    @State private var showsCustomResolution = false
    @State private var actionError: String?

    init() {
        let paths = AppPaths.standard
        _setup = StateObject(wrappedValue: SetupModel(paths: paths))
        _device = StateObject(wrappedValue: EmulatorController(
            sdkDirectory: paths.sdkDirectory,
            store: AVDStore(root: paths.avdDirectory),
            launcher: ProcessLauncher(outputURL: paths.emulatorLogURL),
            provisioner: TeamDeviceKeyProvisioner(sdkDirectory: paths.sdkDirectory)
        ))
        _mirror = StateObject(wrappedValue: MirrorModel(sdkDirectory: paths.sdkDirectory))
        _apk = StateObject(wrappedValue: APKPanelModel(paths: paths))
        _session = StateObject(wrappedValue: SessionModel(paths: paths))
    }

    var body: some View {
        HStack(spacing: 0) {
            DockColumn(
                paths: paths,
                device: device,
                apk: apk,
                scanner: scanner,
                run: run,
                session: session,
                theme: theme,
                window: window,
                dock: dock,
                profileIndex: $profileIndex,
                customWidth: $customWidth,
                customHeight: $customHeight,
                customDensity: $customDensity,
                showsCustomResolution: $showsCustomResolution,
                actionError: $actionError,
                onToggleDevice: toggleDevice,
                onSwitchPreset: switchToPreset,
                onApplyCustomResolution: applyCustomResolution
            )

            if setup.phase == .ready {
                PhoneStage(
                    device: device,
                    mirror: mirror,
                    screenshot: screenshot,
                    run: run,
                    apk: apk,
                    profile: currentProfile,
                    onStartDevice: toggleDevice,
                    onScan: { scanner.start(from: NSApp.keyWindow) },
                    onChooseFile: { apk.chooseFile() },
                    onReconnect: {
                        mirror.start(serial: device.serial)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SetupStage(setup: setup)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            WindowConfigurator { window.attach($0) }
                .frame(width: 0, height: 0)
        )
        .background(Color.clear)
        .benchTheme(theme.mode)
        .animation(.easeInOut(duration: 0.2), value: theme.mode)
        .onExitCommand { dock.dismiss() }
        .onChange(of: device.state) { state in
            if case let .running(serial) = state {
                mirror.start(serial: serial)
                run.attach(serial: serial, sdkDirectory: paths.sdkDirectory)
                screenshot.attach(serial: serial, sdkDirectory: paths.sdkDirectory)
                session.attach(serial: serial, sdkDirectory: paths.sdkDirectory)
                Task { await session.clearPendingInstallIfNeeded() }
            } else {
                mirror.stop()
                run.detach()
                screenshot.detach()
                session.detach()
            }
        }
        .onChange(of: apk.state) { _ in
            run.reset()
        }
        .onChange(of: run.isRunning) { running in
            guard running, let name = apk.acquired?.info.packageName else { return }
            session.recordLaunch(packageName: name)
        }
        .onAppear {
            session.startIfNeeded()
            _ = setup.markReadyIfInstalled()
            scanner.onHit = { link in
                apk.presentScannedLink(link)
            }
            scanner.onFallback = {
                apk.chooseFile()
            }
            dock.startOutsideClickMonitor(dockWidth: DockMetrics.columnWidth)

            // 退出时先卸包、再关设备：设备关了 adb 就卸不掉了。
            ShutdownCoordinator.shared.perform = {
                scanner.shutdown()
                await session.shutdown()
                try? await device.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            scanner.shutdown()
        }
        .onDisappear {
            dock.stopOutsideClickMonitor()
            // 主窗口没了，扫描结果不该再回写到可能已销毁的模型上。
            scanner.onHit = nil
            scanner.onFallback = nil
            scanner.shutdown()
        }
        .alert(
            "截图失败",
            isPresented: Binding(
                get: { screenshot.errorMessage != nil },
                set: { if !$0 { screenshot.clearError() } }
            )
        ) {
            Button("好") { screenshot.clearError() }
        } message: {
            Text(screenshot.errorMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { screenshot.editor != nil },
                set: { if !$0 { screenshot.closeEditor() } }
            )
        ) {
            if let editor = screenshot.editor {
                AnnotationEditorView(model: editor) {
                    screenshot.closeEditor()
                }
                .benchTheme(theme.mode)
            }
        }
    }

    private var currentProfile: DeviceProfile {
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

    private func toggleDevice() {
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

    private func switchToPreset(_ index: Int) {
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

    private func applyCustomResolution() {
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
