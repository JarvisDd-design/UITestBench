import SwiftUI
import UITestBenchCore

/// 手机舞台：外壳里放画面或待机屏，下方挂操作胶囊。
/// 不持有任何模型，状态与动作都由调用方给。
struct PhoneStage: View {
    @ObservedObject var device: EmulatorController
    @ObservedObject var mirror: MirrorModel
    @ObservedObject var screenshot: ScreenshotModel
    @ObservedObject var run: RunModel
    @ObservedObject var apk: APKPanelModel

    let profile: DeviceProfile
    let onStartDevice: () -> Void
    let onScan: () -> Void
    let onChooseFile: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = PhoneLayoutCalculator.layout(
                available: proxy.size,
                profile: profile
            )

            VStack(spacing: PhoneLayoutCalculator.capsuleGap) {
                PhoneFrame(layout: layout) {
                    screen
                }

                ActionCapsule(
                    device: device,
                    apk: apk,
                    run: run,
                    screenshot: screenshot,
                    onRun: runCurrentAPK,
                    onResume: resume,
                    onRestartClearing: restartClearing,
                    onReinstall: reinstall
                )
                .frame(width: layout.screenSize.width + layout.bezel * 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var screen: some View {
        if case .streaming = mirror.state {
            VideoSurface(display: mirror.display)
                .accessibilityLabel("手机屏幕画面")
        } else {
            StandbyScreen(
                device: device,
                apk: apk,
                mirror: mirror,
                onStartDevice: onStartDevice,
                onScan: onScan,
                onChooseFile: onChooseFile,
                onReconnect: onReconnect
            )
        }
    }

    private func runCurrentAPK() {
        guard let acquired = apk.acquired else { return }
        run.run(acquired)
    }

    private func resume() {
        guard let acquired = apk.acquired else { return }
        run.resume(acquired)
    }

    private func restartClearing() {
        guard let acquired = apk.acquired else { return }
        run.restartClearingData(acquired)
    }

    private func reinstall() {
        guard let acquired = apk.acquired else { return }
        run.reinstall(acquired)
    }
}
