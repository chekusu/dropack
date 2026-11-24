import XCTest
@testable import RelayCore

final class ReviewPromptPolicyTests: XCTestCase {
    func testAsksOnceForEachVersionAfterSavingSomethingNew() {
        XCTAssertTrue(ReviewPromptPolicy.shouldRequest(newlySavedCount: 1, appVersion: "1.0.3", lastRequestedVersion: nil))
        XCTAssertTrue(ReviewPromptPolicy.shouldRequest(newlySavedCount: 240, appVersion: "1.0.3", lastRequestedVersion: ""))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: 3, appVersion: "1.0.3", lastRequestedVersion: "1.0.3"))
        XCTAssertTrue(ReviewPromptPolicy.shouldRequest(newlySavedCount: 3, appVersion: "1.1", lastRequestedVersion: "1.0.3"))
    }

    func testDelayedCompletionRequiresTheSameVisibleJob() {
        var job = ImportJob(source: .init(kind: .zip, name: "photos.zip", bookmark: Data()), items: [])
        job.phase = .completed
        XCTAssertTrue(ReviewPromptPolicy.isShowingCompletion(job: job, finishedID: job.id, detailID: job.id))
        XCTAssertFalse(ReviewPromptPolicy.isShowingCompletion(job: job, finishedID: job.id, detailID: nil))
        XCTAssertFalse(ReviewPromptPolicy.isShowingCompletion(job: nil, finishedID: job.id, detailID: nil))
        XCTAssertFalse(ReviewPromptPolicy.isShowingCompletion(job: job, finishedID: UUID(), detailID: job.id))
    }

    func testNeverAsksWhenNothingNewWasSaved() {
        // An import whose items were all skipped as already imported is not a
        // finished task worth a rating prompt.
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: 0, appVersion: "1.0.3", lastRequestedVersion: nil))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: -1, appVersion: "1.0.3", lastRequestedVersion: nil))
    }

    func testMissingVersionNeverAsksAndWhitespaceDoesNotCountAsANewVersion() {
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: 5, appVersion: nil, lastRequestedVersion: nil))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: 5, appVersion: "  ", lastRequestedVersion: nil))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequest(newlySavedCount: 5, appVersion: "1.0.3 ", lastRequestedVersion: "1.0.3"))
    }
}
