import SwiftUI
import UITestBenchCore

/// 手机下方的操作胶囊：运行、截图、重开。状态判定全在 Core 的
/// `ActionCapsuleResolver` 里，这里只负责摆按钮。
struct ActionCapsule: View {
    @ObservedObject var device: EmulatorController
    @ObservedObject var apk: APKPanelModel
    @ObservedObject var run: RunModel
    @ObservedObject var screenshot: ScreenshotModel

    let onRun: () -> Void
    let onResume: () -> Void
    let onRestartClearing: () -> Void
    let onReinstall: () -> Void

    @Environment(\.benchPalette) private var palette

    var body: some View {
        let state = ActionCapsuleResolver.resolve(
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

        Group {
            if state == .hidden {
                Color.clear
            } else {
                capsule(state)
            }
        }
        // 隐藏时也占住胶囊槽位，避免设备状态切换时整块界面跳动。
        .frame(height: PhoneLayoutCalculator.capsuleHeight)
    }

    @ViewBuilder
    private func capsule(_ state: ActionCapsuleState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .hidden:
                EmptyView()

            case .screenshotOnly:
                screenshotButton

            case .waitingForDevice:
                Text("启动设备后可运行")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                screenshotButton

            case .readyToRun:
                Button("运行应用") { onRun() }
                    .buttonStyle(BenchPrimaryButtonStyle(height: 30))
                screenshotButton

            case .running:
                HStack(spacing: 6) {
                    Circle()
                        .fill(palette.lime)
                        .frame(width: 8, height: 8)
                        .shadow(color: palette.lime.opacity(0.6), radius: 4)
                    Text("运行中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                }
                screenshotButton
                restartMenu

            case let .busy(text):
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: PhoneLayoutCalculator.capsuleHeight)
        // 与 DockDrawer 同一套垫高：不透明卡面靠近内容，材质放最底层，
        // 避免文字对比度被桌面壁纸决定。
        .background(
            Capsule().fill(palette.surfaceOpaque.opacity(0.9))
        )
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(palette.separator.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: palette.shadowNear, radius: 12, y: 5)
    }

    private var screenshotButton: some View {
        Button {
            screenshot.capture()
        } label: {
            Label("截图", systemImage: "camera")
        }
        .buttonStyle(BenchSecondaryButtonStyle(height: 28))
        .disabled(!device.isRunning || screenshot.isCapturing)
        .help("抓取当前画面，冻结后标注")
    }

    private var restartMenu: some View {
        Menu {
            Button("保留数据重开") { onResume() }
            Button("清数据重开") { onRestartClearing() }
            Button("完全重装") { onReinstall() }
        } label: {
            Label("重开", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(run.isBusy)
        .help("不删数据、清数据或完全重装后重新启动")
    }
}
