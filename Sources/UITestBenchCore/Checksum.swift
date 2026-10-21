import CryptoKit
import Foundation

public enum Checksum {
    public static func sha1Hex(of data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 流式读文件，不把内容整个载入内存。
    public static func sha1Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ expectedHex: String, data: Data) -> Bool {
        sha1Hex(of: data).caseInsensitiveCompare(expectedHex) == .orderedSame
    }

    public static func matches(_ expectedHex: String, fileAt url: URL) throws -> Bool {
        try sha1Hex(ofFileAt: url).caseInsensitiveCompare(expectedHex) == .orderedSame
    }
}
