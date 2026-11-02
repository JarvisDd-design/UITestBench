import CoreMedia
import CoreVideo
import XCTest
@testable import UITestBenchCore

final class MirrorFrameSlotTests: XCTestCase {
    private func sample(_ pts: Int64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let frame = DecodedFrame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            pts: CMTime(value: pts, timescale: 1_000_000)
        )
        return try VideoSampleBuffer.make(from: frame)
    }

    private func pts(_ sample: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sample)
    }

    func testKeepsOnlyTheLatestFrame() throws {
        let slot = MirrorFrameSlot()
        XCTAssertNil(slot.take())

        XCTAssertFalse(slot.store(try sample(100)))
        XCTAssertTrue(slot.store(try sample(200)))

        let taken = try XCTUnwrap(slot.take())
        XCTAssertEqual(pts(taken.sample), CMTime(value: 200, timescale: 1_000_000))
        XCTAssertNil(slot.take())
    }

    func testCountsOverwrittenFramesAsDropped() throws {
        let slot = MirrorFrameSlot()
        _ = slot.store(try sample(1))
        _ = slot.store(try sample(2))
        _ = slot.store(try sample(3))

        XCTAssertEqual(slot.droppedFrameCount, 2)

        _ = slot.take()
        _ = slot.store(try sample(4))
        XCTAssertEqual(slot.droppedFrameCount, 2, "取走之后再写不算丢帧")

        slot.resetDroppedFrameCount()
        XCTAssertEqual(slot.droppedFrameCount, 0)
    }

    func testTakeClearsAndFlushDoesNotCountAsDrop() throws {
        let slot = MirrorFrameSlot()
        _ = slot.store(try sample(1))
        XCTAssertTrue(slot.isOccupied)

        slot.flush()
        XCTAssertFalse(slot.isOccupied)
        XCTAssertEqual(slot.droppedFrameCount, 0)
    }

    func testKeepsArrivalTimestamp() throws {
        let slot = MirrorFrameSlot()
        _ = slot.store(try sample(1), arrival: 1234.5)
        let taken = try XCTUnwrap(slot.take())
        XCTAssertEqual(taken.arrival, 1234.5)
    }

    func testWaitForEntryReturnsTheFrameAsSoonAsItArrives() throws {
        let slot = MirrorFrameSlot()
        let stored = expectation(description: "写入完成")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            _ = slot.store(try! sample(7), arrival: 99)
            stored.fulfill()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let entry = try XCTUnwrap(slot.waitForEntry(timeout: 2))
        let waited = ProcessInfo.processInfo.systemUptime - started
        wait(for: [stored], timeout: 2)
        XCTAssertEqual(entry.arrival, 99)
        XCTAssertLessThan(waited, 1, "来了帧就该立刻醒，不该等满超时")
        XCTAssertFalse(slot.isOccupied)
    }

    func testWaitForEntryGivesUpAfterTheTimeout() {
        let slot = MirrorFrameSlot()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(slot.waitForEntry(timeout: 0.1))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.09)
    }
}
