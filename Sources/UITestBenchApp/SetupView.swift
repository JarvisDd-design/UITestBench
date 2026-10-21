import AppKit
import SwiftUI
import UITestBenchCore

struct SetupView: View {
    @ObservedObject var model: SetupModel

    @State private var showsMirrorSettings = false
    @State private var repositoryURLText = SdkBootstrapConfiguration.default.repositoryURL.absoluteString
    @State private var systemImageURLText = SdkBootstrapConfiguration.default.systemImageRepositoryURL.absoluteString

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)

            Image(systemName: "shippingbox")
                .font(.system(size: 54, weight: .light))
                .foregroundColor(.accentColor)

            Text("先准备 Android 运行环境")
                .font(.system(size: 26, weight: .semibold))

            Text("首次使用需要下载平台工具、模拟器和 Android 14 系统镜像，约 1.5–2 GB。\n下载支持断点续传，中途关掉应用，下次会接着下。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content

            Spacer(minLength: 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .failed:
            idleOrFailed
        case .preparing, .installing:
            running
        case .ready:
            EmptyView()
        }
    }

    private var idleOrFailed: some View {
        VStack(spacing: 14) {
            if case let .failed(message) = model.phase {
                Text(message)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(primaryTitle) {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)

                Button("从离线包导入…") {
                    importOfflineFolder()
                }
            }

            DisclosureGroup("镜像设置", isExpanded: $showsMirrorSettings) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("组件清单地址")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("repository2-3.xml", text: $repositoryURLText)
                        .textFieldStyle(.roundedBorder)

                    Text("系统镜像清单地址")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("sys-img2-3.xml", text: $systemImageURLText)
                        .textFieldStyle(.roundedBorder)

                    Button("应用") {
                        applyMirrorSettings()
                    }
                    .disabled(!hasValidMirrorURLs)

                    Text("默认走 Google 官方源；换镜像只需替换这两个清单地址。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 6)
            }
            .frame(maxWidth: 520)
        }
    }

    private var running: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progressFraction ?? 0)
                .frame(width: 380)

            Text(model.statusText)
                .foregroundColor(.secondary)

            Button("取消") {
                model.cancel()
            }
        }
    }

    private var primaryTitle: String {
        if case .failed = model.phase {
            return "重试"
        }
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
