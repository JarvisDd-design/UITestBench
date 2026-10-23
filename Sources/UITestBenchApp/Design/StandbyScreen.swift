import SwiftUI
import UITestBenchCore

struct StandbyScreen: View {
    @ObservedObject var device: EmulatorController
    @ObservedObject var apk: APKPanelModel
    @ObservedObject var mirror: MirrorModel

    let onStartDevice: () -> Void
    let onScan: () -> Void
    let onChooseFile: () -> Void
    let onReconnect: () -> Void

    @Environment(\.benchPalette) private var palette
    @State private var isDropTargeted = false

    var body: some View {
        let state = StandbyScreenStateResolver.resolve(
            StandbyScreenInput(
                isStarting: isTransitioning,
                failure: failureMessage,
                hasAPK: apk.acquired?.compatibility.isCompatible == true,
                deviceRunning: device.isRunning
            )
        )
        // 拖入高亮和接收判定共用同一个条件：设备运行时手机屏是触摸面，不接收文件。
        let acceptsDrop = DropTargetPolicy.acceptsDrop(deviceRunning: device.isRunning)

        ZStack {
            LinearGradient(
                colors: [palette.canvas, palette.canvas.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 14) {
                Image(systemName: icon(for: state))
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(palette.limeInk)
                    .accessibilityHidden(true)

                Text(title(for: state))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle(for: state))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                actions(for: state)

                if state == .needsAPK || state == .readyToStart {
                    Text("也可以把 APK 拖到这里")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .padding(24)
        }
        .overlay(
            Rectangle()
                .strokeBorder(palette.lime, lineWidth: isDropTargeted && acceptsDrop ? 3 : 0)
        )
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            guard acceptsDrop else { return false }
            return apk.accept(droppedProviders: providers)
        }
    }

    @ViewBuilder
    private func actions(for state: StandbyScreenState) -> some View {
        switch state {
        case .needsAPK:
            VStack(spacing: 8) {
                Button("扫描屏幕二维码", action: onScan)
                    .buttonStyle(BenchPrimaryButtonStyle(height: 34))
                Button("选择本地文件…", action: onChooseFile)
                    .buttonStyle(BenchSecondaryButtonStyle(height: 30))
            }
        case .readyToStart:
            Button("启动设备", action: onStartDevice)
                .buttonStyle(BenchPrimaryButtonStyle(height: 34))
        case .failed:
            if device.isRunning {
                Button("重新连接画面", action: onReconnect)
                    .buttonStyle(BenchPrimaryButtonStyle(height: 34))
            } else {
                Button("重试启动", action: onStartDevice)
                    .buttonStyle(BenchPrimaryButtonStyle(height: 34))
            }
        case .starting, .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title(for: state))
        }
    }

    /// 启动和停止都是过渡态：两种都先显示进度，标题再靠 `isStopping` 区分。
    private var isTransitioning: Bool {
        if case .starting = device.state { return true }
        if case .stopping = device.state { return true }
        return false
    }

    private var isStopping: Bool {
        if case .stopping = device.state { return true }
        return false
    }

    private var failureMessage: String? {
        if case let .failed(message) = device.state { return message }
        // 画面失败只在设备运行时算数：停止设备时 MirrorModel.stop() 虽然会归零，
        // 但镜像启动是异步的，停止后仍可能收到迟到的 .failed。
        if device.isRunning, case let .failed(message) = mirror.state { return message }
        return nil
    }

    private func title(for state: StandbyScreenState) -> String {
        switch state {
        case .starting: return isStopping ? "正在停止设备…" : "正在启动设备…"
        case .failed: return device.isRunning ? "画面连接失败" : "启动失败"
        case .needsAPK: return "还没有可运行的 APK"
        case .readyToStart: return "APK 已就绪"
        case .connecting: return "正在连接画面…"
        }
    }

    private func subtitle(for state: StandbyScreenState) -> String {
        switch state {
        case .starting:
            return isStopping ? "保存快照后会关掉模拟器" : "首次启动大约需要 30–60 秒"
        case let .failed(message): return message
        case .needsAPK: return "扫描屏幕上的二维码，或把 APK 拖进这块屏幕"
        case .readyToStart: return "启动设备后就能安装运行"
        case .connecting: return "设备已经起来，画面流还在接"
        }
    }

    private func icon(for state: StandbyScreenState) -> String {
        switch state {
        case .starting, .connecting: return "iphone"
        case .failed: return "exclamationmark.triangle"
        case .needsAPK: return "qrcode.viewfinder"
        case .readyToStart: return "play.circle"
        }
    }
}
