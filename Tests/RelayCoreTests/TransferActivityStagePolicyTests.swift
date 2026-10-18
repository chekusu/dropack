import XCTest
@testable import RelayCore

final class TransferActivityStagePolicyTests: XCTestCase {
    private enum Stage: Equatable { case running, paused, finished, failed }
    private func stage(working: Bool = false, priorFailure: Bool = false,
                       finished: Bool = false, needsReset: Bool = false) -> Stage {
        TransferActivityStagePolicy.resolve(isFinished: finished, needsReset: needsReset,
            isWorking: working, hasPriorFailure: priorFailure,
            finished: .finished, failed: .failed, running: .running, paused: .paused)
    }

    func testRetryOfPersistedFailedJobPresentsActualWorkerInsteadOfOldFailure() {
        XCTAssertEqual(stage(priorFailure: true), .failed)
        // The retry is underway while the durable job still says failed.
        XCTAssertEqual(stage(working: true, priorFailure: true), .running)
        XCTAssertEqual(stage(working: true), .running)
        // Backgrounding stops new work even if the durable marker says running.
        XCTAssertEqual(stage(working: false), .paused)
        XCTAssertEqual(stage(working: true), .running)
        XCTAssertEqual(stage(working: true, finished: true), .finished)
    }

    func testCorruptJournalBlocksPresentationAsRunningAndFreshRestoreStaysPaused() {
        XCTAssertEqual(stage(working: true, priorFailure: true, needsReset: true), .failed)
        XCTAssertEqual(stage(), .paused)
        XCTAssertEqual(stage(finished: true), .finished)
    }
}
