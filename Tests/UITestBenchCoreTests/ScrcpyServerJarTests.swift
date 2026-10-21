import XCTest
@testable import UITestBenchCore

final class ChecksumSHA256Tests: XCTestCase {
    func testSHA256MatchesKnownVector() {
        XCTAssertEqual(
            Checksum.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA256OfFileMatchesData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha256-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try Checksum.sha256Hex(ofFileAt: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}

final class ScrcpyServerJarTests: XCTestCase {
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jar-\(UUID().uuidString).jar")
        try Data("abc".utf8).write(to: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testAcceptsMatchingJar() throws {
        XCTAssertNoThrow(try ScrcpyServerJar.validate(
            url,
            expectedSHA256: abcSHA256,
            expectedByteCount: 3
        ))
    }

    func testRejectsWrongSize() {
        XCTAssertThrowsError(try ScrcpyServerJar.validate(
            url,
            expectedSHA256: abcSHA256,
            expectedByteCount: 4
        )) { error in
            XCTAssertEqual(error as? ScrcpyServerJar.ValidationError, .wrongSize(expected: 4, actual: 3))
        }
    }

    func testRejectsWrongChecksum() {
        XCTAssertThrowsError(try ScrcpyServerJar.validate(
            url,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedByteCount: 3
        )) { error in
            guard case .wrongChecksum = error as? ScrcpyServerJar.ValidationError else {
                return XCTFail("应报校验和不符，实际 \(error)")
            }
        }
    }

    func testRejectsMissingFile() {
        let missing = url.appendingPathExtension("missing")

        XCTAssertThrowsError(try ScrcpyServerJar.validate(
            missing,
            expectedSHA256: abcSHA256,
            expectedByteCount: 3
        )) { error in
            XCTAssertEqual(error as? ScrcpyServerJar.ValidationError, .unreadable)
        }
    }

    func testLocatesJarInFirstDirectoryThatContainsIt() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        let withJar = FileManager.default.temporaryDirectory
            .appendingPathComponent("with-jar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: withJar, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: withJar)
        }
        let jar = withJar.appendingPathComponent(ScrcpyServerJar.fileName)
        try Data("abc".utf8).write(to: jar)

        XCTAssertEqual(
            ScrcpyServerJar.locate(in: [empty, withJar]),
            jar
        )
    }

    func testReturnsNilWhenNoDirectoryHasTheJar() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertNil(ScrcpyServerJar.locate(in: [empty]))
    }

    /// 对真实随包资源做一次校验。
    ///
    ///     UITESTBENCH_SCRCPY_JAR=Sources/UITestBenchApp/Resources/scrcpy-server.jar \
    ///       swift test --filter testBundledJar
    func testBundledJarMatchesPinnedVersionWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["UITESTBENCH_SCRCPY_JAR"] else {
            throw XCTSkip("未设置 UITESTBENCH_SCRCPY_JAR")
        }

        XCTAssertNoThrow(try ScrcpyServerJar.validate(URL(fileURLWithPath: path)))
    }
}
