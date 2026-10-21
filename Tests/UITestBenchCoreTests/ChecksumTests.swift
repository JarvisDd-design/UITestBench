import XCTest
@testable import UITestBenchCore

final class ChecksumTests: XCTestCase {
    func testComputesSHA1OfEmptyData() {
        XCTAssertEqual(
            Checksum.sha1Hex(of: Data()),
            "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        )
    }

    func testComputesSHA1OfASCII() {
        XCTAssertEqual(
            Checksum.sha1Hex(of: Data("abc".utf8)),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
    }

    func testHashesFileOnDiskWithoutLoadingItWhole() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChecksumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: url)

        XCTAssertEqual(
            try Checksum.sha1Hex(ofFileAt: url),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
    }

    func testFileHashMatchesInMemoryHashForLargeFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChecksumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var contents = Data(count: 2_500_000)
        for index in contents.indices {
            contents[index] = UInt8(truncatingIfNeeded: index % 241)
        }
        let url = directory.appendingPathComponent("big.bin")
        try contents.write(to: url)

        XCTAssertEqual(try Checksum.sha1Hex(ofFileAt: url), Checksum.sha1Hex(of: contents))
    }

    func testMatchesIsCaseInsensitive() {
        let data = Data("abc".utf8)

        XCTAssertTrue(Checksum.matches("A9993E364706816ABA3E25717850C26C9CD0D89D", data: data))
        XCTAssertFalse(Checksum.matches("a9993e364706816aba3e25717850c26c9cd0d89e", data: data))
    }
}
