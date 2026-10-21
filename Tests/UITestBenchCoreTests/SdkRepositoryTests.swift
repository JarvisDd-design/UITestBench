import XCTest
@testable import UITestBenchCore

final class SdkRepositoryTests: XCTestCase {
    /// 结构照抄 Google 的 repository2-3.xml，只删掉无关条目。
    private let fixture = """
    <?xml version='1.0' encoding='utf-8'?>
    <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" \
    xmlns:common="http://schemas.android.com/repository/android/common/02" \
    xmlns:generic="http://schemas.android.com/repository/android/generic/02" \
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <remotePackage path="platform-tools">
        <type-details xsi:type="generic:genericDetailsType"/>
        <revision>
          <major>37</major>
          <minor>0</minor>
          <micro>1</micro>
        </revision>
        <display-name>Android SDK Platform-Tools</display-name>
        <uses-license ref="android-sdk-license"/>
        <dependencies>
          <dependency path="emulator">
            <min-revision>
              <major>29</major>
              <minor>1</minor>
              <micro>11</micro>
            </min-revision>
          </dependency>
        </dependencies>
        <archives>
          <archive>
            <complete>
              <size>9054187</size>
              <checksum type="sha1">aa5f903c15cf51001717bdf347fb6b53e0aaa</checksum>
              <url>platform-tools_r37.0.1-linux.zip</url>
            </complete>
            <host-os>linux</host-os>
          </archive>
          <archive>
            <complete>
              <size>16110554</size>
              <checksum type="sha1">bb73f4de6452dc57e62ec02b68eed92a4c21661</checksum>
              <url>platform-tools_r37.0.1-darwin.zip</url>
            </complete>
            <host-os>macosx</host-os>
          </archive>
        </archives>
      </remotePackage>
      <remotePackage path="emulator">
        <revision>
          <major>37</major>
          <minor>3</minor>
          <micro>4</micro>
        </revision>
        <display-name>Android Emulator</display-name>
        <uses-license ref="android-sdk-preview-license"/>
        <archives>
          <archive>
            <complete>
              <size>493505602</size>
              <checksum type="sha1">155220398c3537b5a5fed77d7678619840293cb4</checksum>
              <url>emulator-darwin_x64-16555280.zip</url>
            </complete>
            <host-os>macosx</host-os>
            <host-arch>x64</host-arch>
          </archive>
          <archive>
            <complete>
              <size>420504752</size>
              <checksum type="sha1">4cd3b6f14336a0085b8992eeffe637864839b4ce</checksum>
              <url>emulator-darwin_aarch64-16555280.zip</url>
            </complete>
            <host-os>macosx</host-os>
            <host-arch>aarch64</host-arch>
          </archive>
        </archives>
      </remotePackage>
      <remotePackage path="system-images;android-34;default;arm64-v8a">
        <type-details xsi:type="sys-img:sysImgDetailsType">
          <api-level>34</api-level>
          <tag>
            <id>default</id>
            <display>Default Android System Image</display>
          </tag>
          <abi>arm64-v8a</abi>
        </type-details>
        <revision>
          <major>4</major>
        </revision>
        <display-name>ARM 64 v8a System Image</display-name>
        <uses-license ref="android-sdk-license"/>
        <archives>
          <archive>
            <complete>
              <size>705115396</size>
              <checksum type="sha1">d9f2011131919abe952814e041f16f317242c3fa</checksum>
              <url>arm64-v8a-34_r04.zip</url>
            </complete>
          </archive>
        </archives>
      </remotePackage>
    </sdk:sdk-repository>
    """

    private func parseFixture() throws -> SdkRepository {
        try SdkRepository.parse(Data(fixture.utf8))
    }

    func testReadsPackageIdentityAndRevision() throws {
        let repository = try parseFixture()
        let tools = try XCTUnwrap(repository.package(atPath: "platform-tools"))

        XCTAssertEqual(repository.packages.count, 3)
        XCTAssertEqual(tools.revision, SdkRevision(major: 37, minor: 0, micro: 1))
        XCTAssertEqual(tools.displayName, "Android SDK Platform-Tools")
        XCTAssertEqual(tools.licenseID, "android-sdk-license")
    }

    func testPicksTheArchiveForTheRequestedHost() throws {
        let tools = try XCTUnwrap(try parseFixture().package(atPath: "platform-tools"))
        let archive = try XCTUnwrap(tools.archive(forHostOS: "macosx"))

        XCTAssertEqual(archive.url, "platform-tools_r37.0.1-darwin.zip")
        XCTAssertEqual(archive.size, 16_110_554)
        XCTAssertEqual(archive.sha1, "bb73f4de6452dc57e62ec02b68eed92a4c21661")
    }

    func testReturnsNilWhenNoArchiveMatchesTheHost() throws {
        let tools = try XCTUnwrap(try parseFixture().package(atPath: "platform-tools"))

        XCTAssertNil(tools.archive(forHostOS: "windows"))
    }

    /// Apple 芯片要选 aarch64，不能拿第一个 macosx 的包。
    func testPicksArchiveMatchingHostArchitecture() throws {
        let emulator = try XCTUnwrap(try parseFixture().package(atPath: "emulator"))
        let archive = try XCTUnwrap(emulator.archive(forHostOS: "macosx", hostArch: "aarch64"))

        XCTAssertEqual(archive.url, "emulator-darwin_aarch64-16555280.zip")
        XCTAssertEqual(archive.size, 420_504_752)
    }

    /// 没有 host-arch 的包与架构无关，任何芯片都能用。
    func testFallsBackToArchIndependentArchive() throws {
        let tools = try XCTUnwrap(try parseFixture().package(atPath: "platform-tools"))
        let archive = try XCTUnwrap(tools.archive(forHostOS: "macosx", hostArch: "aarch64"))

        XCTAssertEqual(archive.url, "platform-tools_r37.0.1-darwin.zip")
    }

    /// 系统镜像的 archive 不带 host-os，任何平台都能用。
    func testTreatsArchiveWithoutHostOSAsUniversal() throws {
        let image = try XCTUnwrap(
            try parseFixture().package(atPath: "system-images;android-34;default;arm64-v8a")
        )
        let archive = try XCTUnwrap(image.archive(forHostOS: "macosx"))

        XCTAssertEqual(archive.url, "arm64-v8a-34_r04.zip")
        XCTAssertEqual(archive.size, 705_115_396)
        XCTAssertEqual(image.revision, SdkRevision(major: 4))
    }

    func testReadsDependencyMinimumRevision() throws {
        let tools = try XCTUnwrap(try parseFixture().package(atPath: "platform-tools"))

        XCTAssertEqual(
            tools.dependencyMinimumRevisions["emulator"],
            SdkRevision(major: 29, minor: 1, micro: 11)
        )
    }

    func testLookupOfUnknownPathReturnsNil() throws {
        XCTAssertNil(try parseFixture().package(atPath: "system-images;android-99;x;y"))
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try SdkRepository.parse(Data("<sdk-repository><remotePackage".utf8))) { error in
            XCTAssertEqual(error as? SdkRepositoryError, .malformedXML)
        }
    }

    func testRevisionsCompareNumerically() {
        XCTAssertLessThan(SdkRevision(major: 29, minor: 1, micro: 11), SdkRevision(major: 37))
        XCTAssertLessThan(SdkRevision(major: 37, minor: 0, micro: 1), SdkRevision(major: 37, minor: 1))
        XCTAssertEqual(SdkRevision(major: 4).description, "4.0.0")
    }
}
