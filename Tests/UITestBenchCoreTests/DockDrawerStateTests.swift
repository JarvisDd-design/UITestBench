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
        XCTAssertNil(state.hovered, "钉住时悬停不能被记住，否则取消钉住后会冒出抽屉")
        state.pin(.device)
        XCTAssertNil(state.presented)
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

    func testDismissClearsPin() {
        var state = DockDrawerState()
        state.pin(.app)
        state.dismiss()
        XCTAssertNil(state.pinned)
        XCTAssertNil(state.presented)
    }

    func testDismissClearsHover() {
        var state = DockDrawerState()
        state.hover(.material)
        state.dismiss()
        XCTAssertNil(state.hovered)
        XCTAssertNil(state.presented)
    }

    func testClearingHoverKeepsPin() {
        var state = DockDrawerState()
        state.pin(.material)
        state.clearHover()
        XCTAssertEqual(state.presented, .material)
    }

    func testClearingHoverClosesHoveredDrawer() {
        var state = DockDrawerState()
        state.hover(.material)
        state.clearHover()
        XCTAssertNil(state.hovered)
        XCTAssertNil(state.presented)
    }

    func testUnhoverOfAnotherModuleIsIgnored() {
        var state = DockDrawerState()
        state.hover(.material)
        state.unhover(.device)
        XCTAssertEqual(state.hovered, .material)
        XCTAssertEqual(state.presented, .material)
    }

    func testHoveringAnotherModuleSwitchesDrawer() {
        var state = DockDrawerState()
        state.hover(.material)
        state.hover(.device)
        XCTAssertEqual(state.hovered, .device)
        XCTAssertEqual(state.presented, .device)
    }

    func testPinningClearsHover() {
        var state = DockDrawerState()
        state.hover(.material)
        state.pin(.device)
        XCTAssertNil(state.hovered)
        XCTAssertEqual(state.presented, .device)
    }
}
