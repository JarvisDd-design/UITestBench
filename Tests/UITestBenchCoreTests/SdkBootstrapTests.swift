import XCTest
@testable import UITestBenchCore

final class SdkBootstrapTests: XCTestCase {
    private let repositoryXML = """
    <?xml version='1.0' encoding='utf-8'?>
    <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" \
    xmlns:common="http://schemas.android.com/repository/android/common/02" \
    xmlns:generic="http://schemas.android.com/repository/android/generic/02" \
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <remotePackage path="platform-tools">
        <revision><major>37</major><minor>0</minor><micro>1</micro></revision>
        <archives>
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
        <revision><major>37</major><minor>3</minor><micro>4</micro></revision>
        <archives>
          <archive>
            <complete>
              <size>493505602</size>
              <checksum type="sha1">155220398c3537b5a5fed77d7678619840293cb4</checksum>
              <url>emulator-darwin_x64.zip</url>
            </complete>
            <host-os>macosx</host-os>
            <host-arch>x64</host-arch>
          </archive>
          <archive>
            <complete>
              <size>420504752</size>
              <checksum type="sha1">4cd3b6f14336a0085b8992eeffe637864839b4ce</checksum>
              <url>emulator-darwin_aarch64.zip</url>
            </complete>
            <host-os>macosx</host-os>
            <host-arch>aarch64</host-arch>
          </archive>
        </archives>
      </remotePackage>
    </sdk:sdk-repository>
    """

    private let systemImageXML = """
    <?xml version='1.0' encoding='utf-8'?>
    <sdk:sdk-sys-img xmlns:sdk="http://schemas.android.com/sdk/android/repo/sys-img2/03" \
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <remotePackage path="system-images;android-34;default;arm64-v8a">
        <revision><major>4</major></revision>
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
    </sdk:sdk-sys-img>
    """

    override func setUp() {
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
    }

    private func configuration(hostArch: String = "aarch64") -> SdkBootstrapConfiguration {
        SdkBootstrapConfiguration(
            repositoryURL: URL(string: "https://mirror.example.com/repo/repository2-3.xml")!,
            systemImageRepositoryURL: URL(string: "https://mirror.example.com/sys-img/sys-img2-3.xml")!,
            systemImagePackagePath: "system-images;android-34;default;arm64-v8a",
            hostOS: "macosx",
            hostArch: hostArch
        )
    }

    private func bootstrap() -> SdkBootstrap {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return SdkBootstrap(
            configuration: configuration(),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    func testBuildsPlanFromMirrorManifests() async throws {
        StubURLProtocol.handler = { request in
            let body = request.url!.lastPathComponent == "repository2-3.xml"
                ? Data(self.repositoryXML.utf8)
                : Data(self.systemImageXML.utf8)
            return .init(status: 200, body: body)
        }

        let plan = try await bootstrap().plan()

        XCTAssertEqual(plan.downloads.map(\.packagePath), [
            "platform-tools",
            "emulator",
            "system-images;android-34;default;arm64-v8a"
        ])
        XCTAssertEqual(
            plan.downloads[0].url.absoluteString,
            "https://mirror.example.com/repo/platform-tools_r37.0.1-darwin.zip"
        )
        XCTAssertEqual(
            plan.downloads[1].url.absoluteString,
            "https://mirror.example.com/repo/emulator-darwin_aarch64.zip"
        )
        XCTAssertEqual(
            plan.downloads[2].url.absoluteString,
            "https://mirror.example.com/sys-img/arm64-v8a-34_r04.zip"
        )
    }

    func testThrowsOnHTTPError() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 503, body: Data())
        }

        do {
            _ = try await bootstrap().plan()
            XCTFail("503 应当抛错")
        } catch {
            XCTAssertEqual(error as? SdkBootstrapError, .httpStatus(503))
        }
    }

    func testThrowsOnMalformedXML() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: Data("not xml".utf8))
        }

        do {
            _ = try await bootstrap().plan()
            XCTFail("XML 损坏应当抛错")
        } catch {
            XCTAssertEqual(error as? SdkRepositoryError, .malformedXML)
        }
    }

    func testDefaultTargetsGoogleAndCurrentArchitecture() {
        let configuration = SdkBootstrapConfiguration.default

        XCTAssertEqual(
            configuration.repositoryURL.absoluteString,
            "https://dl.google.com/android/repository/repository2-3.xml"
        )
        XCTAssertEqual(
            configuration.systemImageRepositoryURL.absoluteString,
            "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml"
        )
        XCTAssertEqual(configuration.systemImagePackagePath, "system-images;android-34;default;arm64-v8a")
        XCTAssertEqual(configuration.hostOS, "macosx")
        #if arch(arm64)
        XCTAssertEqual(configuration.hostArch, "aarch64")
        #else
        XCTAssertEqual(configuration.hostArch, "x64")
        #endif
    }
}
