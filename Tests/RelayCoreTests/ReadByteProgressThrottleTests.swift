import XCTest
@testable import RelayCore

final class ReadByteProgressThrottleTests: XCTestCase {
    func testFirstChunkReportsImmediatelyThenAtMostEveryTenthSecond() {
        var throttle = ReadByteProgressThrottle()
        XCTAssertEqual(throttle.update(readBytes: 1_048_576, now: 0), 1_048_576)
        XCTAssertNil(throttle.update(readBytes: 2_097_152, now: 0.03))
        XCTAssertNil(throttle.update(readBytes: 3_145_728, now: 0.09))
        XCTAssertEqual(throttle.update(readBytes: 4_194_304, now: 0.1), 4_194_304)
    }

    func testFinalFlushReportsExactBytesInsideThrottleWindowOnlyOnce() {
        var throttle = ReadByteProgressThrottle()
        _ = throttle.update(readBytes: 1_048_576, now: 50)
        XCTAssertEqual(throttle.update(readBytes: 1_048_593, now: 50.001, force: true), 1_048_593)
        XCTAssertNil(throttle.update(readBytes: 1_048_593, now: 50.002, force: true))
    }

    func testDuplicateOrOutOfOrderCountsCannotMoveProgressBackwards() {
        var throttle = ReadByteProgressThrottle()
        _ = throttle.update(readBytes: 3_000_000, now: 1)
        XCTAssertNil(throttle.update(readBytes: 2_000_000, now: 2, force: true))
        XCTAssertNil(throttle.update(readBytes: 3_000_000, now: 3))
        XCTAssertEqual(throttle.update(readBytes: 4_000_000, now: 4), 4_000_000)
    }

    func testLargeStreamKeepsUInt64PrecisionWithoutInferringTotal() {
        var throttle = ReadByteProgressThrottle()
        let bytes: UInt64 = 30 * 1024 * 1024 * 1024 + 13
        XCTAssertEqual(throttle.update(readBytes: bytes, now: 0), bytes)
        XCTAssertEqual(throttle.update(readBytes: UInt64.max, now: 1, force: true), UInt64.max)
    }
}
