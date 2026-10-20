import Foundation

/// 按 AOSP 的二进制 XML 布局，在测试里手工生成 AndroidManifest.xml 样本。
///
/// 只覆盖本项目需要的能力：字符串池、命名空间、开始/结束标签、四类属性值。
/// 布局参照 framed/res/xml 的 chunk 结构，字段顺序与 AOSP 一致。
struct AXmlFixtureBuilder {
    enum Value {
        case string(String)
        case integer(Int32)
        case boolean(Bool)
        case reference(UInt32)
    }

    struct Attribute {
        var namespace: String?
        var name: String
        var rawValue: String?
        var value: Value

        static func string(_ name: String, _ value: String, namespace: String? = nil) -> Attribute {
            Attribute(namespace: namespace, name: name, rawValue: value, value: .string(value))
        }

        static func integer(_ name: String, _ value: Int32, namespace: String? = nil) -> Attribute {
            Attribute(namespace: namespace, name: name, rawValue: nil, value: .integer(value))
        }
    }

    indirect enum Node {
        case element(name: String, attributes: [Attribute], children: [Node])
    }

    var root: Node
    var namespacePrefix: String? = "android"
    var namespaceURI: String? = "http://schemas.android.com/apk/res/android"

    func build() -> Data {
        var pool = StringPool()
        _ = pool.index(of: "") // 惯例：0 号永远指向空串

        if let namespacePrefix { _ = pool.index(of: namespacePrefix) }
        if let namespaceURI { _ = pool.index(of: namespaceURI) }
        collect(root, into: &pool)

        var body = Data()
        if let prefix = namespacePrefix, let uri = namespaceURI {
            body.append(namespaceChunk(type: 0x0100, prefix: pool.index(of: prefix), uri: pool.index(of: uri)))
        }
        body.append(encode(root, pool: pool))
        if let prefix = namespacePrefix, let uri = namespaceURI {
            body.append(namespaceChunk(type: 0x0101, prefix: pool.index(of: prefix), uri: pool.index(of: uri)))
        }

        let resourceMap = resourceMapChunk()

        var document = Data()
        document.appendLE(UInt16(0x0003))            // RES_XML_TYPE
        document.appendLE(UInt16(8))                 // header size
        document.appendLE(UInt32(8 + pool.chunk.count + resourceMap.count + body.count))
        document.append(pool.chunk)
        document.append(resourceMap)
        document.append(body)
        return document
    }

    // MARK: - 字符串池

    private struct StringPool {
        private(set) var strings: [String] = []
        private var indices: [String: Int] = [:]

        mutating func index(of string: String) -> Int {
            if let existing = indices[string] { return existing }
            let index = strings.count
            strings.append(string)
            indices[string] = index
            return index
        }

        /// 只读查询：编码阶段所有字符串应当已经被 `collect` 收齐。
        func existingIndex(of string: String) -> Int {
            guard let index = indices[string] else {
                preconditionFailure("字符串池里没有 \"\(string)\"，收集阶段漏了")
            }
            return index
        }

        var chunk: Data {
            var data = Data()
            var offsets: [UInt32] = []

            for string in strings {
                offsets.append(UInt32(data.count))
                data.append(Self.encodeUTF8(string))
            }
            while data.count % 4 != 0 { data.append(0) }

            let headerSize = 28
            let stringsStart = headerSize + strings.count * 4

            var chunk = Data()
            chunk.appendLE(UInt16(0x0001))            // RES_STRING_POOL_TYPE
            chunk.appendLE(UInt16(headerSize))
            chunk.appendLE(UInt32(stringsStart + data.count))
            chunk.appendLE(UInt32(strings.count))
            chunk.appendLE(UInt32(0))                 // style count
            chunk.appendLE(UInt32(0x100))             // UTF8_FLAG
            chunk.appendLE(UInt32(stringsStart))
            chunk.appendLE(UInt32(0))                 // styles start
            for offset in offsets { chunk.appendLE(offset) }
            chunk.append(data)
            return chunk
        }

        /// AOSP 的 UTF-8 池：字符数 + 字节数都是「首字节高位为 1 则占两字节」的变体。
        private static func encodeUTF8(_ string: String) -> Data {
            let bytes = Array(string.utf8)
            let characterCount = string.utf16.count
            var out = Data()

            if characterCount > 0x7F {
                out.append(UInt8((characterCount >> 8) | 0x80))
                out.append(UInt8(characterCount & 0xFF))
            } else {
                out.append(UInt8(characterCount))
            }

            if bytes.count > 0x7F {
                out.append(UInt8((bytes.count >> 8) | 0x80))
                out.append(UInt8(bytes.count & 0xFF))
            } else {
                out.append(UInt8(bytes.count))
            }

            out.append(contentsOf: bytes)
            out.append(0)
            return out
        }
    }

