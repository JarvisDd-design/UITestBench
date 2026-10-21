import AppKit
import SwiftUI
import UITestBenchCore

/// 折叠在左栏底部的「诊断」：平时不碍事，出事时能一键把现场带走。
struct DiagnosticsView: View {
    let paths: AppPaths
    @ObservedObject var device: EmulatorController

    @State private var isExpanded = false
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup("诊断", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let log = logTail, !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button(didCopy ? "已复制" : "复制诊断信息") {
                    copyReport()
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .font(.caption)
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
