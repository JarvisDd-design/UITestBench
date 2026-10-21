import Compression
import Foundation

public struct ZipFileEntry: Equatable, Sendable {
    public let path: String
    public let compressionMethod: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
    /// 来自中央目录的 Unix 权限位；非 Unix 平台打的包为 nil。
    public let unixPermissions: UInt16?

    public init(
        path: String,
        compressionMethod: UInt16,
        crc32: UInt32,
        compressedSize: Int,
        uncompressedSize: Int,
        localHeaderOffset: Int,
        unixPermissions: UInt16?
    ) {
        self.path = path
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.localHeaderOffset = localHeaderOffset
        self.unixPermissions = unixPermissions
    }
}

public enum ZipArchiveError: Error, Equatable {
    case notAZipArchive
    case truncated
    case corruptedCentralDirectory
    case unsupportedCompressionMethod(UInt16)
    case unsafeEntryPath(String)
    case decompressionFailed
    case checksumMismatch(String)
}

/// 磁盘上的 ZIP。只读 EOCD 尾部与中央目录，条目内容边读边解压，
/// 因此 700 MB 的系统镜像也不会被整包读进内存。
public final class ZipArchive {
    public let entries: [ZipFileEntry]

    private let url: URL
    private let fileSize: Int
    private static let bufferSize = 64 * 1024

