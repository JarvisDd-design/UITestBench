import Foundation

/// 在测试里手工拼出一个合法的 ZIP 归档，避免依赖任何外部样本文件。
struct ZipFixtureBuilder {
    private struct Record {
        let path: String
        let contents: Data
        var crc: UInt32 = 0
        var localHeaderOffset: UInt32 = 0
    }

    private var records: [Record] = []

    func addingStoredEntry(path: String, contents: Data) -> ZipFixtureBuilder {
        var copy = self
        copy.records.append(Record(path: path, contents: contents))
        return copy
    }

    func build() -> Data {
        var output = Data()
        var built: [Record] = []

        for index in records.indices {
            var record = records[index]
            record.crc = CRC32.checksum(record.contents)
            record.localHeaderOffset = UInt32(output.count)
            let nameBytes = Data(record.path.utf8)
            let size = UInt32(record.contents.count)

            output.appendLE(UInt32(0x0403_4b50))   // local file header signature
            output.appendLE(UInt16(20))            // version needed
            output.appendLE(UInt16(0))             // flags
            output.appendLE(UInt16(0))             // method: stored
            output.appendLE(UInt16(0))             // mod time
            output.appendLE(UInt16(0))             // mod date
            output.appendLE(record.crc)
            output.appendLE(size)                  // compressed size
            output.appendLE(size)                  // uncompressed size
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))             // extra field length
            output.append(nameBytes)
            output.append(record.contents)

            built.append(record)
        }

        let centralStart = UInt32(output.count)
        for record in built {
            let nameBytes = Data(record.path.utf8)
            let size = UInt32(record.contents.count)

            output.appendLE(UInt32(0x0201_4b50))   // central directory header signature
            output.appendLE(UInt16(20))            // version made by
            output.appendLE(UInt16(20))            // version needed
            output.appendLE(UInt16(0))             // flags
            output.appendLE(UInt16(0))             // method: stored
            output.appendLE(UInt16(0))             // mod time
            output.appendLE(UInt16(0))             // mod date
            output.appendLE(record.crc)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))             // extra length
            output.appendLE(UInt16(0))             // comment length
            output.appendLE(UInt16(0))             // disk number
            output.appendLE(UInt16(0))             // internal attributes
            output.appendLE(UInt32(0))             // external attributes
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
