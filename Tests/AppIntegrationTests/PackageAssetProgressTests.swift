import XCTest
@testable import Dropack

@MainActor
final class PackageAssetProgressTests: XCTestCase {
    func testSameFilenameAndAnotherAlbumNeverBorrowOriginalOrPackingProgress() {
        let id = UUID()
        var first = PackageAsset(assetIdentifier: "first")
        var second = PackageAsset(assetIdentifier: "second")
        first.title = "original.mov"; second.title = "original.mov"
        let snapshot = PackageActivitySnapshot(totalCount: 2, stage: "读取所选资源",
            name: "original.mov", fraction: 0.8, packageID: id, assetID: second.id,
            originalProgressByAssetID: [second.id: .init(state: .downloading, fraction: 0.42, cloudConfirmed: true)])
        XCTAssertEqual(present(snapshot, id, first).original.state, .unknown)
        XCTAssertEqual(present(snapshot, id, first).state, .waiting)
        XCTAssertEqual(present(snapshot, id, second).originalPercentage, 42)
        XCTAssertNil(present(snapshot, id, second).percentage)
        let unrelated = present(snapshot, UUID(), second)
        XCTAssertEqual(unrelated.original.state, .unknown)
        XCTAssertEqual(unrelated.state, .waiting)
        XCTAssertFalse(unrelated.originalUsesCloud)
    }