    public init(url: URL) throws {
        self.url = url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
            throw ZipArchiveError.notAZipArchive
        }
        self.fileSize = size
        self.entries = try Self.readCentralDirectory(url: url, fileSize: size)
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(url: URL, fileSize: Int) throws -> [ZipFileEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let tailLength = min(fileSize, 22 + 0xFFFF)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        guard let tail = try handle.read(upToCount: tailLength) else {
            throw ZipArchiveError.truncated
        }

        guard let eocdOffset = findEndOfCentralDirectory(in: tail) else {
            throw ZipArchiveError.notAZipArchive
        }
        guard eocdOffset + 22 <= tail.count else { throw ZipArchiveError.truncated }

        let entryCount = Int(try readUInt16(tail, at: eocdOffset + 10))
        let directorySize = Int(try readUInt32(tail, at: eocdOffset + 12))
        let directoryOffset = Int(try readUInt32(tail, at: eocdOffset + 16))

        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset
        else { throw ZipArchiveError.corruptedCentralDirectory }

        // 合法的空归档只有 EOCD，没有中央目录。
        if entryCount == 0, directorySize == 0 {
            return []
        }

        try handle.seek(toOffset: UInt64(directoryOffset))
        guard let directory = try handle.read(upToCount: directorySize),
              directory.count == directorySize
        else { throw ZipArchiveError.truncated }

        var entries: [ZipFileEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0

        while cursor + 46 <= directory.count {
            guard try readUInt32(directory, at: cursor) == 0x0201_4b50 else {
                throw ZipArchiveError.corruptedCentralDirectory
            }

            let madeBy = try readUInt16(directory, at: cursor + 4)
            let method = try readUInt16(directory, at: cursor + 10)
            let crc = try readUInt32(directory, at: cursor + 16)
            let compressedSize = Int(try readUInt32(directory, at: cursor + 20))
            let uncompressedSize = Int(try readUInt32(directory, at: cursor + 24))
            let nameLength = Int(try readUInt16(directory, at: cursor + 28))
            let extraLength = Int(try readUInt16(directory, at: cursor + 30))
            let commentLength = Int(try readUInt16(directory, at: cursor + 32))
            let externalAttributes = try readUInt32(directory, at: cursor + 38)
            let localHeaderOffset = Int(try readUInt32(directory, at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= directory.count else {
                throw ZipArchiveError.corruptedCentralDirectory
            }
            let nameBytes = directory[nameStart..<(nameStart + nameLength)]
            let path = String(decoding: nameBytes, as: UTF8.self)

            // version made by 的高字节是制作平台，3 表示 Unix。
            let unixPermissions = (madeBy >> 8) == 3
                ? UInt16(truncatingIfNeeded: externalAttributes >> 16)
                : nil

            entries.append(
                ZipFileEntry(
                    path: path,
                    compressionMethod: method,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    unixPermissions: unixPermissions
                )
            )

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var offset = tail.count - 22
        while offset >= 0 {
            if (try? readUInt32(tail, at: offset)) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - 解压

    public func extractAll(to directory: URL) throws {
        let base = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for entry in entries {
            let destination = base.appendingPathComponent(entry.path)
            let standardized = destination.standardizedFileURL
            guard !entry.path.hasPrefix("/"),
                  standardized.path == base.path || standardized.path.hasPrefix(base.path + "/")
            else { throw ZipArchiveError.unsafeEntryPath(entry.path) }

            if entry.path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
                continue
            }
            try extract(entry, to: standardized)
        }
    }

    public func extract(_ entry: ZipFileEntry, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard entry.localHeaderOffset >= 0, entry.localHeaderOffset + 30 <= fileSize else {
            throw ZipArchiveError.truncated
        }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let localHeader = try handle.read(upToCount: 30), localHeader.count == 30,
              try Self.readUInt32(localHeader, at: 0) == 0x0403_4b50
        else { throw ZipArchiveError.truncated }

        let nameLength = Int(try Self.readUInt16(localHeader, at: 26))
        let extraLength = Int(try Self.readUInt16(localHeader, at: 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart <= fileSize, entry.compressedSize <= fileSize - dataStart else {
            throw ZipArchiveError.truncated
        }
        try handle.seek(toOffset: UInt64(dataStart))

        manager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var digest = CRC32Digest()
        switch entry.compressionMethod {
        case 0:
            try copyStored(from: handle, size: entry.compressedSize, to: output, digest: &digest)
        case 8:
            try inflate(from: handle, size: entry.compressedSize, to: output, digest: &digest)
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }

        guard digest.value == entry.crc32 else {
            throw ZipArchiveError.checksumMismatch(entry.path)
        }

        if let mode = entry.unixPermissions, mode != 0 {
            try manager.setAttributes(
                [.posixPermissions: NSNumber(value: mode & 0o777)],
                ofItemAtPath: destination.path
            )
        }
    }

    private func copyStored(
        from handle: FileHandle,
        size: Int,
        to output: FileHandle,
        digest: inout CRC32Digest
    ) throws {
        var remaining = size
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: min(Self.bufferSize, remaining)),
                  !chunk.isEmpty
            else { throw ZipArchiveError.truncated }
            remaining -= chunk.count
            digest.update(chunk)
            try output.write(contentsOf: chunk)
        }
    }

    private func inflate(
        from handle: FileHandle,
        size: Int,
        to output: FileHandle,
        digest: inout CRC32Digest
    ) throws {
        guard size > 0 else { return }

        // 先分配再交给 compression_stream_init 初始化，避免读到未初始化的结构体。
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else {
            streamPointer.deallocate()
            throw ZipArchiveError.decompressionFailed
        }
        defer {
            compression_stream_destroy(streamPointer)
            streamPointer.deallocate()
        }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        defer {
            source.deallocate()
            destination.deallocate()
        }

        var remaining = size
        var finished = false

        while !finished {
            if streamPointer.pointee.src_size == 0, remaining > 0 {
                let wanted = min(Self.bufferSize, remaining)
                guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else {
                    throw ZipArchiveError.truncated
                }
                remaining -= chunk.count
                chunk.copyBytes(to: source, count: chunk.count)
                streamPointer.pointee.src_ptr = UnsafePointer(source)
                streamPointer.pointee.src_size = chunk.count
            }

            streamPointer.pointee.dst_ptr = destination
            streamPointer.pointee.dst_size = Self.bufferSize

            let atEnd = remaining == 0 && streamPointer.pointee.src_size == 0
            let flags = atEnd ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(streamPointer, flags)
            let produced = Self.bufferSize - streamPointer.pointee.dst_size

            if produced > 0 {
                let chunk = Data(bytes: destination, count: produced)
                digest.update(chunk)
                try output.write(contentsOf: chunk)
            }

            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
            case COMPRESSION_STATUS_ERROR:
                throw ZipArchiveError.decompressionFailed
            default:
                if atEnd && produced == 0 {
                    throw ZipArchiveError.decompressionFailed
                }
            }
        }
    }

    // MARK: - 读取

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipArchiveError.truncated }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipArchiveError.truncated }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

private struct CRC32Digest {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private var crc: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var value = crc
        for byte in data {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        crc = value
    }

    var value: UInt32 { crc ^ 0xFFFF_FFFF }
}
