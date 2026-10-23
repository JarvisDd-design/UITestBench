import AppKit
import SwiftUI
import UITestBenchCore

struct SetupScreen: View {
    @ObservedObject var model: SetupModel

    @Environment(\.benchPalette) private var palette
    @State private var showsMirrorSettings = false
    @State private var repositoryURLText = ""
    @State private var systemImageURLText = ""
    /// 应用镜像设置后 `configuration` 不是 @Published，用本地副本刷新「当前生效」两行。
    @State private var effectiveConfiguration: SdkBootstrapConfiguration?
    /// 记住上次来源：离线导入失败后点「重试」仍走离线包，不会静默改走网络。
    @State private var lastOfflineFolder: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(palette.limeInk)
                        .accessibilityHidden(true)
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
                        .tint(palette.limeInk)
                        .accessibilityLabel("安装进度")
                }

                if case let .failed(message) = model.phase {
                    // 失败时不再显示 statusText（内容是同一条错误），只留红色这行，省出约 39pt。
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("详细日志在「诊断」抽屉里。")
                        .font(.caption2)
                        .foregroundStyle(palette.textTertiary)
                } else {
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if model.phase != .ready {
                        Button(primaryTitle) { model.start(offlineFolder: lastOfflineFolder) }
                            .buttonStyle(BenchPrimaryButtonStyle(height: 36))
                            .disabled(model.isRunning)
                            .keyboardShortcut(.defaultAction)
                    }

                    if model.isRunning {
                        Button("取消") { model.cancel() }
                            .buttonStyle(BenchSecondaryButtonStyle(height: 32))
                    }

                    Button("从离线包导入…") { importOfflineFolder() }
                        .buttonStyle(BenchSecondaryButtonStyle(height: 32))
                        .disabled(model.isRunning)
                }

                DisclosureGroup(isExpanded: $showsMirrorSettings) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前组件清单：\(displayHost(shownConfiguration.repositoryURL))")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("当前系统镜像清单：\(displayHost(shownConfiguration.systemImageRepositoryURL))")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("组件清单地址")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                        TextField("repository2-3.xml", text: $repositoryURLText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isRunning)
                            .accessibilityLabel("组件清单地址")

                        Text("系统镜像清单地址")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                        TextField("sys-img2-3.xml", text: $systemImageURLText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isRunning)
                            .accessibilityLabel("系统镜像清单地址")

                        Button("应用") { applyMirrorSettings() }
                            .buttonStyle(BenchSecondaryButtonStyle(height: 28))
                            .disabled(!hasValidMirrorURLs || model.isRunning)

                        if model.isRunning {
                            Text("运行中修改会在下次开始准备时生效")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("默认走 Google 官方源；换镜像只需替换这两个清单地址。")
                                .font(.caption2)
                                .foregroundStyle(palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("镜像设置")
                        .font(.caption)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .padding(20)
        }
        .background(palette.canvas)
        .onAppear(perform: loadConfiguration)
    }

    private enum StepState {
        case pending
        case active
        case done

        var accessibilityDescription: String {
            switch self {
            case .pending: return "等待"
            case .active: return "进行中"
            case .done: return "已完成"
            }
        }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(state.accessibilityDescription)")
    }

    private var primaryTitle: String {
        if case .failed = model.phase { return "重试" }
        return "开始准备"
    }

    private var shownConfiguration: SdkBootstrapConfiguration {
        effectiveConfiguration ?? model.configuration
    }

    private var hasValidMirrorURLs: Bool {
        MirrorSettingsValidation.endpoints(
            repository: repositoryURLText,
            systemImage: systemImageURLText
        ) != nil
    }

    private func displayHost(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }

    private func loadConfiguration() {
        // 只同步一次，避免重新出现时覆盖用户正在编辑的输入。
        guard effectiveConfiguration == nil else { return }
        let configuration = model.configuration
        effectiveConfiguration = configuration
        repositoryURLText = configuration.repositoryURL.absoluteString
        systemImageURLText = configuration.systemImageRepositoryURL.absoluteString
    }

    private func applyMirrorSettings() {
        guard let endpoints = MirrorSettingsValidation.endpoints(
            repository: repositoryURLText,
            systemImage: systemImageURLText
        ) else { return }

        let current = shownConfiguration
        let updated = SdkBootstrapConfiguration(
            repositoryURL: endpoints.repository,
            systemImageRepositoryURL: endpoints.systemImage,
            systemImagePackagePath: current.systemImagePackagePath,
            hostOS: current.hostOS,
            hostArch: current.hostArch
        )
        model.configuration = updated
        effectiveConfiguration = updated
        repositoryURLText = endpoints.repository.absoluteString
        systemImageURLText = endpoints.systemImage.absoluteString
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
        lastOfflineFolder = folder
        model.start(offlineFolder: folder)
    }
}
