import XCTest
@testable import UITestBenchCore

/// 磁盘上的 ZIP：中央目录只读尾部与目录区，条目内容流式解压，不把整包读进内存。
final class ZipArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func archive(_ data: Data, named name: String = "archive.zip") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func outputDirectory() throws -> URL {
        let url = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testListsEntriesFromFile() throws {
        let url = try archive(
            ZipFixtureBuilder()
                .addingStoredEntry(path: "a.txt", contents: Data("hello".utf8))
                .addingDeflatedEntry(
                    path: "lib/arm64-v8a/libfoo.so",
                    contents: Data(repeating: 0x42, count: 100_000)
                )
                .build()
        )

        let zip = try ZipArchive(url: url)

        XCTAssertEqual(zip.entries.map(\.path), ["a.txt", "lib/arm64-v8a/libfoo.so"])
        XCTAssertEqual(zip.entries[0].compressionMethod, 0)
        XCTAssertEqual(zip.entries[1].compressionMethod, 8)
        XCTAssertEqual(zip.entries[1].uncompressedSize, 100_000)
        XCTAssertLessThan(zip.entries[1].compressedSize, 100_000)
    }

    func testExtractsStoredAndDeflatedEntries() throws {
        let url = try archive(
            ZipFixtureBuilder()
                .addingStoredEntry(path: "a.txt", contents: Data("hello".utf8))
                .addingDeflatedEntry(path: "lib/arm64-v8a/libfoo.so", contents: Data("shared object".utf8))
                .addingStoredEntry(path: "empty/", contents: Data())
                .build()
        )
        let zip = try ZipArchive(url: url)
        let output = try outputDirectory()

        try zip.extractAll(to: output)

        let manager = FileManager.default
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("a.txt")),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("lib/arm64-v8a/libfoo.so")),
            Data("shared object".utf8)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(manager.fileExists(
            atPath: output.appendingPathComponent("empty").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExtractsLargeDeflatedEntryInChunks() throws {
        // 大于 64 KB 缓冲区的数据，验证流式循环没有截断。
        var contents = Data(count: 3_000_000)
        for index in contents.indices {
            contents[index] = UInt8(truncatingIfNeeded: index % 251)
        }
        let url = try archive(
            ZipFixtureBuilder()
                .addingDeflatedEntry(path: "big.bin", contents: contents)
                .build()
        )
        let output = try outputDirectory()

        try ZipArchive(url: url).extractAll(to: output)

        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("big.bin")), contents)
    }

    func testAppliesUnixPermissions() throws {
        let url = try archive(
            ZipFixtureBuilder()
                .addingStoredEntry(path: "bin/adb", contents: Data("#!/bin/sh\n".utf8), unixPermissions: 0o755)
                .addingStoredEntry(path: "README.txt", contents: Data("read me".utf8), unixPermissions: 0o644)
                .build()
        )
        let output = try outputDirectory()

        try ZipArchive(url: url).extractAll(to: output)

        XCTAssertEqual(try permissions(of: output.appendingPathComponent("bin/adb")), 0o755)
        XCTAssertEqual(try permissions(of: output.appendingPathComponent("README.txt")), 0o644)
    }

    func testRejectsPathTraversal() throws {
        let url = try archive(
            ZipFixtureBuilder()
                .addingStoredEntry(path: "../escaped.txt", contents: Data("nope".utf8))
                .build()
        )
        let output = try outputDirectory()

        XCTAssertThrowsError(try ZipArchive(url: url).extractAll(to: output)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .unsafeEntryPath("../escaped.txt"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.txt").path)
        )
    }

    func testDetectsCorruptedPayloadByCRC() throws {
        var data = ZipFixtureBuilder()
            .addingStoredEntry(path: "a.txt", contents: Data("hello world".utf8))
            .build()
        let payload = Data("hello world".utf8)
        let range = try XCTUnwrap(data.range(of: payload))
        data[range.lowerBound] = UInt8(ascii: "H")
        let url = try archive(data)
        let output = try outputDirectory()

        XCTAssertThrowsError(try ZipArchive(url: url).extractAll(to: output)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .checksumMismatch("a.txt"))
        }
    }

    /// 合法的空归档只有 EOCD，应读出 0 个条目而不是报截断。
    func testReadsEmptyArchiveWithoutEntries() throws {
        let url = try archive(ZipFixtureBuilder().build())
        let output = try outputDirectory()

        let zip = try ZipArchive(url: url)
        XCTAssertTrue(zip.entries.isEmpty)
        XCTAssertNoThrow(try zip.extractAll(to: output))
    }

    func testRejectsNonZipFile() throws {
        let url = try archive(Data("definitely not a zip".utf8))

        XCTAssertThrowsError(try ZipArchive(url: url)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .notAZipArchive)
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
