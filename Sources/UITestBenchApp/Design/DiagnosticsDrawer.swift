import AppKit
import SwiftUI
import UITestBenchCore

struct DiagnosticsDrawer: View {
    let paths: AppPaths
    @ObservedObject var device: EmulatorController

    @Environment(\.benchPalette) private var palette
    @State private var didCopy = false
    @State private var logTail: String?
    @State private var copyGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let logTail, !logTail.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(logTail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(palette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            // 末尾锚点：打开抽屉先看到最后几行，出错原因通常在那里。
                            Color.clear
                                .frame(height: 1)
                                .id("logEnd")
                        }
                    }
                    .frame(height: 180)
                    .padding(8)
                    .background(
                        palette.surfaceOpaque.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityLabel("模拟器日志")
                    .onAppear { scrollToBottom(proxy) }
                    .onChange(of: logTail) { _ in scrollToBottom(proxy) }
                }
            } else {
                Text("还没有模拟器日志。")
                    .font(.caption)
                    .foregroundStyle(palette.textTertiary)
            }

            HStack(spacing: 10) {
                Button {
                    copyReport()
                } label: {
                    Text(didCopy ? "已复制" : "复制诊断信息")
                        .frame(minWidth: 78)
                }
                .buttonStyle(BenchSecondaryButtonStyle(height: 30))

                Button("刷新") { refreshLog() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .onAppear { refreshLog() }
        .onChange(of: device.state) { _ in refreshLog() }
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

    private func refreshLog() {
        logTail = LogTail.lastLines(of: paths.emulatorLogURL, count: 40)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // 等这一帧布局完成再滚，否则刚放进去的内容还量不到高度。
        DispatchQueue.main.async {
            proxy.scrollTo("logEnd", anchor: .bottom)
        }
    }

    private func copyReport() {
        refreshLog()
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
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copyGeneration == generation { didCopy = false }
        }
    }
}
