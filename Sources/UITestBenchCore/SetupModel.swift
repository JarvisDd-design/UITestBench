import Combine
import Foundation

public enum SetupPhase: Equatable, Sendable {
    case idle
    case preparing
    case installing(SdkInstallProgress)
    case ready
    case failed(String)
}

public enum OfflineImportError: Error, Equatable {
    /// 文件夹里缺这些归档。
    case missingFiles([String])
}

/// 首次向导的流程模型：拉清单 → 下载 → 解压 → 就绪。
/// 只管状态，不碰界面；界面订阅 `phase` 即可。
@MainActor
public final class SetupModel: ObservableObject {
    @Published public private(set) var phase: SetupPhase = .idle

    /// 镜像源等配置，开始前可改。
    public var configuration: SdkBootstrapConfiguration

    private let paths: AppPaths
    private let downloader: FileDownloader
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var acceptsProgress = false

    public init(
        paths: AppPaths,
        configuration: SdkBootstrapConfiguration = .default,
        downloader: FileDownloader = FileDownloader(),
        session: URLSession = .shared
    ) {
        self.paths = paths
        self.configuration = configuration
        self.downloader = downloader
        self.session = session
    }

    public var isRunning: Bool { task != nil }

    public var progressFraction: Double? {
        switch phase {
        case let .installing(progress):
            return progress.overallFraction
        case .ready:
            return 1
        default:
            return nil
        }
    }

    public var statusText: String {
        switch phase {
        case .idle:
            return "等待开始"
        case .preparing:
            return "正在获取组件清单…"
        case let .installing(progress):
            let name = Self.displayName(for: progress.packagePath)
            let position = "（\(progress.packageIndex)/\(progress.packageCount)）"
            switch progress.phase {
            case let .downloading(download):
                if let fraction = download.fraction {
                    return "正在下载\(name)\(position) \(Int((fraction * 100).rounded()))%"
                }
                return "正在下载\(name)\(position)…"
            case .extracting:
                return "正在解压\(name)\(position)…"
            case .installed:
                return "\(name) 已安装"
            case .skipped:
                return "\(name) 已存在，跳过"
            }
        case .ready:
            return "环境已就绪"
        case let .failed(message):
            return message
        }
    }

    /// 环境三件套都在就不再走向导。
    @discardableResult
    public func markReadyIfInstalled() -> Bool {
        let installer = SdkInstaller(root: paths.sdkDirectory)
        let required = ["platform-tools", "emulator", "system-images"]
        guard required.allSatisfy({ installer.isInstalled($0) }) else { return false }
        phase = .ready
        return true
    }

    /// 需要在主线程调用。
    ///
    /// - Parameter offlineFolder: 选择离线包文件夹时，按清单里的文件名在文件夹中查找归档，
    ///   找到的跳过下载；缺文件会在拉完清单后明确报出文件名。
    public func start(offlineFolder: URL? = nil) {
        guard task == nil else { return }
        phase = .preparing
        acceptsProgress = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(offlineFolder: offlineFolder)
            self.acceptsProgress = false
            self.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// 等当前这轮结束；没有在跑时立即返回。
    public func waitForCompletion() async {
        let task = self.task
        await task?.value
    }

    private func run(offlineFolder: URL?) async {
        do {
            try Task.checkCancellation()
            try paths.createDirectories()

            let plan = try await SdkBootstrap(configuration: configuration, session: session).plan()
            try Task.checkCancellation()

            let installer = SdkInstaller(root: paths.sdkDirectory)
            var offlineArchives: [String: URL] = [:]
            if let offlineFolder {
                var missing: [String] = []
                for item in plan.downloads where !installer.isInstalled(item.packagePath) {
                    let candidate = offlineFolder.appendingPathComponent(item.url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        offlineArchives[item.packagePath] = candidate
                    } else {
                        missing.append(item.url.lastPathComponent)
                    }
                }
                guard missing.isEmpty else {
                    throw OfflineImportError.missingFiles(missing)
                }
            }

            try await installer.install(
                plan,
                downloader: downloader,
                offlineArchives: offlineArchives
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsProgress else { return }
                    self.phase = .installing(progress)
                }
            }

            try Task.checkCancellation()
            phase = .ready
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(SetupErrorText.text(for: error))
        }
    }

    private static func displayName(for packagePath: String) -> String {
        switch packagePath {
        case "platform-tools":
            return "平台工具"
        case "emulator":
            return "模拟器"
        default:
            return packagePath.hasPrefix("system-images") ? "系统镜像" : packagePath
        }
    }
}

enum SetupErrorText {
    static func text(for error: Error) -> String {
        switch error {
        case let error as SdkBootstrapError:
            switch error {
            case let .httpStatus(code):
                return "获取组件清单失败（HTTP \(code)）。请检查网络，或在设置里改用镜像地址。"
            }
        case is SdkRepositoryError:
            return "组件清单格式无法识别。如果用了镜像地址，请确认地址指向 repository2-3.xml。"
        case let error as DownloadError:
            switch error {
            case let .httpStatus(code):
                return "下载失败（HTTP \(code)）。请重试，已下载的部分会接着下。"
            case .sizeMismatch:
                return "下载的大小与清单不一致，已停止。请重试。"
            case .checksumMismatch:
                return "下载的文件校验不一致，已丢弃。请重试。"
            }
        case let error as SdkInstallPlanError:
            switch error {
            case let .missingPackage(path):
                return "清单里找不到 \(path)，镜像可能不完整。"
            case let .missingArchive(path):
                return "清单里没有适合这台 Mac 的 \(path)。"
            case .invalidArchiveURL:
                return "清单里的下载地址无效，镜像可能配置有误。"
            }
        case let error as SdkInstallError:
            switch error {
            case let .emptyArchive(package):
                return "\(package) 的压缩包是空的，可能下载到了错误页面。请重试。"
            }
        case let error as OfflineImportError:
            switch error {
            case let .missingFiles(names):
                return "离线包里缺少：\(names.joined(separator: "、"))。请把清单对应的压缩包放进同一个文件夹。"
            }
        case let error as URLError:
            return "网络请求失败：\(error.localizedDescription)。请检查网络后重试。"
        default:
            return "安装失败：\(error.localizedDescription)"
        }
    }
}
