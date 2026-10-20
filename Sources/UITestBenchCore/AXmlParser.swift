import Foundation

/// Android 二进制 XML（AXML）解析结果中的一个值。
public enum AXmlValue: Equatable {
    case string(String)
    case integer(Int32)
    case boolean(Bool)
    case reference(UInt32)
    /// 未处理的类型（浮点、尺寸、分数等），保留原始数据，由上层决定是否关心。
    case other(type: UInt8, value: UInt32)
}

public struct AXmlAttribute: Equatable {
    public let namespaceURI: String?
    public let name: String
    public let rawValue: String?
    public let value: AXmlValue
}

public struct AXmlElement: Equatable {
    public let name: String
    public let namespaceURI: String?
    public let attributes: [AXmlAttribute]
    public let children: [AXmlElement]

    public func attribute(named name: String, namespaceURI: String? = nil) -> AXmlAttribute? {
        attributes.first { $0.name == name && $0.namespaceURI == namespaceURI }
    }

    public func child(named name: String) -> AXmlElement? {
        children.first { $0.name == name }
    }
}

public struct AXmlDocument: Equatable {
    public let root: AXmlElement
}

public enum AXmlError: Error, Equatable {
    case notAXmlDocument
    case truncated
    case malformedStringPool
    case malformedElement
    case noRootElement
}

public enum AXmlParser {
    public static func parse(_ data: Data) throws -> AXmlDocument {
        guard data.count >= 8 else { throw AXmlError.truncated }
        guard try readUInt16(data, at: 0) == 0x0003 else { throw AXmlError.notAXmlDocument }

        let headerSize = Int(try readUInt16(data, at: 2))
        let declaredSize = Int(try readUInt32(data, at: 4))
        let totalSize = min(declaredSize, data.count)
        guard headerSize >= 8, totalSize >= headerSize else { throw AXmlError.truncated }

        var pool: StringPool?
        var openElements: [OpenElement] = []
        var root: AXmlElement?

        var offset = headerSize
        while offset + 8 <= totalSize {
            let type = try readUInt16(data, at: offset)
            let chunkHeaderSize = Int(try readUInt16(data, at: offset + 2))
            let chunkSize = Int(try readUInt32(data, at: offset + 4))
            guard chunkSize >= 8, chunkHeaderSize <= chunkSize, offset + chunkSize <= totalSize else {
                throw AXmlError.truncated
            }

            switch type {
            case 0x0001: // 字符串池
                pool = try StringPool(data: data, chunkStart: offset, chunkSize: chunkSize)

            case 0x0100, 0x0180: // 命名空间、资源映射：解析不需要
                break

            case 0x0102: // 开始标签
                guard let pool else { throw AXmlError.malformedStringPool }
                openElements.append(try parseStartElement(data, at: offset, pool: pool))

            case 0x0103: // 结束标签
                guard let completed = openElements.popLast() else { throw AXmlError.malformedElement }
                let element = completed.element
                if let parentIndex = openElements.indices.last {
                    openElements[parentIndex].children.append(element)
                } else if root == nil {
                    root = element
                } else {
                    throw AXmlError.malformedElement
                }

            default:
                break
            }

            offset += chunkSize
        }

        guard openElements.isEmpty, let root else { throw AXmlError.noRootElement }
        return AXmlDocument(root: root)
    }

    // MARK: - 元素

    private struct OpenElement {
        let name: String
        let namespaceURI: String?
        let attributes: [AXmlAttribute]
        var children: [AXmlElement]

        var element: AXmlElement {
            AXmlElement(name: name, namespaceURI: namespaceURI, attributes: attributes, children: children)
        }
    }

    private static func parseStartElement(_ data: Data, at offset: Int, pool: StringPool) throws -> OpenElement {
        let namespaceIndex = try readUInt32(data, at: offset + 16)
        let nameIndex = try readUInt32(data, at: offset + 20)
        let attributeStart = Int(try readUInt16(data, at: offset + 24))
        let attributeSize = Int(try readUInt16(data, at: offset + 26))
        let attributeCount = Int(try readUInt16(data, at: offset + 28))

        guard attributeSize >= 20, let name = pool.string(at: nameIndex) else {
            throw AXmlError.malformedElement
        }

        var attributes: [AXmlAttribute] = []
        attributes.reserveCapacity(attributeCount)
        let attributesBase = offset + 16 + attributeStart

        for index in 0..<attributeCount {
            let base = attributesBase + index * attributeSize
            let attributeNamespace = try readUInt32(data, at: base)
            let attributeName = try readUInt32(data, at: base + 4)
            let rawValue = try readUInt32(data, at: base + 8)
            let dataType = try readUInt8(data, at: base + 15)
            let valueData = try readUInt32(data, at: base + 16)

            guard let attributeNameString = pool.string(at: attributeName) else {
                throw AXmlError.malformedElement
            }

            attributes.append(
                AXmlAttribute(
                    namespaceURI: pool.string(at: attributeNamespace),
                    name: attributeNameString,
                    rawValue: pool.string(at: rawValue),
                    value: try Self.value(dataType: dataType, raw: valueData, pool: pool)
                )
            )
        }

        return OpenElement(
            name: name,
            namespaceURI: pool.string(at: namespaceIndex),
            attributes: attributes,
            children: []
        )
    }

