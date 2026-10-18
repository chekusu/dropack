import XCTest
@testable import RelayCore

final class TransferActivityUpdateBufferTests: XCTestCase {
    func testContinuousBurstKeepsFixedDeadlineAndDeliversLatestValue() {
        var buffer = TransferActivityUpdateBuffer<Int>(interval: 1)
        buffer.enqueue(0)
        XCTAssertEqual(buffer.take(at: 0), 0)
        for update in 1...999 {
            let now = Double(update) / 1_000
            buffer.enqueue(update)
            XCTAssertNil(buffer.take(at: now))
            XCTAssertEqual(buffer.delay(at: now)!, 1 - now, accuracy: 0.000001)
        }
        XCTAssertEqual(buffer.take(at: 1), 999)
        XCTAssertNil(buffer.take(at: 2), "A delivered value must not be replayed as another update.")
    }

    func testTerminalStateReplacesQueuedProgressWithoutWaitingForThrottle() {
        var buffer = TransferActivityUpdateBuffer<String>(interval: 1)
        buffer.enqueue("running 1/10")
        XCTAssertEqual(buffer.take(at: 0), "running 1/10")
        buffer.enqueue("running 5/10")
        buffer.enqueue("finished 10/10", urgent: true)
        XCTAssertEqual(buffer.take(at: 0.01), "finished 10/10")
        XCTAssertNil(buffer.take(at: 1), "Queued progress must not overwrite the terminal result later.")
    }

    func testIdenticalSnapshotsDoNotSpendUpdatesButHeartbeatMayRefreshStaleness() {
        var buffer = TransferActivityUpdateBuffer<Int>(interval: 1)
        buffer.enqueue(3)
        XCTAssertEqual(buffer.take(at: 10), 3)
        for _ in 0..<1_000 { buffer.enqueue(3) }
        XCTAssertNil(buffer.delay(at: 40))
        buffer.enqueue(3, force: true)
        XCTAssertEqual(buffer.take(at: 40), 3)
    }

    func testPauseFollowedByExplicitResumeBeforeDeliveryKeepsLatestState() {
        var buffer = TransferActivityUpdateBuffer<String>(interval: 1)
        buffer.enqueue("running")
        XCTAssertEqual(buffer.take(at: 0), "running")
        buffer.enqueue("paused", urgent: true)
        buffer.enqueue("running again")
        XCTAssertEqual(buffer.take(at: 0.1), "running again")
        XCTAssertNil(buffer.take(at: 2))
    }
}
