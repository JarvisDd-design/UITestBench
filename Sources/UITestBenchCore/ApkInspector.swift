import Foundation

/// 一次扫包得到的全部信息。界面直接用它渲染包信息区。
public struct ApkInfo: Equatable {
    public let packageName: String?
    public let versionCode: Int?
    public let versionName: String?
    public let minSdkVersion: Int?
    public let targetSdkVersion: Int?
    public let applicationLabel: String?
    public let launcherActivityName: String?
    /// 按字母序，去重。空数组表示纯 Java/Kotlin 包，任何架构都能装。
    public let abis: [String]
    public let isSplitApk: Bool
    public let byteCount: Int

    public init(
        packageName: String?,
        versionCode: Int?,
        versionName: String?,
        minSdkVersion: Int?,
        targetSdkVersion: Int?,
        applicationLabel: String?,
        launcherActivityName: String?,
        abis: [String],
        isSplitApk: Bool,
        byteCount: Int
    ) {
        self.packageName = packageName
        self.versionCode = versionCode
        self.versionName = versionName
        self.minSdkVersion = minSdkVersion
        self.targetSdkVersion = targetSdkVersion
        self.applicationLabel = applicationLabel
        self.launcherActivityName = launcherActivityName
        self.abis = abis
        self.isSplitApk = isSplitApk
        self.byteCount = byteCount
    }
}

public enum ApkInspectionError: Error, Equatable {
    /// 内容根本不是 ZIP（常见于链接返回了网页或普通文件）。
    case notAZipArchive
    /// 以 `PK` 开头，但 ZIP 结构读不出来：下载不完整、ZIP64 或条目损坏。
    case damagedArchive
    /// 包根目录下没有 AndroidManifest.xml。
    case manifestMissing
    /// AndroidManifest.xml 存在，但不是可解析的二进制 XML。
    case manifestUnreadable
}

public enum ApkInspector {
    public static let manifestPath = "AndroidManifest.xml"

    public static func inspect(_ data: Data) throws -> ApkInfo {
        let zip: ZipReader
        do {
            zip = try ZipReader(data: data)
        } catch {
            throw Self.startsWithZIPSignature(data)
                ? ApkInspectionError.damagedArchive
                : ApkInspectionError.notAZipArchive
        }

        guard zip.entries.contains(where: { $0.path == manifestPath }) else {
            throw ApkInspectionError.manifestMissing
        }

        let root: AXmlElement
        do {
            root = try AXmlParser.parse(try zip.contents(ofEntryAtPath: manifestPath)).root
        } catch {
            throw ApkInspectionError.manifestUnreadable
        }

        let manifest = try AndroidManifestParser.parse(rootXML: root)

        return ApkInfo(
            packageName: manifest.packageName,
            versionCode: manifest.versionCode,
            versionName: manifest.versionName,
            minSdkVersion: manifest.minSdkVersion,
            targetSdkVersion: manifest.targetSdkVersion,
            applicationLabel: manifest.applicationLabel,
            launcherActivityName: manifest.launcherActivityName,
            abis: abis(in: zip),
            // 拆分包在根元素上带 split 属性；基础包没有这个属性。
            isSplitApk: root.attribute(named: "split") != nil,
            byteCount: data.count
        )
    }

    private static func startsWithZIPSignature(_ data: Data) -> Bool {
        let bytes = data.prefix(2)
        return bytes.count == 2 && bytes[bytes.startIndex] == 0x50
            && bytes[bytes.index(after: bytes.startIndex)] == 0x4B
    }

    private static func abis(in zip: ZipReader) -> [String] {
        Set(
            zip.entries
                .map(\.path)
                .filter { $0.hasPrefix("lib/") }
                .compactMap { $0.split(separator: "/").dropFirst().first.map(String.init) }
        ).sorted()
    }
}
