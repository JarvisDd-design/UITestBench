import XCTest
@testable import UITestBenchCore

final class DockDrawerStateTests: XCTestCase {
    func testHoverShowsDrawerAndLeavingHidesIt() {
        var state = DockDrawerState()
        state.hover(.material)
        XCTAssertEqual(state.presented, .material)
        state.unhover(.material)
        XCTAssertNil(state.presented)
    }

    func testHoverIsIgnoredWhilePinned() {
        var state = DockDrawerState()
        state.pin(.device)
        state.hover(.material)
        XCTAssertEqual(state.presented, .device)
    }

    func testPinningSameModuleTogglesOff() {
        var state = DockDrawerState()
        state.pin(.material)
        XCTAssertEqual(state.pinned, .material)
        state.pin(.material)
        XCTAssertNil(state.pinned)
        XCTAssertNil(state.presented)
    }

    func testPinningAnotherModuleSwitchesDrawer() {
        var state = DockDrawerState()
        state.pin(.material)
        state.pin(.diagnostics)
        XCTAssertEqual(state.presented, .diagnostics)
    }

    func testDismissClearsHoverAndPin() {
        var state = DockDrawerState()
        state.pin(.app)
        state.dismiss()
        XCTAssertNil(state.presented)
        XCTAssertNil(state.pinned)
    }

    func testClearingHoverKeepsPin() {
        var state = DockDrawerState()
        state.pin(.material)
        state.clearHover()
        XCTAssertEqual(state.presented, .material)
    }
}
