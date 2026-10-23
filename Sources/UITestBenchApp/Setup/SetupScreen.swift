import AppKit
import SwiftUI
import UITestBenchCore

struct SetupScreen: View {
    @ObservedObject var model: SetupModel

    @Environment(\.benchPalette) private var palette
    @State private var showsMirrorSettings = false
    @State private var repositoryURLText = SdkBootstrapConfiguration.default.repositoryURL.absoluteString
    @State private var systemImageURLText = SdkBootstrapConfiguration.default.systemImageRepositoryURL.absoluteString

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(palette.limeInk)
                    Text("准备 Android 环境")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("首次使用需要下载平台工具、模拟器和 Android 14 系统镜像，约 1.5–2 GB。支持断点续传。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        stepRow(title: step.title, state: step.state)
                    }
                }

                if let fraction = model.progressFraction {
                    ProgressView(value: fraction)
                        .tint(palette.lime)
                }

                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case let .failed(message) = model.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("详细日志在「诊断」抽屉里。")
                        .font(.caption2)
                        .foregroundStyle(palette.textTertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(primaryTitle) { model.start() }
                        .buttonStyle(BenchPrimaryButtonStyle(height: 36))
                        .disabled(model.isRunning)

                    if model.isRunning {
                        Button("取消下载") { model.cancel() }
                            .buttonStyle(BenchSecondaryButtonStyle(height: 32))
                    }

                    Button("从离线包导入…") { importOfflineFolder() }
                        .buttonStyle(BenchSecondaryButtonStyle(height: 32))
                        .disabled(model.isRunning)
                }

                DisclosureGroup("镜像设置", isExpanded: $showsMirrorSettings) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("组件清单地址")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                        TextField("repository2-3.xml", text: $repositoryURLText)
                            .textFieldStyle(.roundedBorder)

                        Text("系统镜像清单地址")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                        TextField("sys-img2-3.xml", text: $systemImageURLText)
                            .textFieldStyle(.roundedBorder)

                        Button("应用") { applyMirrorSettings() }
                            .buttonStyle(BenchSecondaryButtonStyle(height: 28))
                            .disabled(!hasValidMirrorURLs)

                        Text("默认走 Google 官方源；换镜像只需替换这两个清单地址。")
                            .font(.caption2)
                            .foregroundStyle(palette.textTertiary)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(palette.textPrimary)
            }
            .padding(20)
        }
    }

    private enum StepState {
        case pending
        case active
        case done
    }

    private var steps: [(title: String, state: StepState)] {
        switch model.phase {
        case .idle, .failed:
            return [("组件清单", .pending), ("下载与安装", .pending), ("完成", .pending)]
        case .preparing:
            return [("组件清单", .active), ("下载与安装", .pending), ("完成", .pending)]
        case .installing:
            return [("组件清单", .done), ("下载与安装", .active), ("完成", .pending)]
        case .ready:
            return [("组件清单", .done), ("下载与安装", .done), ("完成", .done)]
        }
    }

    private func stepRow(title: String, state: StepState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .done ? palette.limeInk : palette.textTertiary)
            Text(title)
                .font(.caption)
                .foregroundStyle(state == .pending ? palette.textTertiary : palette.textPrimary)
            Spacer()
            if state == .active {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var primaryTitle: String {
        if case .failed = model.phase { return "重试" }
        return "开始准备"
    }

    private var hasValidMirrorURLs: Bool {
        guard let repository = URL(string: repositoryURLText),
              let systemImage = URL(string: systemImageURLText)
        else { return false }
        return repository.scheme?.hasPrefix("http") == true
            && systemImage.scheme?.hasPrefix("http") == true
    }

    private func applyMirrorSettings() {
        guard let repository = URL(string: repositoryURLText),
              let systemImage = URL(string: systemImageURLText)
        else { return }

        let current = model.configuration
        model.configuration = SdkBootstrapConfiguration(
            repositoryURL: repository,
            systemImageRepositoryURL: systemImage,
            systemImagePackagePath: current.systemImagePackagePath,
            hostOS: current.hostOS,
            hostArch: current.hostArch
        )
        showsMirrorSettings = false
    }

    private func importOfflineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择存放平台工具、模拟器和系统镜像压缩包的文件夹"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.start(offlineFolder: folder)
    }
}
