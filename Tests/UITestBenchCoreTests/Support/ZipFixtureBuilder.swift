import Compression
import Foundation

/// 在测试里手工拼出一个合法的 ZIP 归档，避免依赖任何外部样本文件。
struct ZipFixtureBuilder {
    private struct Record {
        let path: String
        /// 中央目录里原样的文件名字节。用来模拟非 UTF-8（如 GBK）的条目名。
        let rawPath: Data?
        let contents: Data
        var compressed: Data = Data()
        var method: UInt16 = 0
        var unixPermissions: UInt16?
        var crc: UInt32 = 0
        var localHeaderOffset: UInt32 = 0

        var nameBytes: Data { rawPath ?? Data(path.utf8) }
    }

    private var records: [Record] = []

    func addingStoredEntry(path: String, contents: Data, unixPermissions: UInt16? = nil) -> ZipFixtureBuilder {
        var copy = self
        copy.records.append(Record(
            path: path,
            rawPath: nil,
            contents: contents,
            compressed: contents,
            method: 0,
            unixPermissions: unixPermissions
        ))
        return copy
    }

    func addingStoredEntry(rawPath: Data, contents: Data) -> ZipFixtureBuilder {
        var copy = self
        copy.records.append(Record(
            path: "",
            rawPath: rawPath,
            contents: contents,
            compressed: contents,
            method: 0
        ))
        return copy
    }

    func addingDeflatedEntry(path: String, contents: Data, unixPermissions: UInt16? = nil) -> ZipFixtureBuilder {
        var copy = self
        copy.records.append(Record(
            path: path,
            rawPath: nil,
            contents: contents,
            compressed: Self.deflate(contents),
            method: 8,
            unixPermissions: unixPermissions
        ))
        return copy
    }

    func build() -> Data {
        var output = Data()
        var built: [Record] = []

        for index in records.indices {
            var record = records[index]
            record.crc = CRC32.checksum(record.contents)
            record.localHeaderOffset = UInt32(output.count)
            let nameBytes = record.nameBytes
            let size = UInt32(record.compressed.count)

            output.appendLE(UInt32(0x0403_4b50))   // local file header signature
            output.appendLE(UInt16(20))            // version needed
            output.appendLE(UInt16(0))             // flags
            output.appendLE(record.method)
            output.appendLE(UInt16(0))             // mod time
            output.appendLE(UInt16(0))             // mod date
            output.appendLE(record.crc)
            output.appendLE(size)                  // compressed size
            output.appendLE(UInt32(record.contents.count))
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))             // extra field length
            output.append(nameBytes)
            output.append(record.compressed)

            built.append(record)
        }

        let centralStart = UInt32(output.count)
        for record in built {
            let nameBytes = record.nameBytes
            let size = UInt32(record.compressed.count)
            let madeBy: UInt16 = record.unixPermissions == nil ? 20 : 0x0314  // 高字节 3 = Unix
            let externalAttributes = UInt32(record.unixPermissions ?? 0) << 16

            output.appendLE(UInt32(0x0201_4b50))   // central directory header signature
            output.appendLE(madeBy)                // version made by
            output.appendLE(UInt16(20))            // version needed
            output.appendLE(UInt16(0))             // flags
            output.appendLE(record.method)
            output.appendLE(UInt16(0))             // mod time
            output.appendLE(UInt16(0))             // mod date
            output.appendLE(record.crc)
            output.appendLE(size)
            output.appendLE(UInt32(record.contents.count))
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))             // extra length
            output.appendLE(UInt16(0))             // comment length
            output.appendLE(UInt16(0))             // disk number
            output.appendLE(UInt16(0))             // internal attributes
            output.appendLE(externalAttributes)
            output.appendLE(record.localHeaderOffset)
            output.append(nameBytes)
        }
        let centralSize = UInt32(output.count) - centralStart

        output.appendLE(UInt32(0x0605_4b50))       // end of central directory
        output.appendLE(UInt16(0))                 // this disk
        output.appendLE(UInt16(0))                 // disk with central directory
        output.appendLE(UInt16(built.count))
        output.appendLE(UInt16(built.count))
        output.appendLE(centralSize)
        output.appendLE(centralStart)
        output.appendLE(UInt16(0))                 // comment length

        return output
    }

    /// 与 `ZipReader` 解压时用的格式一致：COMPRESSION_ZLIB 就是裸 DEFLATE。
    private static func deflate(_ data: Data) -> Data {
        let capacity = data.count + data.count / 8 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0, "测试数据的压缩结果不应为空")
        return output.prefix(written)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
