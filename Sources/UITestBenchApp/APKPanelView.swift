import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UITestBenchCore

/// 左侧「APK 来源」区的状态机：空 → 正在拿 → 拿到 / 失败。
///
/// 三种入口（拖放、粘贴链接、选择文件）最终都交给 `APKSourceResolver`，
/// 这里只负责展示进度与结果，不做任何解析判断。
@MainActor
final class APKPanelModel: ObservableObject {
    enum State: Equatable {
        case empty
        case loading(description: String)
        case loaded(AcquiredAPK)
        case failed(String)
    }

    @Published private(set) var state: State = .empty
    @Published private(set) var progress: Double?
    @Published var linkText = ""

    private let acquirer: APKAcquirer
    private var currentTask: Task<Void, Never>?

    init(paths: AppPaths) {
        acquirer = APKAcquirer(directory: paths.apkDirectory)
    }

    var acquired: AcquiredAPK? {
        if case let .loaded(apk) = state { return apk }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func accept(droppedFile url: URL) {
        load(sourceName: url.lastPathComponent) {
            try APKSourceResolver.source(forDroppedFile: url)
        }
    }

    func accept(pastedLink text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        load(sourceName: trimmed) {
            try APKSourceResolver.source(forPastedLink: trimmed)
        }
    }

    /// 拖动进来的东西从 `NSItemProvider` 取出文件地址。
    /// 图片里如果直接带数据而不是文件，这里暂时不处理——从 Finder 拖出来都是文件。
    func accept(droppedProviders providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = Self.fileURL(from: item) else { return }
            Task { @MainActor in
                self.accept(droppedFile: url)
            }
        }
        return true
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        progress = nil
        state = .empty
    }

    private func load(sourceName: String, source: @escaping () throws -> APKSource) {
        currentTask?.cancel()
        progress = nil
        state = .loading(description: sourceName)

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try source()
                let acquired = try await acquirer.acquire(resolved) { update in
                    let fraction = update.fraction
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                    }
                }
                guard !Task.isCancelled else { return }
                progress = nil
                state = .loaded(acquired)
            } catch is CancellationError {
                // 用户换了来源或点了取消，状态已经由新的动作接管。
            } catch let error as APKSourceError {
                guard !Task.isCancelled else { return }
                progress = nil
                state = .failed(error.explanation)
            } catch let error as APKAcquisitionError {
                guard !Task.isCancelled else { return }
                progress = nil
                state = .failed(error.explanation)
            } catch {
                guard !Task.isCancelled else { return }
                progress = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}

/// 左栏的 APK 区：拖放框 + 链接输入 + 本地文件，下面是包信息和兼容性结论。
struct APKPanelView: View {
    @ObservedObject var model: APKPanelModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APK")
                .font(.headline)

            dropZone

            HStack(spacing: 6) {
                TextField("粘贴 APK 下载链接", text: $model.linkText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.accept(pastedLink: model.linkText) }
                Button("获取") {
                    model.accept(pastedLink: model.linkText)
                }
                .disabled(model.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("选择本地文件…") {
                chooseFile()
            }
            .buttonStyle(.link)
            .font(.caption)

            stateView
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
            Text("拖入 APK 或二维码截图")
                .font(.callout)
            Text("也可以拖入一张包含下载链接的二维码图片")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.accept(droppedProviders: providers)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.state {
        case .empty:
            EmptyView()

        case let .loading(description):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在获取 \(description)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let fraction = model.progress {
                    ProgressView(value: fraction)
                }
                Button("取消") { model.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

        case let .failed(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .loaded(apk):
            loadedView(apk)
        }
    }

    private func loadedView(_ apk: AcquiredAPK) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(apk.info.applicationLabel ?? "未知应用名")
                .font(.headline)

            infoRow("包名", apk.info.packageName ?? "未知")
            infoRow("版本", versionText(apk.info))
            infoRow("大小", byteText(apk.info.byteCount))
            infoRow("Android", sdkText(apk.info))
            infoRow("架构", abiText(apk.info))

            compatibilityView(apk.compatibility)
        }
        .padding(.top, 2)
    }

    private func compatibilityView(_ report: CompatibilityReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if report.isCompatible {
                Label("可以在这台模拟器上安装", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("这个包装不上", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func versionText(_ info: ApkInfo) -> String {
        switch (info.versionName, info.versionCode) {
        case let (name?, code?): return "\(name)（\(code)）"
        case let (name?, nil): return name
        case let (nil, code?): return "\(code)"
        default: return "未知"
        }
    }

    private func sdkText(_ info: ApkInfo) -> String {
        switch (info.minSdkVersion, info.targetSdkVersion) {
        case let (min?, target?): return "最低 \(min) · 目标 \(target)"
        case let (min?, nil): return "最低 \(min)"
        case let (nil, target?): return "目标 \(target)"
        default: return "未声明"
        }
    }

    private func abiText(_ info: ApkInfo) -> String {
        info.abis.isEmpty ? "纯 Java/Kotlin" : info.abis.joined(separator: "、")
    }

    private func byteText(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["apk", "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.accept(droppedFile: url)
    }
}