    private static func value(dataType: UInt8, raw: UInt32, pool: StringPool) throws -> AXmlValue {
        switch dataType {
        case 0x01:
            return .reference(raw)
        case 0x03:
            guard let string = pool.string(at: raw) else { throw AXmlError.malformedStringPool }
            return .string(string)
        case 0x10, 0x11:
            return .integer(Int32(bitPattern: raw))
        case 0x12:
            return .boolean(raw != 0)
        default:
            return .other(type: dataType, value: raw)
        }
    }

    // MARK: - 字符串池

    private struct StringPool {
        private let strings: [String]

        init(data: Data, chunkStart: Int, chunkSize: Int) throws {
            let headerSize = Int(try readUInt16(data, at: chunkStart + 2))
            let stringCount = Int(try readUInt32(data, at: chunkStart + 8))
            let flags = try readUInt32(data, at: chunkStart + 16)
            let stringsStart = Int(try readUInt32(data, at: chunkStart + 20))
            let isUTF8 = (flags & 0x100) != 0

            guard headerSize >= 28, stringsStart <= chunkSize else { throw AXmlError.malformedStringPool }

            var parsed: [String] = []
            parsed.reserveCapacity(stringCount)
            let offsetsBase = chunkStart + headerSize

            for index in 0..<stringCount {
                let stringOffset = Int(try readUInt32(data, at: offsetsBase + index * 4))
                let start = chunkStart + stringsStart + stringOffset
                guard start < chunkStart + chunkSize else { throw AXmlError.malformedStringPool }
                parsed.append(isUTF8
                    ? try Self.decodeUTF8(data, at: start)
                    : try Self.decodeUTF16(data, at: start))
            }

            self.strings = parsed
        }

        func string(at index: UInt32) -> String? {
            guard index != 0xFFFF_FFFF, Int(index) < strings.count else { return nil }
            return strings[Int(index)]
        }

        private static func decodeUTF8(_ data: Data, at start: Int) throws -> String {
            var cursor = start
            var characterLength = Int(try readUInt8(data, at: cursor))
            cursor += 1
            if characterLength & 0x80 != 0 {
                let second = Int(try readUInt8(data, at: cursor))
                cursor += 1
                characterLength = ((characterLength & 0x7F) << 8) | second
            }
            _ = characterLength

            var byteLength = Int(try readUInt8(data, at: cursor))
            cursor += 1
            if byteLength & 0x80 != 0 {
                let second = Int(try readUInt8(data, at: cursor))
                cursor += 1
                byteLength = ((byteLength & 0x7F) << 8) | second
            }

            let bytes = try slice(data, from: cursor, length: byteLength)
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw AXmlError.malformedStringPool
            }
            return string
        }

        private static func decodeUTF16(_ data: Data, at start: Int) throws -> String {
            var cursor = start
            var length = Int(try readUInt16(data, at: cursor))
            cursor += 2
            if length & 0x8000 != 0 {
                let second = Int(try readUInt16(data, at: cursor))
                cursor += 2
                length = ((length & 0x7FFF) << 16) | second
            }

            let bytes = try slice(data, from: cursor, length: length * 2)
            guard let string = String(data: bytes, encoding: .utf16LittleEndian) else {
                throw AXmlError.malformedStringPool
            }
            return string
        }
    }

    // MARK: - 读取

    private static func slice(_ data: Data, from offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else { throw AXmlError.truncated }
        let start = data.startIndex + offset
        return data[start..<(start + length)]
    }

    private static func readUInt8(_ data: Data, at offset: Int) throws -> UInt8 {
        let bytes = try slice(data, from: offset, length: 1)
        return bytes[bytes.startIndex]
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        let bytes = try slice(data, from: offset, length: 2)
        let base = bytes.startIndex
        return UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8)
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
