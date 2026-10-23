import Compression
import Foundation

/// 读取 ZIP 归档。只做本项目需要的部分：中央目录、条目解压。
public struct ZipReader {
    public struct Entry: Equatable {
        public let path: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public enum ZipError: Error, Equatable {
        case notAZipArchive
        case truncated
        case corruptedCentralDirectory
        case corruptedLocalHeader
        case invalidEntryName
        case entryNotFound(String)
        case unsupportedCompressionMethod(UInt16)
        case decompressionFailed
    }

    public let entries: [Entry]

    private let data: Data

    public init(data: Data) throws {
        self.data = data

        let endOfCentralDirectory = try Self.findEndOfCentralDirectory(in: data)
        let entryCount = Int(try Self.readUInt16(data, at: endOfCentralDirectory + 10))
        let centralDirectoryOffset = Int(try Self.readUInt32(data, at: endOfCentralDirectory + 16))

        var parsed: [Entry] = []
        parsed.reserveCapacity(entryCount)
        var cursor = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard try Self.readUInt32(data, at: cursor) == 0x0201_4b50 else {
                throw ZipError.corruptedCentralDirectory
            }

            let nameLength = Int(try Self.readUInt16(data, at: cursor + 28))
            let extraLength = Int(try Self.readUInt16(data, at: cursor + 30))
            let commentLength = Int(try Self.readUInt16(data, at: cursor + 32))

            let nameStart = cursor + 46
            let nameBytes = try Self.slice(data, from: nameStart, length: nameLength)
            // 有些 APK 的资源文件名是 GBK，且没有置 UTF-8 标志位。
            // 一个条目名读不出来不该让整包被当成「不是 ZIP」；真正的
            // AndroidManifest.xml 路径永远是 ASCII，按字节能对上。
            let path = String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .isoLatin1)
                ?? ""

            parsed.append(
                Entry(
                    path: path,
                    compressionMethod: try Self.readUInt16(data, at: cursor + 10),
                    crc32: try Self.readUInt32(data, at: cursor + 16),
                    compressedSize: Int(try Self.readUInt32(data, at: cursor + 20)),
                    uncompressedSize: Int(try Self.readUInt32(data, at: cursor + 24)),
                    localHeaderOffset: Int(try Self.readUInt32(data, at: cursor + 42))
                )
            )

            cursor += 46 + nameLength + extraLength + commentLength
        }

        self.entries = parsed
    }

    /// 取出指定条目的原始内容（自动处理 stored 与 deflate 两种压缩方式）。
    public func contents(ofEntryAtPath path: String) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ZipError.entryNotFound(path)
        }

        let localHeader = entry.localHeaderOffset
        guard try Self.readUInt32(data, at: localHeader) == 0x0403_4b50 else {
            throw ZipError.corruptedLocalHeader
        }

        let nameLength = Int(try Self.readUInt16(data, at: localHeader + 26))
        let extraLength = Int(try Self.readUInt16(data, at: localHeader + 28))
        let dataStart = localHeader + 30 + nameLength + extraLength
        let compressed = try Self.slice(data, from: dataStart, length: entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, uncompressedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    /// 用系统 Compression 框架解 raw deflate（ZIP 的 method 8）。
    private static func inflate(_ input: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }

        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, uncompressedSize,
                    sourceBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written == uncompressedSize else { throw ZipError.decompressionFailed }
        return output
    }

    /// 从文件末尾向前找「中央目录结束记录」(EOCD)。
    /// 末尾可能有最长 65535 字节的注释，所以要在这个范围内回溯。
    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let recordSize = 22
        guard data.count >= recordSize else { throw ZipError.notAZipArchive }

        let lowestCandidate = max(0, data.count - recordSize - 0xFFFF)
        var candidate = data.count - recordSize

        while candidate >= lowestCandidate {
            if (try? readUInt32(data, at: candidate)) == 0x0605_4b50 {
                return candidate
            }
            candidate -= 1
        }

        throw ZipError.notAZipArchive
    }

    private static func slice(_ data: Data, from offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ZipError.truncated
        }
        let start = data.startIndex + offset
        return data[start..<(start + length)]
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        let bytes = try slice(data, from: offset, length: 2)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        let bytes = try slice(data, from: offset, length: 4)
        let base = bytes.startIndex
        return UInt32(bytes[base])
            | (UInt32(bytes[base + 1]) << 8)
            | (UInt32(bytes[base + 2]) << 16)
            | (UInt32(bytes[base + 3]) << 24)
    }
}
