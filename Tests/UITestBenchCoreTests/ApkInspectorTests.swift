import XCTest
@testable import UITestBenchCore

final class ApkInspectorTests: XCTestCase {
    /// 只带一个最小 manifest 的包：没有 lib/ 目录，即纯 Java/Kotlin 应用。
    private func minimalApk(extraEntries: [String: Data] = [:]) -> Data {
        APKFixture.minimalAPK(extraEntries: extraEntries)
    }

    func testReadsPackageSdkVersionsAndSizeInOnePass() throws {
        let data = minimalApk()

        let info = try ApkInspector.inspect(data)

        XCTAssertEqual(info.packageName, "com.example.demo")
        XCTAssertEqual(info.versionCode, 7)
        XCTAssertEqual(info.versionName, "0.7")
        XCTAssertEqual(info.minSdkVersion, 24)
        XCTAssertEqual(info.targetSdkVersion, 34)
        XCTAssertEqual(info.byteCount, data.count)
    }

    func testCollectsSortedAbisFromNativeLibDirectories() throws {
        let data = minimalApk(extraEntries: [
            "lib/armeabi-v7a/libfoo.so": Data([0x01]),
            "lib/arm64-v8a/libfoo.so": Data([0x02]),
            "lib/arm64-v8a/libbar.so": Data([0x03]),
            "assets/lib/arm64-v8a/not-a-real-lib.so": Data([0x04])
        ])

        let info = try ApkInspector.inspect(data)

        XCTAssertEqual(info.abis, ["arm64-v8a", "armeabi-v7a"])
    }

    func testPureJavaApkReportsNoAbis() throws {
        let info = try ApkInspector.inspect(minimalApk())

        XCTAssertEqual(info.abis, [])
    }

    func testMarksManifestWithSplitAttributeAsSplitApk() throws {
        let manifest = AXmlFixtureBuilder(
            root: .element(
                name: "manifest",
                attributes: [
                    .string("package", "com.example.demo"),
                    .string("split", "config.arm64_v8a")
                ],
                children: []
            )
        ).build()
        let data = ZipFixtureBuilder()
            .addingStoredEntry(path: "AndroidManifest.xml", contents: manifest)
            .build()

        let info = try ApkInspector.inspect(data)

        XCTAssertTrue(info.isSplitApk)
    }

    func testRejectsArchiveWithoutManifest() throws {
        let data = ZipFixtureBuilder()
            .addingStoredEntry(path: "classes.dex", contents: Data([0x64, 0x65, 0x78]))
            .build()

        XCTAssertThrowsError(try ApkInspector.inspect(data)) { error in
            XCTAssertEqual(error as? ApkInspectionError, .manifestMissing)
        }
    }

    func testReportsUnreadableManifest() throws {
        let data = ZipFixtureBuilder()
            .addingStoredEntry(path: "AndroidManifest.xml", contents: Data("not binary xml".utf8))
            .build()

        XCTAssertThrowsError(try ApkInspector.inspect(data)) { error in
            XCTAssertEqual(error as? ApkInspectionError, .manifestUnreadable)
        }
    }

    func testRejectsDataThatIsNotAZipArchive() throws {
        XCTAssertThrowsError(try ApkInspector.inspect(Data("definitely not a zip".utf8))) { error in
            XCTAssertEqual(error as? ApkInspectionError, .notAZipArchive)
        }
    }

    /// 资源文件名是 GBK 的包仍然是有效 APK，不能因为一个条目名读不出来就整包放弃。
    func testInspectsAnAPKContainingANonUTF8EntryName() throws {
        let data = APKFixture.minimalAPK(extraRawEntries: [
            (pathBytes: Data([0xD6, 0xD0, 0xCE, 0xC4]), contents: Data("asset".utf8))
        ])

        let info = try ApkInspector.inspect(data)

        XCTAssertEqual(info.packageName, "com.example.demo")
    }

    /// 以 PK 开头但结构读不出来：是包损坏或格式不受支持，不该说成「不是 ZIP」。
    func testDistinguishesADamagedZipFromAnOrdinaryFile() {
        let damaged = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 32)

        XCTAssertThrowsError(try ApkInspector.inspect(damaged)) { error in
            XCTAssertEqual(error as? ApkInspectionError, .damagedArchive)
        }
    }
}
