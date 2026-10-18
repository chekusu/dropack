import Foundation
import XCTest
@testable import RelayCore

final class CancellableCallbackOperationTests: XCTestCase {
    func testCancellationBeforeAwaitDoesNotStartRequest() async {
        let finalized = LockedCounter()
        let operation = CancellableCallbackOperation<Int> { result in finalized.increment(); return result }
        operation.cancel()
        operation.cancel()
        do { _ = try await operation.wait { XCTFail("Cancelled operation must not start") }; XCTFail("Must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(finalized.value, 1)
    }

    func testTaskCancellationCompletesWithoutFrameworkCompletion() async {
        let started = expectation(description: "Request started")
        let completed = expectation(description: "Await returned")
        let terminated = LockedCounter()
        let operation = CancellableCallbackOperation<Int>()
        let task = Task {
            do {
                _ = try await operation.wait {
                    operation.registerTermination { terminated.increment() }
                    started.fulfill()
                    // A suspended framework never invokes completion.
                }
                XCTFail("Must cancel")
            } catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [completed], timeout: 1)
        operation.cancel()
        XCTAssertEqual(terminated.value, 1)
    }

    func testCancellationBeforeRequestHandleRegistrationTerminatesLateHandle() async {
        let started = expectation(description: "Start has not returned handle yet")
        let completed = expectation(description: "Await returned")
        let release = DispatchSemaphore(value: 0)
        let terminated = LockedCounter()
        let operation = CancellableCallbackOperation<Int>()
        let task = Task.detached {
            do {
                _ = try await operation.wait {
                    started.fulfill()
                    release.wait()
                    operation.registerTermination { terminated.increment() }
                }
                XCTFail("Must cancel")
            } catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        release.signal()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(terminated.value, 1)
    }

    func testLateAndDuplicateCallbacksCannotWriteOrResumeAgain() async {
        let writes = LockedCounter()
        let finalized = LockedCounter()
        let operation = CancellableCallbackOperation<Int> { result in finalized.increment(); return result }
        operation.cancel()
        operation.process { writes.increment() }
        operation.complete { writes.increment(); return 42 }
        operation.finish(.success(42))
        operation.cancel()
        do { _ = try await operation.wait {}; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(finalized.value, 1)
    }

    func testCancellationWaitsForActiveCopyBeforeCleanupAndNextWorker() async {
        let started = expectation(description: "Registered")
        let copying = expectation(description: "Provider copy running")
        let returned = expectation(description: "Operation returned")
        let release = DispatchSemaphore(value: 0)
        let copyExited = LockedCounter()
        let cleanup = LockedCounter()
        let operation = CancellableCallbackOperation<Int> { result in
            XCTAssertEqual(copyExited.value, 1, "Cleanup cannot race the accepted callback")
            cleanup.increment()
            return result
        }
        let task = Task {
            do { _ = try await operation.wait { started.fulfill() }; XCTFail("Must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(copyExited.value, 1)
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        DispatchQueue.global().async {
            operation.complete {
                copying.fulfill()
                release.wait()
                XCTAssertTrue(operation.isCancelled)
                copyExited.increment()
                return 42
            }
        }
        await fulfillment(of: [copying], timeout: 1)
        task.cancel()
        operation.cancel()
        XCTAssertEqual(cleanup.value, 0, "Cancellation cannot finalize an active writer")
        operation.complete { XCTFail("Duplicate provider callback must be ignored"); return 99 }
        release.signal()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(cleanup.value, 1)
    }

    func testStreamingFailureFinalizesWithoutCompletionAndRejectsLateChunk() async {
        let finalized = LockedCounter()
        let terminated = LockedCounter()
        let writes = LockedCounter()
        let operation = CancellableCallbackOperation<Void> { result in finalized.increment(); return result }
        enum WriteFailure: Error { case disk }
        do {
            try await operation.wait {
                operation.registerTermination { terminated.increment() }
                operation.process { writes.increment(); throw WriteFailure.disk }
                operation.process { XCTFail("Late chunk after disk failure"); writes.increment() }
            }
            XCTFail("Must fail")
        } catch { XCTAssertTrue(error is WriteFailure) }
        operation.finish(.success(()))
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(finalized.value, 1)
        XCTAssertEqual(terminated.value, 1)
    }

    func testLastChunkFailureWinsOverConcurrentSuccessCompletion() async {
        enum WriteFailure: Error { case disk }
        let operation = CancellableCallbackOperation<Void>()
        do {
            try await operation.wait {
                operation.process {
                    operation.finish(.success(()))
                    throw WriteFailure.disk
                }
            }
            XCTFail("A successful provider callback cannot hide a failed write")
        } catch { XCTAssertTrue(error is WriteFailure) }
    }

    func testSynchronousCompletionBeforeHandleRegistrationResumesExactlyOnce() async throws {
        let terminated = LockedCounter()
        let transformed = LockedCounter()
        let operation = CancellableCallbackOperation<Int>()
        let value = try await operation.wait {
            operation.complete { transformed.increment(); return 42 }
            operation.complete { transformed.increment(); return 99 }
            operation.registerTermination { terminated.increment() }
        }
        operation.cancel()
        XCTAssertEqual(value, 42)
        XCTAssertEqual(transformed.value, 1)
        XCTAssertEqual(terminated.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}
