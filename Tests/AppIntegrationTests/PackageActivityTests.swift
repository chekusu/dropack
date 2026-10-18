import Combine
import XCTest
@testable import Dropack

@MainActor
final class PackageActivityTests: XCTestCase {
    func testRapidProgressPublishesLatestWholeSnapshotWithoutInvalidatingController() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PackageController(service: PhotoPackageService(root: root))
        try await waitUntil { !controller.isBusy }

        var controllerChanges = 0
        var snapshots: [PackageActivitySnapshot] = []
        let controllerObservation = controller.objectWillChange.sink { controllerChanges += 1 }
        let progressObservation = controller.activity.$snapshot.dropFirst().sink { snapshots.append($0) }
        defer { controllerObservation.cancel(); progressObservation.cancel() }

        let token = UUID()
        controller.activity.begin(token: token, initial: .init(totalCount: 100, stage: "读取原片"))
        for index in 1...150 {
            controller.activity.receive(token: token, completedCount: index / 3, totalCount: 100,
                                        stage: "正在打包", name: "photo-\(index).heic",
                                        fraction: Double(index) / 150)
        }
        XCTAssertEqual(snapshots.count, 1, "A synchronous burst must share one pending publication.")
        try await waitUntil { snapshots.last?.name == "photo-150.heic" }
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last, .init(completedCount: 50, totalCount: 100,
                                            stage: "正在打包", name: "photo-150.heic", fraction: 1))
        XCTAssertEqual(controllerChanges, 0, "Per-resource progress must not invalidate the page/navigation owner.")
    }

    func testPendingCheckpointCountSurvivesResourceOnlyUpdatesAndDuplicateValues() async throws {
        let activity = PackageActivity(interval: .milliseconds(40))
        let token = UUID()
        activity.begin(token: token, initial: .init(completedCount: 2, totalCount: 12, stage: "继续打包"))
        activity.receive(token: token, completedCount: 3, totalCount: 12,
                         stage: "正在打包", name: "", fraction: 1)
        activity.receive(token: token, stage: "读取原片", name: "next.mov", fraction: 0)
        try await waitUntil { activity.snapshot.name == "next.mov" }
        XCTAssertEqual(activity.snapshot.completedCount, 3)
        XCTAssertEqual(activity.snapshot.totalCount, 12)

        var publications = 0
        let observation = activity.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<100 {
            activity.receive(token: token, completedCount: 2, totalCount: 12,
                             stage: "读取原片", name: "next.mov", fraction: 0)
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(publications, 0, "Duplicate and delayed older counts must not create visible updates.")
        XCTAssertEqual(activity.snapshot.completedCount, 3)
    }

    func testFinishCancelsPendingProgressAndPublishesJournalCountsImmediately() async throws {
        let activity = PackageActivity(interval: .milliseconds(60))
        let token = UUID()
        activity.begin(token: token, initial: .init(totalCount: 12, stage: "准备打包"))
        activity.receive(token: token, completedCount: 8, totalCount: 12,
                         stage: "正在打包", name: "old.heic", fraction: 0.5)
        let terminal = PackageActivitySnapshot(completedCount: 12, totalCount: 12)
        activity.finish(token: token, final: terminal)
        XCTAssertEqual(activity.snapshot, terminal)
        activity.receive(token: token, stage: "核对照片包", name: "late.heic", fraction: 0.8)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(activity.snapshot, terminal, "A queued callback must not replace the ready/paused journal state.")
    }

    func testSuspendKeepsConfirmedCountAndRejectsCallbacksUntilJournalFinish() async throws {
        let activity = PackageActivity(interval: .milliseconds(60))
        let token = UUID()
        activity.begin(token: token, initial: .init(completedCount: 4, totalCount: 20, stage: "继续打包"))
        activity.receive(token: token, completedCount: 5, totalCount: 20,
                         stage: "正在打包", name: "", fraction: 1)
        activity.receive(token: token, stage: "读取原片", name: "large.mov", fraction: 0.1)
        activity.suspend(token: token)
        let stopping = activity.snapshot
        XCTAssertEqual(stopping.completedCount, 5, "Pause must preserve a confirmed count still inside the throttle window.")
        activity.receive(token: token, completedCount: 6, totalCount: 20,
                         stage: "从 iCloud 下载", name: "late.mov", fraction: 0.9)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(activity.snapshot, stopping)

        // A transaction may have committed just before cancellation reached it.
        // The durable journal is authoritative after rollback/cleanup completes.
        activity.finish(token: token, final: .init(completedCount: 6, totalCount: 20))
        XCTAssertEqual(activity.snapshot, .init(completedCount: 6, totalCount: 20))
    }

    func testNewOperationAndResetDiscardOldTokenAndNormalizeProgress() async throws {
        let activity = PackageActivity(interval: .milliseconds(60))
        let oldToken = UUID()
        activity.begin(token: oldToken, initial: .init(totalCount: 100, stage: "准备打包"))
        activity.receive(token: oldToken, completedCount: 90, totalCount: 100,
                         stage: "正在打包", name: "old.mov", fraction: 0.8)
        let newToken = UUID()
        let replacement = PackageActivitySnapshot(totalCount: 3, stage: "准备打包")
        activity.begin(token: newToken, initial: replacement)
        activity.finish(token: oldToken, final: .init(completedCount: 100, totalCount: 100))
        activity.receive(token: oldToken, stage: "核对照片包", name: "old.mov", fraction: 1)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(activity.snapshot, replacement)

        activity.receive(token: newToken, completedCount: 20, totalCount: 3,
                         stage: "正在打包", name: "new.mov", fraction: .nan)
        try await waitUntil { activity.snapshot.name == "new.mov" }
        XCTAssertEqual(activity.snapshot.completedCount, 3)
        XCTAssertEqual(activity.snapshot.fraction, 0)
        activity.receive(token: newToken, stage: "正在打包", name: "pending.mov", fraction: 2)
        activity.reset()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(activity.snapshot, PackageActivitySnapshot(), "Clearing/replacing a task must discard pending progress.")
    }

    func testDuplicateFilenamesUseJournalAssetIdentityAndKeepCommittedChecks() async throws {
        let activity = PackageActivity(interval: .milliseconds(30))
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 2, packageID: packageID))
        activity.receive(token: token, completedCount: 1, stage: "正在打包", name: "IMG_0001.HEIC",
            fraction: 1, packageID: packageID, assetID: "camera-A",
            completedAssetIDs: ["camera-A"], sequence: 1)
        activity.receive(token: token, stage: "读取原片", name: "IMG_0001.HEIC",
            fraction: 0.25, packageID: packageID, assetID: "camera-B", sequence: 2)
        try await waitUntil { activity.snapshot.assetID == "camera-B" }
        XCTAssertEqual(activity.snapshot.packageID, packageID)
        XCTAssertEqual(activity.snapshot.name, "IMG_0001.HEIC")
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["camera-A"])
        XCTAssertEqual(activity.snapshot.completedCount, 1)
        XCTAssertEqual(activity.snapshot.fraction, 0.25)
    }

    func testOutOfOrderCheckpointMergesIdentitiesWithoutMovingCurrentAssetBack() async throws {
        let activity = PackageActivity(interval: .milliseconds(30))
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(completedCount: 1, totalCount: 3,
            packageID: packageID, completedAssetIDs: ["first"]))
        // MainActor scheduled the next resource before the preceding checkpoint.
        activity.receive(token: token, stage: "读取原片", name: "same.mov", fraction: 0.3,
            packageID: packageID, assetID: "third", sequence: 30)
        activity.receive(token: token, completedCount: 2, totalCount: 3,
            stage: "正在打包", name: "same.mov", fraction: 1,
            packageID: packageID, assetID: "second", completedAssetIDs: ["first", "second"], sequence: 20)
        activity.receive(token: token, stage: "读取原片", name: "same.mov", fraction: 0.9,
            packageID: packageID, assetID: "second", sequence: 19)
        try await waitUntil { activity.snapshot.completedCount == 2 }
        XCTAssertEqual(activity.snapshot.assetID, "third")
        XCTAssertEqual(activity.snapshot.stage, "读取原片")
        XCTAssertEqual(activity.snapshot.fraction, 0.3)
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["first", "second"])
        activity.receive(token: token, stage: "生成照片包清单", name: "", fraction: 0,
            packageID: packageID, sequence: 40)
        try await waitUntil { activity.snapshot.assetID == nil }
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["first", "second"])
    }

    func testFinishedCheckpointIdentitiesRejectLateCallbacksAndOtherAlbumProgress() async throws {
        let activity = PackageActivity(interval: .milliseconds(30))
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 2, packageID: packageID))
        activity.receive(token: token, stage: "读取原片", name: "correct.mov", fraction: 0.2,
            packageID: packageID, assetID: "correct", sequence: 1)
        activity.receive(token: token, completedCount: 2, totalCount: 2,
            stage: "正在打包", name: "wrong.mov", fraction: 1,
            packageID: UUID(), assetID: "wrong", completedAssetIDs: ["wrong"], sequence: 2)
        try await waitUntil { activity.snapshot.assetID == "correct" }
        XCTAssertTrue(activity.snapshot.completedAssetIDs.isEmpty)
        let final = PackageActivitySnapshot(completedCount: 2, totalCount: 2,
            packageID: packageID, completedAssetIDs: ["correct", "second"])
        activity.finish(token: token, final: final)
        activity.receive(token: token, completedCount: 0, stage: "读取原片", name: "late.mov", fraction: 0.8,
            packageID: packageID, assetID: "late", completedAssetIDs: [], sequence: 99)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(activity.snapshot, final)
        XCTAssertNil(activity.snapshot.assetID)
    }

    func testPauseAndResumeUseAuthoritativeCheckpointIdentities() async throws {
        let activity = PackageActivity(interval: .milliseconds(30))
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 3, packageID: packageID))
        activity.receive(token: token, completedCount: 1, stage: "正在打包", name: "one.mov", fraction: 1,
            packageID: packageID, assetID: "one", completedAssetIDs: ["one"], sequence: 1)
        activity.receive(token: token, stage: "正在打包", name: "two.mov", fraction: 0.5,
            packageID: packageID, assetID: "two", sequence: 2)
        activity.suspend(token: token)
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["one"])
        // The second file committed immediately before cancellation took effect.
        let checkpoint = PackageActivitySnapshot(completedCount: 2, totalCount: 3,
            packageID: packageID, completedAssetIDs: ["one", "two"])
        activity.finish(token: token, final: checkpoint)
        XCTAssertNil(activity.snapshot.assetID)
        let resumedToken = UUID()
        activity.begin(token: resumedToken, initial: checkpoint)
        activity.receive(token: resumedToken, stage: "读取原片", name: "three.mov", fraction: 0.1,
            packageID: packageID, assetID: "three", sequence: 1)
        activity.receive(token: token, stage: "读取原片", name: "stale.mov", fraction: 0.1,
            packageID: packageID, assetID: "stale", sequence: 100)
        try await waitUntil { activity.snapshot.assetID == "three" }
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["one", "two"])
    }

    func testDownloadCompletionCannotCompleteOriginalOrZIP() {
        let activity = PackageActivity(interval: .zero)
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 1, packageID: packageID))
        activity.receive(token: token, stage: "从 iCloud 下载", name: "movie.mov", fraction: 1,
            packageID: packageID, assetID: "movie",
            originalProgress: .init(state: .downloading, fraction: 1), sequence: 1)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["movie"]?.state, .downloading)
        XCTAssertTrue(activity.snapshot.originalProgressByAssetID["movie"]?.cloudConfirmed == true)
        XCTAssertNil(activity.snapshot.packingFraction)
        XCTAssertTrue(activity.snapshot.completedAssetIDs.isEmpty)
        XCTAssertEqual(activity.snapshot.completedCount, 0)
        activity.receive(token: token, stage: "读取原片", name: "movie.mov", fraction: 1,
            packageID: packageID, assetID: "movie",
            originalProgress: .init(state: .ready, cloudConfirmed: true), sequence: 2)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["movie"]?.state, .ready)
        XCTAssertTrue(activity.snapshot.completedAssetIDs.isEmpty)
        // A captured cloud original can next be hashed as an app-owned file.
        // Its current phase changes, but the confirmed source fact remains.
        activity.receive(token: token, stage: "核对文件", name: "movie.mov", fraction: 0.1,
            packageID: packageID, assetID: "movie",
            originalProgress: .init(state: .preparing, fraction: 0.1), sequence: 3)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["movie"]?.state, .preparing)
        XCTAssertTrue(activity.snapshot.originalProgressByAssetID["movie"]?.cloudConfirmed == true)
        activity.receive(token: token, stage: "正在打包", name: "movie.mov", fraction: 0.4,
            packageID: packageID, assetID: "movie", originalProgress: .ready, packingFraction: 0.4, sequence: 4)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["movie"]?.state, .ready)
        XCTAssertEqual(activity.snapshot.packingFraction, 0.4)
        XCTAssertTrue(activity.snapshot.completedAssetIDs.isEmpty)
    }

    func testOriginalCallbacksUsePerItemOrderWithoutRegressingCurrentZIP() {
        let activity = PackageActivity(interval: .zero)
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 2, packageID: packageID))
        activity.receive(token: token, stage: "正在打包", name: "second.mov", fraction: 0.3,
            packageID: packageID, assetID: "second", originalProgress: .ready,
            packingFraction: 0.3, sequence: 30)
        activity.receive(token: token, stage: "读取所选资源", name: "first.mov", fraction: 1,
            packageID: packageID, assetID: "first", originalProgress: .ready, sequence: 20)
        activity.receive(token: token, stage: "从 iCloud 下载", name: "first.mov", fraction: 0.8,
            packageID: packageID, assetID: "first",
            originalProgress: .init(state: .downloading, fraction: 0.8), sequence: 19)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["first"], .ready)
        XCTAssertEqual(activity.snapshot.assetID, "second")
        XCTAssertEqual(activity.snapshot.stage, "正在打包")
        XCTAssertEqual(activity.snapshot.packingFraction, 0.3)
    }

    func testPauseFinishDropsVolatileOriginalStateAndOldCallbacksCannotRestoreIt() {
        let activity = PackageActivity(interval: .zero)
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 1, packageID: packageID))
        activity.receive(token: token, stage: "正在打包", name: "movie.mov", fraction: 0.5,
            packageID: packageID, assetID: "movie", originalProgress: .ready,
            packingFraction: 0.5, sequence: 1)
        activity.suspend(token: token)
        activity.finish(token: token, final: .init(totalCount: 1, packageID: packageID))
        activity.receive(token: token, stage: "从 iCloud 下载", name: "movie.mov", fraction: 1,
            packageID: packageID, assetID: "movie", originalProgress: .ready, sequence: 99)
        XCTAssertTrue(activity.snapshot.originalProgressByAssetID.isEmpty)
        XCTAssertNil(activity.snapshot.packingFraction)
        let resumed = UUID()
        activity.begin(token: resumed, initial: .init(totalCount: 1, packageID: packageID))
        activity.receive(token: resumed, stage: "读取原片", name: "movie.mov", fraction: 0,
            packageID: packageID, assetID: "movie",
            originalProgress: .init(state: .preparing), sequence: 1)
        XCTAssertEqual(activity.snapshot.originalProgressByAssetID["movie"]?.state, .preparing)
        XCTAssertNil(activity.snapshot.packingFraction)
    }

    func testCheckpointPrunesTransientOriginalWhilePreservingPackedIdentity() {
        let activity = PackageActivity(interval: .zero)
        let token = UUID(), packageID = UUID()
        activity.begin(token: token, initial: .init(totalCount: 1, packageID: packageID))
        activity.receive(token: token, stage: "正在打包", name: "movie.mov", fraction: 1,
            packageID: packageID, assetID: "movie", originalProgress: .ready,
            packingFraction: 1, sequence: 1)
        activity.receive(token: token, completedCount: 1, stage: "正在打包", name: "", fraction: 1,
            packageID: packageID, assetID: "movie", completedAssetIDs: ["movie"], sequence: 2)
        activity.receive(token: token, stage: "从 iCloud 下载", name: "movie.mov", fraction: 0.9,
            packageID: packageID, assetID: "movie",
            originalProgress: .init(state: .downloading, fraction: 0.9), sequence: 1)
        XCTAssertTrue(activity.snapshot.originalProgressByAssetID.isEmpty)
        XCTAssertEqual(activity.snapshot.completedAssetIDs, ["movie"])
    }

    func testOriginalAndPackingProgressRejectNonFiniteValues() {
        XCTAssertNil(PackageOriginalProgress(state: .preparing, fraction: .nan).fraction)
        XCTAssertNil(PackageOriginalProgress(state: .downloading, fraction: .infinity).fraction)
        XCTAssertEqual(PackageOriginalProgress(state: .downloading, fraction: 1.5).fraction, 1)
        XCTAssertNil(PackageOriginalProgress(state: .ready, fraction: 0.5).fraction)
        XCTAssertNil(PackageActivitySnapshot(packingFraction: .nan).packingFraction)
        XCTAssertEqual(PackageActivitySnapshot(packingFraction: -1).packingFraction, 0)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for packaging activity")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