    // MARK: - 收集字符串

    private func collect(_ node: Node, into pool: inout StringPool) {
        guard case let .element(name, attributes, children) = node else { return }
        _ = pool.index(of: name)
        for attribute in attributes {
            if let namespace = attribute.namespace { _ = pool.index(of: namespace) }
            _ = pool.index(of: attribute.name)
            if let rawValue = attribute.rawValue { _ = pool.index(of: rawValue) }
            if case let .string(value) = attribute.value { _ = pool.index(of: value) }
        }
        for child in children { collect(child, into: &pool) }
    }

    // MARK: - 编码

    private func resourceMapChunk() -> Data {
        var chunk = Data()
        chunk.appendLE(UInt16(0x0180))                // RES_XML_RESOURCE_MAP_TYPE
        chunk.appendLE(UInt16(8))
        chunk.appendLE(UInt32(8))
        return chunk
    }

    private func namespaceChunk(type: UInt16, prefix: Int, uri: Int) -> Data {
        var chunk = Data()
        chunk.appendLE(type)
        chunk.appendLE(UInt16(16))
        chunk.appendLE(UInt32(24))
        chunk.appendLE(UInt32(1))                     // line number
        chunk.appendLE(UInt32(0xFFFF_FFFF))           // comment
        chunk.appendLE(UInt32(prefix))
        chunk.appendLE(UInt32(uri))
        return chunk
    }

    private func encode(_ node: Node, pool: StringPool) -> Data {
        guard case let .element(name, attributes, children) = node else { return Data() }

        var out = Data()
        let attributeSize = 20
        let headerSize = 16

        out.appendLE(UInt16(0x0102))                  // RES_XML_START_ELEMENT_TYPE
        out.appendLE(UInt16(headerSize))
        out.appendLE(UInt32(headerSize + 20 + attributes.count * attributeSize))
        out.appendLE(UInt32(1))                       // line number
        out.appendLE(UInt32(0xFFFF_FFFF))             // comment
        out.appendLE(UInt32(0xFFFF_FFFF))             // namespace（元素本身无命名空间）
        out.appendLE(UInt32(pool.existingIndex(of: name)))
        out.appendLE(UInt16(20))                      // attribute start
        out.appendLE(UInt16(attributeSize))
        out.appendLE(UInt16(attributes.count))
        out.appendLE(UInt16(0))                       // id index
        out.appendLE(UInt16(0))                       // class index
        out.appendLE(UInt16(0))                       // style index

        for attribute in attributes {
            let namespaceIndex = attribute.namespace.map { pool.existingIndex(of: $0) } ?? 0xFFFF_FFFF
            let rawValueIndex = attribute.rawValue.map { pool.existingIndex(of: $0) } ?? 0xFFFF_FFFF
            out.appendLE(UInt32(namespaceIndex))
            out.appendLE(UInt32(pool.existingIndex(of: attribute.name)))
            out.appendLE(UInt32(rawValueIndex))
            out.appendLE(UInt16(8))                   // typed value size
            out.append(UInt8(0))                      // res0
            switch attribute.value {
            case let .string(value):
                out.append(UInt8(0x03))               // TYPE_STRING
                out.appendLE(UInt32(pool.existingIndex(of: value)))
            case let .integer(value):
                out.append(UInt8(0x10))               // TYPE_INT_DEC
                out.appendLE(value)
            case let .boolean(value):
                out.append(UInt8(0x12))               // TYPE_INT_BOOLEAN
                out.appendLE(UInt32(value ? 0xFFFF_FFFF : 0))
            case let .reference(value):
                out.append(UInt8(0x01))               // TYPE_REFERENCE
                out.appendLE(value)
            }
        }

        for child in children { out.append(encode(child, pool: pool)) }

        out.appendLE(UInt16(0x0103))                  // RES_XML_END_ELEMENT_TYPE
        out.appendLE(UInt16(headerSize))
        out.appendLE(UInt32(24))
        out.appendLE(UInt32(1))
        out.appendLE(UInt32(0xFFFF_FFFF))
        out.appendLE(UInt32(0xFFFF_FFFF))
        out.appendLE(UInt32(pool.existingIndex(of: name)))

        return out
    }
}
