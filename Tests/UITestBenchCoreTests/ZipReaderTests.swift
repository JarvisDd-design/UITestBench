import XCTest
@testable import UITestBenchCore

final class ZipReaderTests: XCTestCase {
    func testListsEntryPathsFromCentralDirectory() throws {
        let archive = ZipFixtureBuilder()
            .addingStoredEntry(path: "AndroidManifest.xml", contents: Data([0x03, 0x00, 0x08, 0x00]))
            .addingStoredEntry(path: "lib/arm64-v8a/libdemo.so", contents: Data(repeating: 0xAA, count: 16))
            .build()

        let reader = try ZipReader(data: archive)

        XCTAssertEqual(
            reader.entries.map(\.path),
            ["AndroidManifest.xml", "lib/arm64-v8a/libdemo.so"]
        )
    }
}

extension ZipReaderTests {
    func testReadsContentsOfStoredEntry() throws {
        let payload = Data("manifest-bytes".utf8)
        let archive = ZipFixtureBuilder()
            .addingStoredEntry(path: "AndroidManifest.xml", contents: payload)
            .build()

        let reader = try ZipReader(data: archive)

        XCTAssertEqual(try reader.contents(ofEntryAtPath: "AndroidManifest.xml"), payload)
    }
}

extension ZipReaderTests {
    // 由系统 `zip -9` 生成的真实样本，用来验证 deflate 解码与真实 ZIP 兼容。
    func testReadsContentsOfDeflatedEntry() throws {
        let base64 = """
        UEsDBBQAAgAIAFeLVF3GB3u7FQAAAHgFAAATABwAQW5kcm9pZE1hbmlmZXN0LnhtbFVUCQAD1jPXatQz12p1eAsAAQT2AQAABAAAAABLzEspys9MSRylRqlRapQapehDAQBQSwECHgMUAAIACABXi1Rdxgd7uxUAAAB4BQAAEwAYAAAAAAABAAAApIEAAAAAQW5kcm9pZE1hbmlmZXN0LnhtbFVUBQAD1jPXanV4CwABBPYBAAAEAAAAAFBLBQYAAAAAAQABAFkAAABiAAAAAAA=
        """
        let archive = try XCTUnwrap(Data(base64Encoded: base64))
        let reader = try ZipReader(data: archive)

        let contents = try reader.contents(ofEntryAtPath: "AndroidManifest.xml")

        XCTAssertEqual(contents, Data(String(repeating: "android", count: 200).utf8))
    }
}

extension ZipReaderTests {
    func testRejectsDataThatIsNotAZipArchive() {
        let garbage = Data(repeating: 0x42, count: 128)

        XCTAssertThrowsError(try ZipReader(data: garbage)) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .notAZipArchive)
        }
    }

    func testReportsMissingEntry() throws {
        let archive = ZipFixtureBuilder()
            .addingStoredEntry(path: "a.txt", contents: Data("a".utf8))
            .build()
        let reader = try ZipReader(data: archive)

        XCTAssertThrowsError(try reader.contents(ofEntryAtPath: "missing.txt")) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .entryNotFound("missing.txt"))
        }
    }

    /// 有些 APK 的资源文件名是 GBK。一个读不出来的名字不该让整个包被
    /// 判成「不是 ZIP」——AndroidManifest.xml 本身永远是可读的 ASCII。
    func testKeepsReadingWhenAnEntryNameIsNotUTF8() throws {
        let gbkAssetName = Data([0xD6, 0xD0, 0xCE, 0xC4]) // 「中文」的 GBK 编码
        let manifest = Data("manifest-bytes".utf8)
        let archive = ZipFixtureBuilder()
            .addingStoredEntry(path: "AndroidManifest.xml", contents: manifest)
            .addingStoredEntry(rawPath: gbkAssetName, contents: Data("asset".utf8))
            .build()

        let reader = try ZipReader(data: archive)

        XCTAssertTrue(reader.entries.contains { $0.path == "AndroidManifest.xml" })
        XCTAssertEqual(try reader.contents(ofEntryAtPath: "AndroidManifest.xml"), manifest)
    }
}
