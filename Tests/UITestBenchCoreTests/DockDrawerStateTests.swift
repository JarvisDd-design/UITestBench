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

    // MARK: - 跨窗口（多面板）收起判定

    func testClickingPhoneDismissesPinnedDrawer() {
        var state = DockDrawerState()
        state.pin(.device)
        XCTAssertTrue(state.shouldDismissOnClick(target: .phone))
        // 判定本身是纯函数，真正的收起由 DockModel 调 dismiss()。
        state.dismiss()
        XCTAssertNil(state.presented)
    }

    func testClickingDockOrDrawerKeepsPinnedDrawer() {
        var state = DockDrawerState()
        state.pin(.device)
        XCTAssertFalse(state.shouldDismissOnClick(target: .dock))
        XCTAssertFalse(state.shouldDismissOnClick(target: .drawer))
        XCTAssertEqual(state.presented, .device)
    }

    func testClickingAuxiliaryPanelsKeepsPinnedDrawer() {
        var state = DockDrawerState()
        state.pin(.device)
        // 扫码浮层、底胶囊：点它们不该收起抽屉。
        XCTAssertFalse(state.shouldDismissOnClick(target: .auxiliary))
        XCTAssertFalse(state.shouldDismissOnClick(target: .sheet))
        XCTAssertFalse(state.shouldDismissOnClick(target: .modal))
        XCTAssertEqual(state.presented, .device)
    }

    func testHoverDrawerIsNeverDismissedByWindowClick() {
        var state = DockDrawerState()
        state.hover(.app)
        XCTAssertFalse(state.shouldDismissOnClick(target: .phone))
        XCTAssertEqual(state.presented, .app)
    }

    func testDismissByWindowClickClearsPin() {
        var state = DockDrawerState()
        state.pin(.diagnostics)
        XCTAssertTrue(state.shouldDismissOnClick(target: .phone))
        state.dismiss()
        XCTAssertNil(state.pinned)
    }

    // MARK: - Esc 收起判定

    func testEscapeDismissesAnyPresentedDrawer() {
        // hover 抽屉没有焦点，Esc 也要能收起；钉住的同理。
        XCTAssertEqual(
            DockEscapePolicy.action(
                isPresented: true,
                isEditingText: false,
                hasForeignKeyWindow: false
            ),
            .dismiss
        )
    }

    func testEscapeDoesNothingWithoutDrawer() {
        XCTAssertEqual(
            DockEscapePolicy.action(
                isPresented: false,
                isEditingText: false,
                hasForeignKeyWindow: false
            ),
            .ignore
        )
    }

    func testFirstEscapeWhileEditingEndsEditingInsteadOfDismissing() {
        // SwiftUI 的 TextField 不会自己结束编辑：第一次 Esc 只把焦点交出去，
        // 抽屉要等下一次 Esc 才收起。
        XCTAssertEqual(
            DockEscapePolicy.action(
                isPresented: true,
                isEditingText: true,
                hasForeignKeyWindow: false
            ),
            .endEditing
        )
    }

    func testEscapeIsLeftToScannerSheetAndModal() {
        // 扫码浮层的 Esc 属于扫码；sheet / 模态各自处理。
        XCTAssertEqual(
            DockEscapePolicy.action(
                isPresented: true,
                isEditingText: false,
                hasForeignKeyWindow: true
            ),
            .ignore
        )
        XCTAssertEqual(
            DockEscapePolicy.action(
                isPresented: true,
                isEditingText: true,
                hasForeignKeyWindow: true
            ),
            .ignore
        )
    }
}
