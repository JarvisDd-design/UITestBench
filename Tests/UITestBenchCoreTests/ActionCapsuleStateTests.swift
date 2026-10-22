import XCTest
@testable import UITestBenchCore

final class ActionCapsuleStateTests: XCTestCase {
    private func input(
        hasAPK: Bool,
        deviceRunning: Bool,
        isRunning: Bool = false,
        isBusy: Bool = false,
        busyText: String? = nil
    ) -> ActionCapsuleInput {
        ActionCapsuleInput(
            hasAPK: hasAPK,
            deviceRunning: deviceRunning,
            isRunning: isRunning,
            isBusy: isBusy,
            busyText: busyText
        )
    }

    func testHiddenWithoutDeviceOrAPK() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(input(hasAPK: false, deviceRunning: false)),
            .hidden
        )
    }

    func testWaitingForDeviceWhenAPKLoadedButDeviceStopped() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(input(hasAPK: true, deviceRunning: false)),
            .waitingForDevice
        )
    }

    func testReadyToRun() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(input(hasAPK: true, deviceRunning: true)),
            .readyToRun
        )
    }

    func testRunningWinsOverReady() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: true, deviceRunning: true, isRunning: true)
            ),
            .running
        )
    }

    func testScreenshotOnlyWhenDeviceRunsWithoutAPK() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(input(hasAPK: false, deviceRunning: true)),
            .screenshotOnly
        )
    }

    func testBusyCarriesStatus() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: true, deviceRunning: true, isBusy: true, busyText: "正在安装…")
            ),
            .busy("正在安装…")
        )
    }

    func testBusyWithoutStatusUsesFallback() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: true, deviceRunning: true, isBusy: true)
            ),
            .busy("正在处理…")
        )
    }

    func testBusyWinsOverWaitingForDevice() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: true, deviceRunning: false, isBusy: true, busyText: "正在安装…")
            ),
            .busy("正在安装…")
        )
    }

    func testBusyWinsOverHidden() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: false, deviceRunning: false, isBusy: true)
            ),
            .busy("正在处理…")
        )
    }

    func testBusyWinsOverRunning() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(
                    hasAPK: true,
                    deviceRunning: true,
                    isRunning: true,
                    isBusy: true,
                    busyText: "正在重开…"
                )
            ),
            .busy("正在重开…")
        )
    }

    func testBusyTextAloneDoesNotForceBusy() {
        XCTAssertEqual(
            ActionCapsuleResolver.resolve(
                input(hasAPK: true, deviceRunning: true, busyText: "上次运行失败")
            ),
            .readyToRun
        )
    }
}
