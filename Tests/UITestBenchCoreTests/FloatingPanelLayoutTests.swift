import CoreGraphics
import XCTest
@testable import UITestBenchCore

final class FloatingPanelLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let phone = CGRect(x: 500, y: 300, width: 314, height: 681)

    func testDockSitsLeftOfPhoneWithItsTopAligned() {
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: nil,
            visibleScreen: visible
        )
        XCTAssertEqual(frames.dock, CGRect(x: 420, y: 537, width: 68, height: 444))
    }

    func testCapsuleSitsBelowPhoneAndMatchesItsWidth() {
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: nil,
            visibleScreen: visible
        )
        XCTAssertEqual(frames.capsule, CGRect(x: 500, y: 240, width: 314, height: 48))
    }

    func testDrawerSitsLeftOfDockAndIsVerticallyCenteredOnIt() {
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: CGSize(width: 292, height: 200),
            visibleScreen: visible
        )
        // 坞 y=537..981，中心 759；200 高卡片 → y=659；右侧 = 420-12 = 408。
        XCTAssertEqual(frames.drawer, CGRect(x: 116, y: 659, width: 292, height: 200))
    }

    func testDrawerIsClampedToTheLeftEdgeInsteadOfFlippingRight() {
        let leftPhone = CGRect(x: 80, y: 300, width: 314, height: 681)
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: leftPhone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: CGSize(width: 292, height: 200),
            visibleScreen: visible
        )
        // 坞 x=0，卡片本该到 -304；夹到屏幕左侧 8pt，允许压住坞。
        XCTAssertEqual(frames.drawer?.minX, 8)
        XCTAssertEqual(frames.drawer?.width, 292)
    }

    func testDrawerIsClampedToTheTopInset() {
        let highPhone = CGRect(x: 500, y: 600, width: 314, height: 681)
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: highPhone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: CGSize(width: 292, height: 500),
            visibleScreen: visible
        )
        XCTAssertEqual(frames.drawer?.maxY, 892)
    }

    func testDrawerIsClampedToTheBottomInset() {
        // 矮手机 + 矮坞让坞中心很低，500 高的卡片会掉到屏幕下方。
        let lowPhone = CGRect(x: 500, y: 0, width: 314, height: 200)
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: lowPhone,
            dockSize: CGSize(width: 68, height: 100),
            capsuleHeight: 48,
            drawerSize: CGSize(width: 292, height: 500),
            visibleScreen: visible
        )
        XCTAssertEqual(frames.drawer?.minY, 8)
    }

    func testTallDrawerOnShortScreenKeepsItsHeaderVisible() {
        let shortScreen = CGRect(x: 0, y: 0, width: 1440, height: 600)
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 300),
            capsuleHeight: 48,
            drawerSize: CGSize(width: 292, height: 560),
            visibleScreen: shortScreen
        )
        // 放不下时顶部贴住可见区顶部，保证标题栏可见。
        XCTAssertEqual(frames.drawer?.maxY, 592)
        XCTAssertEqual(frames.drawer?.height, 560)
    }

    func testNoDrawerSizeProducesNoDrawerFrame() {
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: nil,
            visibleScreen: visible
        )
        XCTAssertNil(frames.drawer)
    }

    func testCustomMetricsAreHonored() {
        var metrics = FloatingPanelMetrics.standard
        metrics.dockGap = 20
        metrics.capsuleGap = 30
        metrics.drawerGap = 40
        metrics.screenInset = 10
        let frames = FloatingPanelLayoutCalculator.frames(
            phoneFrame: phone,
            dockSize: CGSize(width: 68, height: 444),
            capsuleHeight: 48,
            drawerSize: nil,
            visibleScreen: visible,
            metrics: metrics
        )
        XCTAssertEqual(frames.dock.maxX, phone.minX - 20)
        XCTAssertEqual(frames.capsule.maxY, phone.minY - 30)
    }

    func testClampedPhoneFrameKeepsDockAndCapsuleOnScreen() {
        let offscreen = CGRect(x: -300, y: -100, width: 314, height: 681)
        let clamped = FloatingPanelLayoutCalculator.clampedPhoneFrame(
            offscreen,
            dockWidth: 68,
            capsuleHeight: 48,
            visibleScreen: visible
        )
        // minX = 0 + 12 + 68 + 8 = 88；minY = 0 + 12 + 48 + 8 = 68。
        XCTAssertEqual(clamped.minX, 88)
        XCTAssertEqual(clamped.minY, 68)
        XCTAssertEqual(clamped.size, offscreen.size)
    }

    func testClampedPhoneFrameLeavesRoomOnTheRightAndTop() {
        let p = CGRect(x: 1400, y: 850, width: 314, height: 681)
        let clamped = FloatingPanelLayoutCalculator.clampedPhoneFrame(
            p,
            dockWidth: 68,
            capsuleHeight: 48,
            visibleScreen: visible
        )
        XCTAssertEqual(clamped.maxX, 1432)
        XCTAssertEqual(clamped.maxY, 892)
        XCTAssertEqual(clamped.size, p.size)
    }

    func testClampedPhoneFrameKeepsPhoneVisibleOnATooNarrowScreen() {
        let narrow = CGRect(x: 0, y: 0, width: 360, height: 900)
        let p = CGRect(x: -500, y: 300, width: 314, height: 681)
        let clamped = FloatingPanelLayoutCalculator.clampedPhoneFrame(
            p,
            dockWidth: 68,
            capsuleHeight: 48,
            visibleScreen: narrow
        )
        // 左侧安全区比剩余宽度还大时，优先让手机留在屏幕里。
        XCTAssertEqual(clamped.minX, 360 - 8 - 314)
    }
}
