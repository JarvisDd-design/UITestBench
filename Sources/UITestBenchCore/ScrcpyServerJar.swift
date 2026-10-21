import Foundation

/// 随包的 scrcpy 服务端。jar 与客户端实现必须成对发布，
/// 所以启动前校验字节数与 SHA-256，绝不接受「差不多」的版本。
public enum ScrcpyServerJar {
    public static let fileName = "scrcpy-server.jar"
    public static let expectedByteCount = 733_930
    public static let expectedSHA256 = "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"

    public enum ValidationError: Error, Equatable {
        case unreadable
        case wrongSize(expected: Int, actual: Int)
        case wrongChecksum(expected: String, actual: String)
    }

    /// 按顺序在候选目录里找 jar：SwiftPM 资源包与 Xcode 应用包的位置不同，
    /// 由调用方把两边的资源目录都塞进来，这里只负责「第一个存在的」。
    public static func locate(in directories: [URL]) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func validate(
        _ url: URL,
        expectedSHA256: String = ScrcpyServerJar.expectedSHA256,
        expectedByteCount: Int = ScrcpyServerJar.expectedByteCount
    ) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ValidationError.unreadable
        }

        let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actualSize == expectedByteCount else {
            throw ValidationError.wrongSize(expected: expectedByteCount, actual: actualSize)
        }

        let actualHash: String
        do {
            actualHash = try Checksum.sha256Hex(ofFileAt: url)
        } catch {
            throw ValidationError.unreadable
        }

        guard actualHash.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ValidationError.wrongChecksum(expected: expectedSHA256, actual: actualHash)
        }
    }
}
