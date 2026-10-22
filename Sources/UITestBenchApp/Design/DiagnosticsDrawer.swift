import AppKit
import SwiftUI
import UITestBenchCore

struct DiagnosticsDrawer: View {
    let paths: AppPaths
    @ObservedObject var device: EmulatorController

    @Environment(\.benchPalette) private var palette
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let log = logTail, !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(8)
                .background(
                    palette.surfaceOpaque.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            } else {
                Text("还没有模拟器日志。")
                    .font(.caption)
                    .foregroundStyle(palette.textTertiary)
            }

            Button(didCopy ? "已复制" : "复制诊断信息") {
                copyReport()
            }
            .buttonStyle(BenchSecondaryButtonStyle(height: 30))
        }
    }

    private var summary: String {
        var parts = ["组件：\(sdkReady ? "已就绪" : "未就绪")", "设备：\(deviceStateText)"]
        if case .running = device.state {
            parts.append(device.serial)
        }
        return parts.joined(separator: " · ")
    }

    private var sdkReady: Bool {
        let installer = SdkInstaller(root: paths.sdkDirectory)
        return ["platform-tools", "emulator", "system-images"].allSatisfy {
            installer.isInstalled($0)
        }
    }

    private var deviceStateText: String {
        switch device.state {
        case .stopped: return "已停止"
        case .starting: return "正在启动"
        case .stopping: return "正在停止"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }

    private var logTail: String? {
        LogTail.lastLines(of: paths.emulatorLogURL, count: 40)
    }

    private func copyReport() {
        let report = DiagnosticsReport(
            appVersion: AboutView.appVersion,
            supportDirectory: paths.supportDirectory.path,
            sdkReady: sdkReady,
            deviceState: deviceStateText,
            serial: device.isRunning ? device.serial : nil,
            logTail: logTail
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
