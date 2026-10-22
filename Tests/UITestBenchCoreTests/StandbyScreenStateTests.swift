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

    func testFailureOnlyWhenDeviceStopped() {
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(failure: "启动失败", deviceRunning: false)),
            .failed("启动失败")
        )
        XCTAssertEqual(
            StandbyScreenStateResolver.resolve(input(failure: "旧错误", deviceRunning: true)),
            .connecting
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
