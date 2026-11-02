import XCTest
@testable import UITestBenchCore

final class MirrorQualityModeTests: XCTestCase {
    func testSmoothTradesResolutionFramerateForLatency() {
        XCTAssertEqual(MirrorQualityMode.smooth.maxFPS, 30)
        XCTAssertEqual(MirrorQualityMode.smooth.maxSize, 1280)
        XCTAssertEqual(MirrorQualityMode.smooth.videoBitRate, 4_000_000)
        XCTAssertEqual(MirrorQualityMode.sharp.maxFPS, 60)
        XCTAssertEqual(MirrorQualityMode.sharp.maxSize, 1920)
        XCTAssertEqual(MirrorQualityMode.sharp.videoBitRate, 6_000_000)
    }

    func testSharpKeepsMorePixelsAndBytesThanSmooth() {
        XCTAssertLessThan(MirrorQualityMode.smooth.maxSize, MirrorQualityMode.sharp.maxSize)
        XCTAssertLessThan(MirrorQualityMode.smooth.videoBitRate, MirrorQualityMode.sharp.videoBitRate)
    }

    func testLargeProfilesDefaultToSmooth() {
        XCTAssertEqual(MirrorQualityMode.defaultMode(for: .compact), .sharp)
        XCTAssertEqual(MirrorQualityMode.defaultMode(for: .standard), .sharp)
        XCTAssertEqual(MirrorQualityMode.defaultMode(for: .large), .smooth)
        let custom = DeviceProfile(name: "自定义", width: 1440, height: 2960, density: 560)
        XCTAssertEqual(MirrorQualityMode.defaultMode(for: custom), .smooth)
    }

    func testStartupArgumentsCarrySizeFramerateAndBitRate() {
        XCTAssertEqual(
            MirrorQualityMode.smooth.startupArguments,
            ["max_size=1280", "max_fps=30", "video_bit_rate=4000000"]
        )
        XCTAssertEqual(
            MirrorQualityMode.sharp.startupArguments,
            ["max_size=1920", "max_fps=60", "video_bit_rate=6000000"]
        )
    }

    func testPreferenceFallsBackToDeviceDefault() {
        let defaults = UserDefaults(suiteName: "MirrorQualityModeTests")!
        defaults.removePersistentDomain(forName: "MirrorQualityModeTests")
        let preference = MirrorQualityPreference(defaults: defaults)

        XCTAssertNil(preference.storedMode)
        XCTAssertEqual(preference.mode(for: .large), .smooth)
        XCTAssertEqual(preference.mode(for: .standard), .sharp)

        preference.storedMode = .smooth
        XCTAssertEqual(preference.mode(for: .standard), .smooth)
        XCTAssertEqual(
            defaults.string(forKey: MirrorQualityMode.userDefaultsKey),
            "smooth"
        )

        preference.storedMode = nil
        XCTAssertNil(defaults.string(forKey: MirrorQualityMode.userDefaultsKey))
        XCTAssertEqual(preference.mode(for: .large), .smooth)
    }
}
