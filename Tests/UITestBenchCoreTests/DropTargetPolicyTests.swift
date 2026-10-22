import XCTest
@testable import UITestBenchCore

final class DropTargetPolicyTests: XCTestCase {
    func testAcceptsDropUnlessDeviceRunning() {
        XCTAssertTrue(DropTargetPolicy.acceptsDrop(deviceRunning: false))
        XCTAssertFalse(DropTargetPolicy.acceptsDrop(deviceRunning: true))
    }
}
