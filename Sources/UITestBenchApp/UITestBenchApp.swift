import AppKit
import SwiftUI
import UITestBenchCore

@main
struct UITestBenchApp: App {
    // 退出前要把设备上的包卸掉、临时文件清掉，所以不能立刻放行退出。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("UI验收台") {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
    }
}

struct ContentView: View {
    private let paths = AppPaths.standard
    @StateObject private var setup: SetupModel

    init() {
        _setup = StateObject(wrappedValue: SetupModel(paths: .standard))
    }

    var body: some View {
        Group {
            if setup.phase == .ready {
                BenchView(paths: paths)
            } else {
                SetupView(model: setup)
            }
        }
        .onAppear {
            setup.markReadyIfInstalled()
        }
    }
}

private struct BenchView: View {
    let paths: AppPaths

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

    init(paths: AppPaths) {
        self.paths = paths
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
        HSplitView {
            SidePanel(
                paths: paths,
                device: device,
                apk: apk,
                scanner: scanner,
                run: run,
                session: session,
                profileIndex: $profileIndex,
                customWidth: $customWidth,
                customHeight: $customHeight,
                customDensity: $customDensity,
                showsCustomResolution: $showsCustomResolution
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            DeviceArea(device: device, mirror: mirror, screenshot: screenshot)
                .frame(minWidth: 480)
        }
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
            // 退出时先卸包、再关设备：设备关了 adb 就卸不掉了。
            ShutdownCoordinator.shared.perform = {
                scanner.shutdown()
                await session.shutdown()
                try? await device.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 保证屏幕录制指示灯熄灭，不留后台捕获。
            scanner.shutdown()
        }
        .onDisappear {
            // 主窗口关闭后 BenchView 会消失；取景框和录制指示灯不能留在后台。
            scanner.shutdown()
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
            }
        }
    }
}

private struct SidePanel: View {
    let paths: AppPaths
    @ObservedObject var device: EmulatorController
    @ObservedObject var apk: APKPanelModel
    @ObservedObject var scanner: ScreenScannerModel
    @ObservedObject var run: RunModel
    @ObservedObject var session: SessionModel
    @Binding var profileIndex: Int
    @Binding var customWidth: String
    @Binding var customHeight: String
    @Binding var customDensity: String
    @Binding var showsCustomResolution: Bool

    @State private var actionError: String?
    @State private var showsAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("UI验收台")
                .font(.title2.weight(.semibold))

            APKPanelView(model: apk, scanner: scanner)

