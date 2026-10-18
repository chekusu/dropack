import XCTest
@testable import RelayCore

final class TransferActivityLifecyclePolicyTests: XCTestCase {
    func testRunningToBackgroundPauseRetainsNativeActivityUntilFinished() {
        var policy = TransferActivityLifecyclePolicy()
        XCTAssertTrue(policy.accept(isWorking: true))
        XCTAssertEqual(policy.action(mode: .working, hasActivity: false, activitiesEnabled: true), .request)
        XCTAssertEqual(policy.action(mode: .working, hasActivity: true, activitiesEnabled: true), .update)
        XCTAssertTrue(policy.accept(isWorking: false))
        XCTAssertEqual(policy.action(mode: .paused, hasActivity: true, activitiesEnabled: true), .update)
        XCTAssertTrue(policy.accept(isWorking: true))
        XCTAssertEqual(policy.action(mode: .working, hasActivity: true, activitiesEnabled: true), .update)
        XCTAssertEqual(policy.action(mode: .terminal, hasActivity: true, activitiesEnabled: true), .end)
    }

    func testLibraryReselectDoesNotResurrectButActualResumeCanStartSameJob() {
        var policy = TransferActivityLifecyclePolicy()
        policy.clear()
        XCTAssertEqual(policy.action(mode: .paused, hasActivity: true, activitiesEnabled: true), .end)
        XCTAssertFalse(policy.accept(isWorking: false))
        XCTAssertEqual(policy.action(mode: .paused, hasActivity: false, activitiesEnabled: true), .none)
        XCTAssertTrue(policy.accept(isWorking: true))
        XCTAssertEqual(policy.action(mode: .working, hasActivity: false, activitiesEnabled: true), .request)
    }

    func testUserDismissalStaysSuppressedAcrossClearAndSameJobResume() {
        var policy = TransferActivityLifecyclePolicy()
        policy.suppress()
        policy.clear()
        XCTAssertTrue(policy.accept(isWorking: true))
        XCTAssertEqual(policy.action(mode: .working, hasActivity: false, activitiesEnabled: true), .none)
        let freshTask = TransferActivityLifecyclePolicy()
        XCTAssertEqual(freshTask.action(mode: .working, hasActivity: false, activitiesEnabled: true), .request)
    }

    func testPermissionOffEndsExistingAndPausedCannotCreateNewActivity() {
        let policy = TransferActivityLifecyclePolicy()
        XCTAssertEqual(policy.action(mode: .working, hasActivity: true, activitiesEnabled: false), .end)
        XCTAssertEqual(policy.action(mode: .working, hasActivity: false, activitiesEnabled: false), .none)
        XCTAssertEqual(policy.action(mode: .paused, hasActivity: false, activitiesEnabled: true), .none)
        XCTAssertEqual(policy.action(mode: .working, hasActivity: false, activitiesEnabled: true), .request)
    }
}
