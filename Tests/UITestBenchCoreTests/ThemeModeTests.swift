import XCTest
@testable import UITestBenchCore

final class ThemeModeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeModeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToLight() {
        XCTAssertEqual(ThemePreference(defaults: defaults).mode, .light)
    }

    func testPersistsSelection() {
        var preference = ThemePreference(defaults: defaults)
        preference.mode = .dark
        XCTAssertEqual(ThemePreference(defaults: defaults).mode, .dark)
    }

    func testUnknownValueFallsBackToLight() {
        defaults.set("purple", forKey: ThemeMode.userDefaultsKey)
        XCTAssertEqual(ThemePreference(defaults: defaults).mode, .light)
    }
}
