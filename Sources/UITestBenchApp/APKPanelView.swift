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

    /// 扫码命中后先停在确认条上，用户点「下载」才真正开始。
    struct ScanNotice: Equatable {
        let link: DownloadLink
    }

    @Published private(set) var state: State = .empty
    @Published private(set) var progress: Double?
    @Published private(set) var scanNotice: ScanNotice?
    @Published var linkText = ""

    private let acquirer: APKAcquirer
    private var currentTask: Task<Void, Never>?
    /// 每次换来源都会推进；旧任务迟到的进度和结果不许覆盖新任务。
    private var loadID = 0

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

    /// 截图数据：剪贴板、拖入的图片、浏览器里直接拖出来的图都走这里。
    func accept(imageData data: Data) {
        load(sourceName: "二维码截图") {
            try APKSourceResolver.source(forImageData: data)
        }
    }

    /// 选择本地 APK 或二维码截图。放在 model 里，扫码的「改用截图」
    /// 可以直接调用，不会把视图一起保活。
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            "apk", "png", "jpg", "jpeg", "heic", "heif", "gif",
            "tiff", "tif", "bmp", "webp", "avif",
        ].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(droppedFile: url)
    }

    /// 拖动进来的东西可能是文件、图片数据、链接或纯文本。
    func accept(droppedProviders providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.fileURL(from: item) else { return }
                Task { @MainActor in
                    self.accept(droppedFile: url)
                }
            }
            return true
        }

        let imageTypes: [UTType] = [.image, .png, .tiff, .jpeg, .heic]
        if let type = imageTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self.accept(imageData: data)
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    self.linkText = url.absoluteString
                    self.accept(pastedLink: url.absoluteString)
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                guard let text = item as? String else { return }
                Task { @MainActor in
                    self.linkText = text
                    self.accept(pastedLink: text)
                }
            }
            return true
        }

        return false
    }

    /// ⌘⇧V：从剪贴板拿截图、文件或链接。
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            accept(droppedFile: url)
            return
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            accept(imageData: data)
            return
        }

        // 有些聊天工具只提供 NSImage，不直接给 PNG/TIFF 数据。
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?
            .first as? NSImage,
           let data = image.tiffRepresentation {
            accept(imageData: data)
            return
        }

        if let urlString = pasteboard.string(forType: .URL) {
            linkText = urlString
            accept(pastedLink: urlString)
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            linkText = text
            accept(pastedLink: text)
            return
        }

        // 空剪贴板不能把正在下载或已经拿到的包冲掉，只提醒一下。
        guard !isLoading, scanNotice == nil, acquired == nil else {
            NSSound.beep()
            return
        }
        state = .failed("剪贴板里没有图片或链接。先复制一张带二维码的截图，或复制 APK 下载链接。")
    }

    // MARK: - 扫码结果

    func presentScannedLink(_ link: DownloadLink) {
        currentTask?.cancel()
        currentTask = nil
        loadID += 1
        progress = nil
        state = .empty
        scanNotice = ScanNotice(link: link)
    }

    func downloadScannedLink() {
        guard let notice = scanNotice else { return }
        scanNotice = nil
        load(
            sourceName: "\(notice.link.host)/\(notice.link.fileName)",
            policy: .scanned,
            scanned: true
        ) {
            .remote(notice.link.url)
        }
    }

    func dismissScanNotice() {
        scanNotice = nil
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        loadID += 1
        progress = nil
        state = .empty
    }

    private func load(
        sourceName: String,
        policy: APKAcquisitionPolicy = .standard,
        scanned: Bool = false,
        source: @escaping @Sendable () throws -> APKSource
    ) {
        currentTask?.cancel()
        loadID += 1
        let id = loadID
        scanNotice = nil
        progress = nil
        state = .loading(description: sourceName)

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 解码截图、校验链接是同步 CPU 活；放到后台，大截图不会卡住界面。
                let resolved = try await Task.detached(priority: .userInitiated) {
                    try source()
                }.value
                guard id == self.loadID, !Task.isCancelled else { return }

                let acquired = try await self.acquirer.acquire(resolved, policy: policy) { update in
                    let fraction = update.fraction
                    Task { @MainActor [weak self] in
                        guard let self, id == self.loadID else { return }
                        self.progress = fraction
                    }
                }
                guard id == self.loadID, !Task.isCancelled else { return }
                self.progress = nil
                self.state = .loaded(acquired)
            } catch is CancellationError {
                // 用户换了来源或点了取消，状态已经由新的动作接管。
            } catch let error as APKSourceError {
                guard id == self.loadID, !Task.isCancelled else { return }
                self.progress = nil
                self.state = .failed(error.explanation)
            } catch let error as APKAcquisitionError {
                guard id == self.loadID, !Task.isCancelled else { return }
                self.progress = nil
                self.state = .failed(scanned ? Self.scannedExplanation(for: error) : error.explanation)
            } catch {
                guard id == self.loadID, !Task.isCancelled else { return }
                self.progress = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// 扫码下载失败时补一句「二维码里可能不是 APK」，比裸的错误码更像人话。
    private static func scannedExplanation(for error: APKAcquisitionError) -> String {
        if case .inspection(.notAZipArchive) = error {
            return "下载完成了，但这个文件不是 APK。二维码里可能是一个网页或普通文件。"
        }
        return error.explanation
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}

/// 左栏的 APK 区：拖放框 + 链接输入 + 本地文件，下面是包信息和兼容性结论。
struct APKPanelView: View {
    @ObservedObject var model: APKPanelModel
    @ObservedObject var scanner: ScreenScannerModel
    @State private var isDropTargeted = false
    @Environment(\.benchPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 扫码是主入口：对准飞书/浏览器里的码就行，不用先截图。
            Button {
                scanner.start(from: NSApp.keyWindow)
            } label: {
                Label("扫描屏幕二维码", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BenchPrimaryButtonStyle(height: 38))
            .disabled(scanner.isScanning)
            .help("打开可拖动的取景卡片，出现 2 秒后开始扫描")

            scanNoticeView
            scannerIssueView

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

            HStack(spacing: 10) {
                Button("选择本地文件…") {
                    model.chooseFile()
                }
                Button("从剪贴板粘贴") {
                    model.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("粘贴截图、图片文件或下载链接（⌘⇧V）")
            }
            .buttonStyle(.link)
            .font(.caption)

            stateView
        }
    }

    @ViewBuilder
    private var scanNoticeView: some View {
        if let notice = model.scanNotice {
            VStack(alignment: .leading, spacing: 6) {
                Label("识别到下载地址", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.limeInk)
                Text(notice.link.host)
                    .font(.caption)
                Text(notice.link.fileName)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("下载") { model.downloadScannedLink() }
                        .buttonStyle(BenchPrimaryButtonStyle(height: 28))
                    Button("取消") { model.dismissScanNotice() }
                        .buttonStyle(BenchSecondaryButtonStyle(height: 28))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.lime.opacity(0.14))
            )
        }
    }

    @ViewBuilder
    private var scannerIssueView: some View {
        switch scanner.state {
        case let .permissionDenied(issue):
            VStack(alignment: .leading, spacing: 6) {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .resetNeedsRestart = issue {
                    HStack(spacing: 8) {
                        Button("退出应用") { NSApp.terminate(nil) }
                        Button("稍后") { scanner.dismissIssue() }
                    }
                    .controlSize(.small)
                } else {
                    if issue.offersPermissionActions {
                        HStack(spacing: 8) {
                            Button("打开系统设置") { scanner.openSystemSettings() }
                            Button("重置授权") { scanner.resetPermission() }
                            Button("重新检查") { scanner.recheckPermission() }
                        }
                        .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Button("重试扫描") { scanner.start(from: NSApp.keyWindow) }
                        Button("改用截图…") { scanner.useScreenshotFallback() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.1))
            )

        case let .failed(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("知道了") { scanner.dismissIssue() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

        case .idle, .scanning:
            EmptyView()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
            Text("拖入 APK 或二维码截图")
                .font(.callout)
            Text("也可以拖入链接、图片，或从剪贴板粘贴")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        }
        .foregroundStyle(isDropTargeted ? palette.limeInk : palette.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? palette.limeInk : palette.textTertiary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $isDropTargeted) { providers in
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
                    .foregroundStyle(palette.limeInk)
            } else {
                Label("这个包装不上", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(palette.error)
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
}
