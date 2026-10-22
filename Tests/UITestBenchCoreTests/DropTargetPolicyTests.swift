import XCTest
@testable import UITestBenchCore

final class DropTargetPolicyTests: XCTestCase {
    func testAcceptsDropOnlyWhenDeviceStopped() {
        XCTAssertTrue(DropTargetPolicy.acceptsDrop(deviceRunning: false))
        XCTAssertFalse(DropTargetPolicy.acceptsDrop(deviceRunning: true))
    }
}
