import XCTest
@testable import UITestBenchCore

/// 滚轮 → 轮齿。触控板给的是像素级增量，总要攒够一格才发一条控制消息；
/// 不然一次轻扫会轰出几十条消息，设备那边卡成幻灯片。
final class ScrollNotchAccumulatorTests: XCTestCase {
    private var accumulator = ScrollNotchAccumulator()

    /// 精确增量（触控板）：攒满一格才出一个轮齿。
    func testPreciseDeltasAccumulateIntoNotches() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: step / 2, isPrecise: true), 0)
        XCTAssertEqual(accumulator.notches(delta: step / 2, isPrecise: true), 1)
    }

    /// 一次滑动超过好几格时不能只算一格，剩下的也不能丢。
    func testLargePreciseDeltaYieldsMultipleNotchesAndKeepsRemainder() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: step * 3.5, isPrecise: true), 3)
        XCTAssertEqual(accumulator.notches(delta: step * 0.5, isPrecise: true), 1, "上次剩下的半格要接着攒")
    }

    /// 方向反转时要先把攒着的反向余量抵掉，不能「攒了 20 又退了 20 还发出 1 格」。
    func testDirectionReversalCancelsPendingRemainder() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: step * 0.6, isPrecise: true), 0)
        XCTAssertEqual(accumulator.notches(delta: -step * 0.6, isPrecise: true), 0, "退回去刚好抵消")
        XCTAssertEqual(accumulator.notches(delta: -step, isPrecise: true), -1)
    }

    /// 非精确增量（普通鼠标）本来就是整格，直接照搬。
    func testNonPreciseDeltasPassThrough() {
        XCTAssertEqual(accumulator.notches(delta: 3, isPrecise: false), 3)
        XCTAssertEqual(accumulator.notches(delta: -2, isPrecise: false), -2)
    }

    /// 像素级的小抖动不该产生噪声事件。
    func testTinyPreciseDeltasStayBelowOneNotch() {
        XCTAssertEqual(accumulator.notches(delta: 1, isPrecise: true), 0)
        XCTAssertEqual(accumulator.notches(delta: -2, isPrecise: true), 0)
    }

    /// 慢慢滚、每次都不满一格，如果一直等到攒满才动，用户会以为「滚不动」。
    /// 手停下来后把攒到的零头放出去，至少滚一格。
    func testFlushReleasesTheRemainderWhenTheUserStops() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: step * 0.3, isPrecise: true), 0)
        XCTAssertEqual(accumulator.flush(), 1, "停下时不足一格的位移也要滚一点点")
        XCTAssertEqual(accumulator.flush(), 0, "放出去之后不能重复发")
    }

    /// 零头的方向不能丢：往上攒的零头放出去还是往上。
    func testFlushKeepsTheDirection() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: -step * 0.3, isPrecise: true), 0)
        XCTAssertEqual(accumulator.flush(), -1)
    }

    /// 一两个点的抖动不是滚动，停下也不该发。
    func testFlushIgnoresNoise() {
        XCTAssertEqual(accumulator.notches(delta: 1, isPrecise: true), 0)
        XCTAssertEqual(accumulator.flush(), 0)
    }

    /// 已经放出去两格，剩下的半格在停下时也要放出去，不能吞掉。
    func testFlushReleasesAWholeNotchRemainderToo() {
        let step = ScrollNotchAccumulator.pointsPerNotch

        XCTAssertEqual(accumulator.notches(delta: step * 2.5, isPrecise: true), 2)
        XCTAssertEqual(accumulator.flush(), 1)
    }
}
