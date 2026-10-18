import UIKit
import XCTest
@testable import Dropack

@MainActor
final class PackageBackgroundLifecycleTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("photo.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: source)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testEnteringBackgroundDoesNotCancelPackaging() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let createdID = await controller.create(fileURLs: [source])
        let id = try XCTUnwrap(createdID)
        _ = await controller.shareURL(packageID: id) { _ in
            controller.sceneDidEnterBackground()
            XCTAssertTrue(controller.canPause, "Background entry must leave the worker running.")
            XCTAssertFalse(controller.isPauseRequested)
        }
        XCTAssertNotNil(id)
        XCTAssertEqual(controller.job?.phase, .ready)
        XCTAssertNotNil(controller.archiveURL)
        XCTAssertEqual(execution.backgroundEntries, 1)
        XCTAssertEqual(execution.completions, [true])
    }

    func testTimeBudgetPauseFinishesThenResumesOnceOnForeground() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let createdID = await controller.create(fileURLs: [source])
        let id = try XCTUnwrap(createdID)
        _ = await controller.shareURL(packageID: id) { _ in
            controller.sceneDidEnterBackground()
            execution.expire(.timeLimit)
            XCTAssertTrue(controller.isPauseRequested)
            XCTAssertFalse(controller.canResume, "Never start a second ZIP writer before cancellation unwinds.")
        }
        XCTAssertNotNil(id)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.canResume)
        XCTAssertEqual(execution.completions, [false])
        let staleExpiration = execution.expire
        execution.onNextBegin = {
            staleExpiration(.systemCancelled)
            XCTAssertFalse(controller.isPauseRequested, "A late callback from the first attempt cannot cancel its successor.")
        }
        controller.sceneDidBecomeActive()
        try await waitUntil { !controller.isBusy && controller.archiveURL != nil }
        XCTAssertEqual(controller.job?.id, id)
        XCTAssertEqual(controller.job?.phase, .ready)
        XCTAssertEqual(execution.beginCount, 2)
        XCTAssertEqual(execution.completions, [false, true])
        XCTAssertEqual(execution.userInitiatedAttempts, [true, false])
        controller.sceneDidBecomeActive()
        XCTAssertEqual(execution.beginCount, 2)
    }

    func testManualPauseRemainsPausedOnForegroundAndCanResume() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let createdID = await controller.create(fileURLs: [source])
        let id = try XCTUnwrap(createdID)
        _ = await controller.shareURL(packageID: id) { _ in
            controller.sceneDidEnterBackground()
            controller.pause()
            execution.expire(.timeLimit) // An expiring lease cannot undo a manual pause.
            controller.pause()
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isPauseRequested)
        controller.sceneDidBecomeActive()
        XCTAssertTrue(controller.canResume)
        XCTAssertEqual(execution.beginCount, 1)
        controller.resume()
        try await waitUntil { !controller.isBusy && controller.archiveURL != nil }
        XCTAssertEqual(execution.beginCount, 2)
    }

    func testSystemStopDoesNotAutoResumeAndCannotOverwriteNewPresentation() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let createdID = await controller.create(fileURLs: [source])
        let id = try XCTUnwrap(createdID)
        _ = await controller.shareURL(packageID: id) { _ in
            execution.systemProgress(true)
            XCTAssertTrue(controller.usesSystemBackgroundProgress)
            controller.sceneDidEnterBackground()
            execution.expire(.systemCancelled)
        }
        XCTAssertFalse(controller.usesSystemBackgroundProgress)
        controller.sceneDidBecomeActive()
        XCTAssertTrue(controller.canResume)
        XCTAssertEqual(execution.beginCount, 1)
        let stalePresentation = execution.systemProgress
        execution.onNextBegin = {
            execution.systemProgress(true)
            stalePresentation(false)
            XCTAssertTrue(controller.usesSystemBackgroundProgress)
        }
        controller.resume()
        try await waitUntil { !controller.isBusy && controller.archiveURL != nil }
        XCTAssertFalse(controller.usesSystemBackgroundProgress)
    }

    func testExpirationBeforeNewJournalExistsNeverResumesPreviousAlbum() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let createdID = await controller.create(fileURLs: [source])
        let previousID = try XCTUnwrap(createdID)
        _ = await controller.shareURL(packageID: previousID) { _ in controller.pause() }
        XCTAssertTrue(controller.canResume)
        execution.onNextBegin = {
            controller.sceneDidEnterBackground()
            Task { @MainActor in execution.expire(.timeLimit) }
        }
        let missing = root.appendingPathComponent("missing.mov")
        let newID = await controller.create(fileURLs: [missing])
        XCTAssertNil(newID)
        controller.sceneDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.job?.id, previousID)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(execution.beginCount, 1, "A failed metadata selection starts no background task and cannot restart an old album.")
        XCTAssertNil(controller.archiveURL)
    }

    func testDraftEditsStartNoBackgroundWorkUntilShare() async throws {
        let execution = FakePackageBackgroundExecution()
        let controller = try await makeController(execution)
        let created = await controller.create(fileURLs: [source])
        let id = try XCTUnwrap(created)
        XCTAssertTrue(controller.job?.isDraft == true)
        XCTAssertFalse(controller.canResume)
        XCTAssertNil(controller.archiveURL)
        XCTAssertEqual(execution.beginCount, 0)
        let renamed = await controller.rename(packageID: id, title: "Edited album")
        XCTAssertTrue(renamed)
        let renamedID = try XCTUnwrap(controller.job?.id)
        let refreshed = await controller.refreshAlbum(packageID: renamedID)
        let currentID = try XCTUnwrap(refreshed)
        XCTAssertTrue(controller.job?.isDraft == true)
        XCTAssertEqual(execution.beginCount, 0)
        let url = await controller.shareURL(packageID: currentID)
        XCTAssertNotNil(url)
        XCTAssertEqual(controller.job?.phase, .ready)
        XCTAssertEqual(execution.beginCount, 1)
        XCTAssertEqual(execution.completions, [true])
    }

    private func makeController(_ execution: FakePackageBackgroundExecution) async throws -> PackageController {
        let controller = PackageController(service: PhotoPackageService(root: root.appendingPathComponent("Packages")),
                                           backgroundExecution: execution)
        try await waitUntil { !controller.isBusy }
        return controller
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Packaging did not reach a recoverable terminal state"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class FakePackageBackgroundExecution: PackageBackgroundManaging {
    var beginCount = 0
    var userInitiatedAttempts: [Bool] = []
    var backgroundEntries = 0
    var completions: [Bool] = []
    var expire: @MainActor (PackageBackgroundExpirationReason) -> Void = { _ in }
    var systemProgress: @MainActor (Bool) -> Void = { _ in }
    var onNextBegin: (() -> Void)?
    func begin(token: UUID, userInitiated: Bool, onExpiration: @escaping @MainActor (PackageBackgroundExpirationReason) -> Void,
               onSystemProgress: @escaping @MainActor (Bool) -> Void) {
        beginCount += 1; userInitiatedAttempts.append(userInitiated); expire = onExpiration; systemProgress = onSystemProgress
        let action = onNextBegin; onNextBegin = nil; action?()
    }
    func update(_ snapshot: PackageActivitySnapshot) {}
    func finish(success: Bool) { completions.append(success); systemProgress(false) }
    func sceneDidEnterBackground() { backgroundEntries += 1 }
    func sceneDidBecomeActive() {}
}
