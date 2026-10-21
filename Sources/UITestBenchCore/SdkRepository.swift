import Foundation

public struct SdkRevision: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let micro: Int

    public init(major: Int, minor: Int = 0, micro: Int = 0) {
        self.major = major
        self.minor = minor
        self.micro = micro
    }

    public var description: String { "\(major).\(minor).\(micro)" }

    public static func < (lhs: SdkRevision, rhs: SdkRevision) -> Bool {
        (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro)
    }
}

public struct SdkArchive: Equatable, Sendable {
    public let url: String
    public let size: Int64
    public let sha1: String
    /// nil 表示与平台无关，例如系统镜像。
    public let hostOS: String?
    /// x64 / aarch64；nil 表示与架构无关。注意这是主机架构，不是 ABI。
    public let hostArch: String?

    public init(url: String, size: Int64, sha1: String, hostOS: String?, hostArch: String? = nil) {
        self.url = url
        self.size = size
        self.sha1 = sha1
        self.hostOS = hostOS
        self.hostArch = hostArch
    }
}

public struct SdkPackage: Equatable, Sendable {
    public let path: String
    public let revision: SdkRevision
    public let displayName: String?
    public let licenseID: String?
    public let archives: [SdkArchive]
    /// 依赖的包路径 → 最低版本。
    public let dependencyMinimumRevisions: [String: SdkRevision]

    public init(
        path: String,
        revision: SdkRevision,
        displayName: String?,
        licenseID: String?,
        archives: [SdkArchive],
        dependencyMinimumRevisions: [String: SdkRevision]
    ) {
        self.path = path
        self.revision = revision
        self.displayName = displayName
        self.licenseID = licenseID
        self.archives = archives
        self.dependencyMinimumRevisions = dependencyMinimumRevisions
    }

    /// 优先取该平台、该架构的包；没有 host-os / host-arch 的视为通用包。
    ///
    /// emulator 同时提供 x64 与 aarch64 两个 macosx 包，所以架构必须参与选择。
    public func archive(forHostOS hostOS: String, hostArch: String? = nil) -> SdkArchive? {
        let matchingOS = archives.filter { $0.hostOS == hostOS || $0.hostOS == nil }
        guard let hostArch else {
            return matchingOS.first { $0.hostArch == nil } ?? matchingOS.first
        }
        return matchingOS.first { $0.hostArch == hostArch }
            ?? matchingOS.first { $0.hostArch == nil }
    }
}

public enum SdkRepositoryError: Error, Equatable {
    case malformedXML
}

public struct SdkRepository: Equatable, Sendable {
    public let packages: [SdkPackage]

    public init(packages: [SdkPackage]) {
        self.packages = packages
    }

    public func package(atPath path: String) -> SdkPackage? {
        packages.first { $0.path == path }
    }

    public static func parse(_ data: Data) throws -> SdkRepository {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw SdkRepositoryError.malformedXML }
        return SdkRepository(packages: delegate.packages)
    }
}

// MARK: - SAX 解析

private final class Delegate: NSObject, XMLParserDelegate {
    private(set) var packages: [SdkPackage] = []

    private var packageBuilder: PackageBuilder?
    private var archiveBuilder: ArchiveBuilder?
    private var revision = RevisionAccumulator()
    private var revisionTarget: RevisionTarget = .package
    private var dependencyMinimums: [String: SdkRevision] = [:]
    private var dependencyPath: String?
    private var dependencyRevision: SdkRevision?

    private var text = ""
    private var capturing = false

    private enum RevisionTarget { case package, dependency }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        text = ""
        capturing = false

        switch elementName {
        case "remotePackage":
            packageBuilder = PackageBuilder(path: attributes["path"] ?? "")
            dependencyMinimums = [:]

        case "revision":
            revision = RevisionAccumulator()
            revisionTarget = dependencyPath == nil ? .package : .dependency

        case "min-revision":
            revision = RevisionAccumulator()
            revisionTarget = .dependency

        case "dependency":
            dependencyPath = attributes["path"]
            dependencyRevision = nil

        case "uses-license":
            packageBuilder?.licenseID = attributes["ref"]

        case "display-name", "size", "url", "host-os", "host-arch",
             "major", "minor", "micro":
            capturing = true

        case "checksum":
            capturing = attributes["type"] == "sha1"

        case "archive":
            archiveBuilder = ArchiveBuilder()

        case "complete":
            archiveBuilder?.isComplete = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "display-name":
            packageBuilder?.displayName = text
        case "size":
            archiveBuilder?.size = Int64(text)
        case "url":
            archiveBuilder?.url = text
        case "host-os":
            archiveBuilder?.hostOS = text
        case "host-arch":
            archiveBuilder?.hostArch = text
        case "checksum":
            archiveBuilder?.sha1 = text
        case "major":
            setRevision(\.major, from: text)
        case "minor":
            setRevision(\.minor, from: text)
        case "micro":
            setRevision(\.micro, from: text)

        case "revision":
            if revisionTarget == .dependency {
                dependencyRevision = revision.value
            } else {
                packageBuilder?.revision = revision.value
            }

        case "min-revision":
            dependencyRevision = revision.value

        case "dependency":
            if let path = dependencyPath, let minimum = dependencyRevision {
                dependencyMinimums[path] = minimum
            }
            dependencyPath = nil
            dependencyRevision = nil

        case "archive":
            if let archive = archiveBuilder?.build() {
                packageBuilder?.archives.append(archive)
            }
            archiveBuilder = nil

        case "remotePackage":
            if let package = packageBuilder?.build(dependencies: dependencyMinimums) {
                packages.append(package)
            }
            packageBuilder = nil

        default:
            break
        }

        text = ""
        capturing = false
    }

    private func setRevision(_ keyPath: WritableKeyPath<RevisionAccumulator, Int?>, from text: String) {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        revision[keyPath: keyPath] = value
    }
}

private struct RevisionAccumulator {
    var major: Int?
    var minor: Int?
    var micro: Int?

    var value: SdkRevision {
        SdkRevision(major: major ?? 0, minor: minor ?? 0, micro: micro ?? 0)
    }
}

private struct PackageBuilder {
    let path: String
    var revision = SdkRevision(major: 0)
    var displayName: String?
    var licenseID: String?
    var archives: [SdkArchive] = []

    func build(dependencies: [String: SdkRevision]) -> SdkPackage? {
        guard !path.isEmpty else { return nil }
        return SdkPackage(
            path: path,
            revision: revision,
            displayName: displayName,
            licenseID: licenseID,
            archives: archives,
            dependencyMinimumRevisions: dependencies
        )
    }
}

private struct ArchiveBuilder {
    var url: String?
    var size: Int64?
    var sha1: String?
    var hostOS: String?
    var hostArch: String?
    /// 只有 <complete> 里的信息才算数，<partial> 是增量包。
    var isComplete = false

    func build() -> SdkArchive? {
        guard isComplete,
              let url, !url.isEmpty,
              let sha1, !sha1.isEmpty
        else { return nil }
        return SdkArchive(url: url, size: size ?? 0, sha1: sha1, hostOS: hostOS, hostArch: hostArch)
    }
}