            if let notice = session.recoveryNotice {
                Label(notice, systemImage: "arrow.counterclockwise.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("机型")
                    .font(.headline)
                Picker("", selection: $profileIndex) {
                    ForEach(Array(DeviceProfile.presets.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(index)
                    }
                    Text("自定义").tag(-1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: profileIndex) { newValue in
                    guard newValue >= 0 else { return }
                    switchToPreset(newValue)
                }

                Text(profileSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("自定义分辨率", isExpanded: $showsCustomResolution) {
                    HStack(spacing: 6) {
                        TextField("宽", text: $customWidth)
                        TextField("高", text: $customHeight)
                        TextField("DPI", text: $customDensity)
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                    Button("应用") {
                        applyCustomResolution()
                    }
                    .disabled(customProfile == nil)
                }
            }

            Button(action: toggleDevice) {
                Text(deviceButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(isBusy)

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 团队 ID 没写成时设备仍然能用，但显示的只是本机 ID。
            // 必须在「运行」之前说清楚，避免把它当团队 ID 发给开发。
            if let warning = device.provisioningWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let acquired = apk.acquired {
                Divider()
                runSection(acquired)
            }

            Spacer()

            DiagnosticsView(paths: paths, device: device)

            HStack {
                Spacer()
                Button("关于") { showsAbout = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsAbout) {
            AboutView()
        }
    }

    @ViewBuilder
    private func runSection(_ apk: AcquiredAPK) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行")
                .font(.headline)

            if run.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(run.statusText ?? "正在运行…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    run.run(apk)
                } label: {
                    Label(run.isRunning ? "重新运行" : "运行应用", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!device.isRunning || !apk.compatibility.isCompatible)
                .help(device.isRunning
                      ? "会先清空应用数据，等同于第一次打开"
                      : "先启动设备")
            }

            if run.isRunning {
                Label("应用已启动", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

                HStack(spacing: 8) {
                    Button("保留数据重开") { run.resume(apk) }
                        .help("不删数据，只结束进程再启动——看「第二次打开」的界面")
                    Button("清数据重开") { run.restartClearingData(apk) }
                    Button("完全重装") { run.reinstall(apk) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(run.isBusy)
            }

            if let identity = run.identity {
                deviceIdentitySection(identity, packageName: apk.info.packageName)
            }

            if let message = run.failureText {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 开发在测试环境按「设备 ID」加白名单时，要的是应用自己看到的 Android ID。
    /// 系统里 `settings get secure android_id` 拿到的是设备种子，和应用看到的
    /// 不是一个值，所以这里从 SSAID 表里按包名取。
    @ViewBuilder
    private func deviceIdentitySection(_ identity: DeviceIdentity, packageName: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let androidID = identity.androidID {
                HStack(spacing: 6) {
                    Text("设备 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(androidID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制") { copyToPasteboard(androidID) }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                // 有的反馈后台存的是 Android ID 的 MD5（32 位）。两种都给出，
                // 设计同事按后台实际显示的那一列复制即可。
                HStack(spacing: 6) {
                    Text("MD5")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(DeviceFingerprint.md5(of: androidID))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("复制 MD5") {
                        copyToPasteboard(DeviceFingerprint.md5(of: androidID))
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help("反馈后台显示 32 位设备 ID 时，发这个")
                }
            } else {
                HStack(spacing: 6) {
                    Text("设备 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("应用还没读取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let packageName {
                        Button("刷新") { run.refreshIdentity(packageName: packageName) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if device.teamKeyActive {
                Label(
                    "团队设备 ID 已启用：全团队、所有同一套证书的包共用这个 ID。",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(identityExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(identity.model) · 序列号 \(identity.serial)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .help("模拟器没有 OAID，IMEI 也为空；应用在模拟器上用的是 Android ID。")
    }

    private var identityExplanation: String {
        if device.teamKeyActive {
            return "发给开发加测试白名单，配一次即可。全团队、所有同一套签名证书的包共用这一个 ID；"
                + "反复运行、清数据、重装、换电脑都不会变。"
        }
        return "发给开发加测试白名单，配一次即可。同一个包反复运行、清数据、重装都不会变；"
            + "同一套签名证书签的包共用这个 ID。"
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var profileSummary: String {
        if profileIndex >= 0, DeviceProfile.presets.indices.contains(profileIndex) {
            let profile = DeviceProfile.presets[profileIndex]
            return "\(profile.width) × \(profile.height) · \(profile.density) dpi"
        }
        if let custom = customProfile {
            return "\(custom.width) × \(custom.height) · \(custom.density) dpi"
        }
        return "宽高和 DPI 都要填正整数"
    }

    private var customProfile: DeviceProfile? {
        guard let width = Int(customWidth), let height = Int(customHeight),
              let density = Int(customDensity),
              width > 0, height > 0, density > 0
        else { return nil }
        return DeviceProfile(name: "自定义", width: width, height: height, density: density)
    }

    private var deviceButtonTitle: String {
        switch device.state {
        case .stopped:
            return "启动设备"
        case .starting:
            return "正在启动…"
        case .stopping:
            return "正在停止…"
        case .running:
            return "停止设备"
        case .failed:
            return "重试启动"
        }
    }

    /// 启动和停止都要等模拟器进程真的走完，这段时间按钮必须锁住，
    /// 否则会一边存快照一边再起一台，撞上快照锁直接 FATAL。
    private var isBusy: Bool {
        switch device.state {
        case .starting, .stopping: return true
        case .stopped, .running, .failed: return false
        }
    }

    private var statusMessage: String? {
        if let actionError { return actionError }
        if case let .failed(message) = device.state { return message }
        return nil
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
        guard let profile = customProfile else { return }
        actionError = nil
        profileIndex = -1
        Task {
            do {
                try await device.switchProfile(to: profile)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct DeviceArea: View {
    @ObservedObject var device: EmulatorController
    @ObservedObject var mirror: MirrorModel
    @ObservedObject var screenshot: ScreenshotModel

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if case .streaming = mirror.state {
                VStack(spacing: 14) {
                    // 画面层铺满整个右栏，手机屏在中间等比显示。这样鼠标落在
                    // 画面旁边的空白处也能滚动/聚焦，而不是「只有对着手机才有反应」。
                    // 黑边上的点击仍会被坐标映射丢掉，不会误触。
                    VideoSurface(display: mirror.display)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.45), lineWidth: 6)
                        )

                    navigationBar
                    if let message = screenshot.errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                }
                .padding(24)
            } else {
                statusView
            }
        }
    }

    /// 设备上的三个系统键。
    private var navigationBar: some View {
        HStack(spacing: 10) {
            deviceKeyButton("返回", systemImage: "chevron.backward", key: .back, hint: "返回")
            deviceKeyButton("主页", systemImage: "house", key: .home, hint: "回到桌面")
            deviceKeyButton("多任务", systemImage: "rectangle.on.rectangle", key: .appSwitch, hint: "最近任务")

            Divider().frame(height: 18)

            Button {
                screenshot.capture()
            } label: {
                if screenshot.isCapturing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("截图中…")
                    }
                } else {
                    Label("截图", systemImage: "camera")
                }
            }
            .disabled(screenshot.isCapturing)
            .help("抓取当前画面，冻结后标注")
        }
        .buttonStyle(.bordered)
    }

    private func deviceKeyButton(
        _ title: String,
        systemImage: String,
        key: AndroidKey,
        hint: String
    ) -> some View {
        Button {
            mirror.pressKey(key)
            // 点完按钮把焦点还给画面，接着敲键盘仍然直接进设备。
            mirror.display.window?.makeFirstResponder(mirror.display)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .help(hint)
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(spacing: 12) {
            if case .starting = mirror.state, device.isRunning {
                ProgressView()
                Text("正在连接画面…")
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = mirror.state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else if case .ended = mirror.state {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("画面流已结束，停止设备后可以重新启动。")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("这里将显示手机画面")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
