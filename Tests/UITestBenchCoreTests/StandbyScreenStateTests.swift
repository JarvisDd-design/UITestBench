import XCTest
@testable import UITestBenchCore

final class StandbyScreenStateTests: XCTestCase {
    private func input(
        isStarting: Bool = false,
        failure: String? = nil,
        hasAPK: Bool = false,
        deviceRunning: Bool = false
    ) -> StandbyScreenInput {
        StandbyScreenInput(
            isStarting: isStarting,
            failure: failure,
            hasAPK: hasAPK,
            deviceRunning: deviceRunning
        )
    }

    func testStartingWins() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(
                input(isStarting: true, failure: "旧错误", hasAPK: true, deviceRunning: false)
            ),
            .starting
        )
    }

    func testFailureWinsRegardlessOfDeviceState() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(failure: "启动失败", deviceRunning: false)),
            .failed("启动失败")
        )
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(failure: "画面组件缺失", deviceRunning: true)),
            .failed("画面组件缺失")
        )
    }

    func testConnectingWinsOverAPK() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(hasAPK: true, deviceRunning: true)),
            .connecting
        )
    }

    func testStartingWinsOverRunningAndFailure() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(
                input(isStarting: true, failure: "旧错误", hasAPK: true, deviceRunning: true)
            ),
            .starting
        )
    }

    func testReadyToStart() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(hasAPK: true, deviceRunning: false)),
            .readyToStart
        )
    }

    func testNeedsAPK() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(hasAPK: false, deviceRunning: false)),
            .needsAPK
        )
    }
}