    func testCloudDownloadHundredPercentIsNotReadyOrPackaged() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "cloud-video")
        let downloaded = PackageActivitySnapshot(totalCount: 1, stage: "读取原片",
            packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .init(state: .downloading, fraction: 1, cloudConfirmed: true)])
        let presentation = present(downloaded, id, asset)
        XCTAssertEqual(presentation.original.state, .downloading)
        XCTAssertEqual(presentation.originalPercentage, 100)
        XCTAssertTrue(presentation.originalUsesCloud)
        XCTAssertEqual(presentation.state, .waiting)
        XCTAssertNil(presentation.percentage)

        let ready = PackageActivitySnapshot(totalCount: 1, stage: "核对文件", fraction: 1,
            packageID: id, assetID: asset.id, originalProgressByAssetID: [asset.id: .ready])
        XCTAssertEqual(present(ready, id, asset).original.state, .ready)
        XCTAssertNil(present(ready, id, asset).originalPercentage)
        XCTAssertEqual(present(ready, id, asset).state, .waiting,
            "Preparing/hash progress must not advance the separate packaging indicator.")
    }

    func testProviderPreparationNeverClaimsAnICloudDownload() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "private-picker")
        let snapshot = PackageActivitySnapshot(totalCount: 1, stage: "读取所选资源", fraction: 0.7,
            packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .init(state: .preparing, fraction: 0.35)])
        let presentation = present(snapshot, id, asset)
        XCTAssertEqual(presentation.original.state, .preparing)
        XCTAssertEqual(presentation.originalPercentage, 35)
        XCTAssertFalse(presentation.originalUsesCloud)
        XCTAssertFalse(presentation.originalStage.contains("iCloud"))
        XCTAssertEqual(presentation.state, .waiting)
    }

    func testOriginalReadyAndZipProgressStayIndependentUntilDurableCommit() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "live-photo")
        var snapshot = PackageActivitySnapshot(totalCount: 1, stage: "核对实况视频",
            name: "original.mov", fraction: 1, packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .ready], packingFraction: 0.23)
        XCTAssertEqual(present(snapshot, id, asset).original.state, .ready)
        XCTAssertEqual(present(snapshot, id, asset).state, .running)
        XCTAssertEqual(present(snapshot, id, asset).percentage, 23)
        snapshot = PackageActivitySnapshot(totalCount: 1, stage: "正在打包", fraction: 1,
            packageID: id, assetID: asset.id, originalProgressByAssetID: [asset.id: .ready], packingFraction: 1)
        XCTAssertEqual(present(snapshot, id, asset).state, .running,
            "Even 100% ZIP resource output is not a complete Live Photo until all resources commit.")
        snapshot = PackageActivitySnapshot(completedCount: 1, totalCount: 1,
            stage: "核对照片包", packageID: id, completedAssetIDs: [asset.id])
        XCTAssertEqual(present(snapshot, id, asset).state, .completed)
        XCTAssertEqual(present(snapshot, id, asset).original.state, .ready)
    }

    func testNewItemKeepsPriorCommittedCheckmarkWithoutRefreshingAlbumJob() {
        let id = UUID(), first = PackageAsset(assetIdentifier: "first"), second = PackageAsset(assetIdentifier: "second")
        let snapshot = PackageActivitySnapshot(completedCount: 1, totalCount: 2,
            stage: "正在打包", name: "original.mov", fraction: 0.9,
            packageID: id, assetID: second.id, completedAssetIDs: [first.id], packingFraction: 0.2)
        XCTAssertFalse(first.isCompleted)
        XCTAssertEqual(present(snapshot, id, first).state, .completed)
        XCTAssertEqual(present(snapshot, id, first).original.state, .ready)
        XCTAssertEqual(present(snapshot, id, second).percentage, 20)
    }

    func testReadBytesWithoutTotalNeverBecomeDownloadOrPackingPercentage() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "large-video")
        let snapshot = PackageActivitySnapshot(totalCount: 1, stage: "读取原片",
            name: "original.mov", fraction: 0.7, readBytes: 800_000_000,
            packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .init(state: .preparing)])
        let presentation = present(snapshot, id, asset)
        XCTAssertNil(presentation.originalPercentage)
        XCTAssertNil(presentation.percentage)
        XCTAssertFalse(presentation.originalUsesCloud)
        XCTAssertEqual(presentation.state, .waiting)
    }

    func testPauseDropsVolatileDownloadAndUncommittedZipPercent() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "large-video")
        let snapshot = PackageActivitySnapshot(totalCount: 1, stage: "正在打包",
            packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .init(state: .downloading, fraction: 0.72, cloudConfirmed: true)],
            packingFraction: 0.42)
        let paused = PackageAssetProgressPresentation(snapshot: snapshot, packageID: id,
            asset: asset, isBusy: false, pauseRequested: false, phase: .paused)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.fraction)
        XCTAssertEqual(paused.original.state, .unknown)
        XCTAssertNil(paused.originalPercentage)
        XCTAssertFalse(paused.originalUsesCloud)
        let pausing = PackageAssetProgressPresentation(snapshot: snapshot, packageID: id,
            asset: asset, isBusy: true, pauseRequested: true, phase: .packing)
        XCTAssertEqual(pausing.state, .pausing)
        XCTAssertNil(pausing.fraction)
        XCTAssertNil(pausing.originalPercentage)
    }

    func testStaleReadyStagingFileCannotSurviveCompletedPause() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "temporary-staging")
        let snapshot = PackageActivitySnapshot(totalCount: 1, stage: "正在打包",
            packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .ready], packingFraction: 0.42)
        let pausing = PackageAssetProgressPresentation(snapshot: snapshot, packageID: id,
            asset: asset, isBusy: true, pauseRequested: true, phase: .packing)
        XCTAssertEqual(pausing.original.state, .ready,
            "The positively confirmed file may exist until cleanup actually finishes.")
        let paused = PackageAssetProgressPresentation(snapshot: snapshot, packageID: id,
            asset: asset, isBusy: false, pauseRequested: false, phase: .paused)
        XCTAssertEqual(paused.original.state, .unknown,
            "The staging path is transient and cannot prove availability after rollback.")
        XCTAssertNil(paused.originalPercentage)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.percentage)
    }

    func testOnlyDurablyCapturedPickerFileProvesReadinessAfterRelaunch() {
        let id = UUID()
        var captured = PackageAsset(assetIdentifier: "picker"), external = PackageAsset(assetIdentifier: "file")
        let file = PackageFileSource(bookmark: Data(), relativePath: "original.mov", isFolder: false,
            byteCount: 100, modifiedAt: nil)
        captured.fileSource = file; captured.pickerResourcePending = false
        external.fileSource = file
        let snapshot = PackageActivitySnapshot(packageID: id)
        let restored = PackageAssetProgressPresentation(snapshot: snapshot, packageID: id,
            asset: captured, isBusy: false, pauseRequested: false, phase: .paused)
        XCTAssertEqual(restored.original.state, .ready)
        XCTAssertEqual(restored.state, .paused)
        XCTAssertEqual(present(snapshot, id, external).original.state, .unknown,
            "A Files bookmark may reference an undownloaded cloud document.")
        captured.fileSource = nil
        XCTAssertEqual(present(snapshot, id, captured).original.state, .unknown)
    }

    func testAlreadyCachedPreviewDoesNotWaitForOccupiedPackagingActor() async {
        let expectedURL = URL(fileURLWithPath: "/ready-preview.jpg")
        let result = await PackageThumbnailAvailability.waitForAvailable(
            loadOnce: { XCTFail("An existing preview must not hop to the packaging actor."); return nil },
            cachedURL: { expectedURL }, shouldWait: { true },
            sleep: { _ in XCTFail("An existing preview must not poll.") })
        XCTAssertEqual(result, expectedURL)
    }

    func testPreviewWaitReadsSourceOnceThenOnlyChecksCacheWithBoundedBackoff() async {
        let expectedURL = URL(fileURLWithPath: "/small-preview.jpg")
        var sourceLoads = 0, cacheChecks = 0
        var sleeps: [Duration] = []
        let result = await PackageThumbnailAvailability.waitForAvailable(
            loadOnce: { sourceLoads += 1; return nil },
            cachedURL: { cacheChecks += 1; return sleeps.count == 5 ? expectedURL : nil },
            shouldWait: { true },
            sleep: { sleeps.append($0) })
        XCTAssertEqual(result, expectedURL)
        XCTAssertEqual(sourceLoads, 1, "Missing previews must not repeatedly read originals or invoke PhotoKit.")
        XCTAssertEqual(cacheChecks, 7)
        XCTAssertEqual(sleeps, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(2), .seconds(2)])
    }

    func testPreviewWaitStopsWhenPackageBecomesInactiveButAcceptsItsLastPublishedPreview() async {
        let expectedURL = URL(fileURLWithPath: "/completed-preview.jpg")
        var active = true, available: URL?, sleeps = 0
        let result = await PackageThumbnailAvailability.waitForAvailable(
            loadOnce: { nil }, cachedURL: { available }, shouldWait: { active },
            sleep: { _ in sleeps += 1; active = false; available = expectedURL })
        XCTAssertEqual(result, expectedURL)
        XCTAssertEqual(sleeps, 1)
        let missing = await PackageThumbnailAvailability.waitForAvailable(
            loadOnce: { nil }, cachedURL: { nil }, shouldWait: { false },
            sleep: { _ in XCTFail("An idle or replaced package must not retain a polling task.") })
        XCTAssertNil(missing)
    }

    func testPreviewWaitCancellationReturnsWithoutFurtherCacheOrSourceReads() async {
        let sleeping = expectation(description: "Preview waiter sleeping")
        let returned = expectation(description: "Cancelled preview waiter returned")
        var sourceLoads = 0, cacheChecks = 0
        let task = Task { @MainActor in
            let result = await PackageThumbnailAvailability.waitForAvailable(
                loadOnce: { sourceLoads += 1; return nil },
                cachedURL: { cacheChecks += 1; return nil }, shouldWait: { true },
                sleep: { _ in sleeping.fulfill(); try await Task.sleep(for: .seconds(60)) })
            XCTAssertNil(result)
            returned.fulfill()
        }
        await fulfillment(of: [sleeping], timeout: 2)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(sourceLoads, 1)
        XCTAssertEqual(cacheChecks, 2)
    }

    func testOnlyConfirmedActiveCloudDownloadShowsTheOriginalBadge() {
        let id = UUID(), asset = PackageAsset(assetIdentifier: "asset")
        for original in [PackageOriginalProgress.unknown,
                         .init(state: .preparing, fraction: 0.5), .ready] {
            let snapshot = PackageActivitySnapshot(packageID: id, assetID: asset.id,
                originalProgressByAssetID: [asset.id: original])
            XCTAssertFalse(present(snapshot, id, asset).originalUsesCloud,
                "Unknown, local preparation and ready originals must not add an idle photo icon.")
        }
        let downloading = PackageActivitySnapshot(packageID: id, assetID: asset.id,
            originalProgressByAssetID: [asset.id: .init(state: .downloading, fraction: 0.5, cloudConfirmed: true)])
        XCTAssertTrue(present(downloading, id, asset).originalUsesCloud)
    }

    func testEditableDraftOnlyPackagesWhenSharedAndEmptyAlbumCannotShare() {
        XCTAssertFalse(PackageAlbumEditingPresentation.canResume(.draft))
        XCTAssertFalse(PackageAlbumEditingPresentation.canResume(.preparing))
        XCTAssertFalse(PackageAlbumEditingPresentation.canResume(.ready))
        XCTAssertTrue(PackageAlbumEditingPresentation.canResume(.paused))
        XCTAssertTrue(PackageAlbumEditingPresentation.canResume(.failed))
        XCTAssertTrue(PackageAlbumEditingPresentation.canShare(assetCount: 2, hasIssue: false, isBusy: false))
        XCTAssertFalse(PackageAlbumEditingPresentation.canShare(assetCount: 0, hasIssue: false, isBusy: false))
        XCTAssertFalse(PackageAlbumEditingPresentation.canShare(assetCount: 2, hasIssue: true, isBusy: false))
        XCTAssertFalse(PackageAlbumEditingPresentation.canShare(assetCount: 2, hasIssue: false, isBusy: true))
    }

    private func present(_ snapshot: PackageActivitySnapshot, _ id: UUID,
                         _ asset: PackageAsset) -> PackageAssetProgressPresentation {
        .init(snapshot: snapshot, packageID: id, asset: asset,
              isBusy: true, pauseRequested: false, phase: .packing)
    }
}
