import Foundation

public enum SdkInstallPhase: Equatable, Sendable {
    case downloading(DownloadProgress)
    case extracting
    case installed
    case skipped
}

public struct SdkInstallProgress: Equatable, Sendable {
    public let packagePath: String
    /// 1 起始。
    public let packageIndex: Int
    public let packageCount: Int
    public let phase: SdkInstallPhase
    public let overallFraction: Double?

    public init(
        packagePath: String,
        packageIndex: Int,
        packageCount: Int,
        phase: SdkInstallPhase,
        overallFraction: Double?
    ) {
        self.packagePath = packagePath
        self.packageIndex = packageIndex
        self.packageCount = packageCount
        self.phase = phase
        self.overallFraction = overallFraction
    }
}

public enum SdkInstallError: Error, Equatable {
    /// 解压后一个顶层条目都没有，多半是下载到了错误页面。
    case emptyArchive(String)
}

/// 把 `SdkInstallPlan` 落成可用的 SDK 目录：
///
///     <root>/platform-tools/
///     <root>/emulator/
///     <root>/system-images/…
///
/// 每个包先解压到 `<root>/.staging/<uuid>`，整目录换入，最后写
/// `<root>/.installed/<包名>.json` 作为已完成标记。任何一步失败都不会留下标记，
/// 下次运行会重来；`.part` 文件保留以便续传。
public struct SdkInstaller: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// - Parameter offlineArchives: 包路径 → 本地归档。命中时跳过下载，只做校验与解压；
    ///   文件归用户所有，安装完不删除。
    public func install(
        _ plan: SdkInstallPlan,
        downloader: FileDownloader = FileDownloader(),
        offlineArchives: [String: URL] = [:],
        progress: (@Sendable (SdkInstallProgress) -> Void)? = nil
    ) async throws {
        let fileManager = FileManager.default
        let downloadsDirectory = root.appendingPathComponent(".downloads", isDirectory: true)
        let installedDirectory = root.appendingPathComponent(".installed", isDirectory: true)
        let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
        let backupRoot = root.appendingPathComponent(".backup", isDirectory: true)

        for directory in [root, downloadsDirectory, installedDirectory, stagingRoot, backupRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            try? fileManager.removeItem(at: backupRoot)
        }

        var completedBytes: Int64 = 0
        let totalBytes = plan.totalBytes

        @Sendable func fraction(_ bytes: Int64) -> Double? {
            guard totalBytes > 0 else { return nil }
            return min(1, Double(bytes) / Double(totalBytes))
        }

        for (index, item) in plan.downloads.enumerated() {
            try Task.checkCancellation()
            let packageIndex = index + 1
            let count = plan.downloads.count
            let markerURL = installedDirectory.appendingPathComponent(Self.markerName(for: item.packagePath) + ".json")

            if isInstalled(item, markerURL: markerURL) {
                completedBytes += item.size
                progress?(SdkInstallProgress(
                    packagePath: item.packagePath,
                    packageIndex: packageIndex,
                    packageCount: count,
                    phase: .skipped,
                    overallFraction: fraction(completedBytes)
                ))
                continue
            }

            let archiveURL: URL
            let shouldDeleteArchive: Bool

            if let offline = offlineArchives[item.packagePath] {
                let actual = try Checksum.sha1Hex(ofFileAt: offline)
                guard actual.caseInsensitiveCompare(item.sha1) == .orderedSame else {
                    throw DownloadError.checksumMismatch(expected: item.sha1, actual: actual)
                }
                archiveURL = offline
                shouldDeleteArchive = false
            } else {
                let packageDownloads = downloadsDirectory
                    .appendingPathComponent(Self.markerName(for: item.packagePath), isDirectory: true)
                try fileManager.createDirectory(at: packageDownloads, withIntermediateDirectories: true)
                archiveURL = packageDownloads.appendingPathComponent(item.url.lastPathComponent)
                shouldDeleteArchive = true

                let completedBeforePackage = completedBytes
                try await downloader.download(url: item.url, to: archiveURL, expectedSHA1: item.sha1) { update in
                    progress?(SdkInstallProgress(
                        packagePath: item.packagePath,
                        packageIndex: packageIndex,
                        packageCount: count,
                        phase: .downloading(update),
                        overallFraction: fraction(completedBeforePackage + update.receivedBytes)
                    ))
                }
            }

            try Task.checkCancellation()
            progress?(SdkInstallProgress(
                packagePath: item.packagePath,
                packageIndex: packageIndex,
                packageCount: count,
                phase: .extracting,
                overallFraction: fraction(completedBytes + item.size)
            ))

            let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                try Self.extract(archiveURL, into: staging, package: item.packagePath, root: root, backupRoot: backupRoot)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            try? fileManager.removeItem(at: staging)

            let record = InstalledRecord(packagePath: item.packagePath, sha1: item.sha1)
            try JSONEncoder().encode(record).write(to: markerURL, options: .atomic)
            if shouldDeleteArchive {
                try? fileManager.removeItem(at: archiveURL)
            }

            completedBytes += item.size
            progress?(SdkInstallProgress(
                packagePath: item.packagePath,
                packageIndex: packageIndex,
                packageCount: count,
                phase: .installed,
                overallFraction: fraction(completedBytes)
            ))
        }
    }

    // MARK: 安装状态

    public func isInstalled(_ packagePath: String) -> Bool {
        let topLevel = packagePath.split(separator: ";").first.map(String.init) ?? packagePath
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(topLevel).path)
    }

    /// 归档内的顶层目录整目录换入；旧目录先挪到备份区，换入失败时还原。
    private static func extract(
        _ archiveURL: URL,
        into staging: URL,
        package: String,
        root: URL,
        backupRoot: URL
    ) throws {
        let fileManager = FileManager.default
        let archive = try ZipArchive(url: archiveURL)
        try archive.extractAll(to: staging)

        let entries = try fileManager.contentsOfDirectory(atPath: staging.path)
            .filter { $0 != ".DS_Store" }
        guard !entries.isEmpty else {
            throw SdkInstallError.emptyArchive(package)
        }

        // 包的安装位置由包路径决定，不能按归档里的顶层目录名摊到根上：
        // 系统镜像归档的顶层就叫 arm64-v8a，必须落到 system-images/android-34/…
        let destination = root.appendingPathComponent(Self.destinationPath(for: package), isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // 归档自带与目标同名的顶层目录时，搬它里面的东西；否则直接搬顶层条目。
        var source = staging
        if entries.count == 1, entries[0] == destination.lastPathComponent {
            source = staging.appendingPathComponent(entries[0])
        }
        let contents = try fileManager.contentsOfDirectory(atPath: source.path)
            .filter { $0 != ".DS_Store" }

        // 整目录替换：旧目录先挪走，换入失败再还原，避免旧文件残留。
        var backup: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let candidate = backupRoot.appendingPathComponent(UUID().uuidString)
            try fileManager.moveItem(at: destination, to: candidate)
            backup = candidate
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in contents {
                try fileManager.moveItem(
                    at: source.appendingPathComponent(name),
                    to: destination.appendingPathComponent(name)
                )
            }
            if let backup {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            if let backup {
                try? fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    /// `system-images;android-34;default;arm64-v8a` → `system-images/android-34/default/arm64-v8a`
    static func destinationPath(for package: String) -> String {
        package.split(separator: ";").joined(separator: "/")
    }

    private func isInstalled(_ item: SdkDownload, markerURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let record = try? JSONDecoder().decode(InstalledRecord.self, from: data),
              record.packagePath == item.packagePath,
              record.sha1.caseInsensitiveCompare(item.sha1) == .orderedSame
        else { return false }

        let topLevel = item.packagePath.split(separator: ";").first.map(String.init) ?? item.packagePath
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(topLevel).path)
    }

    static func markerName(for packagePath: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return packagePath.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }
}

private struct InstalledRecord: Codable, Equatable {
    let packagePath: String
    let sha1: String
}
