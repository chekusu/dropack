import XCTest
import CryptoKit
import ZIPFoundation
@testable import Dropack

@MainActor
final class ReceivedAlbumIntegrationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFailedFirstSaveNeverCreatesEmptySystemAlbumAndDeletionKeepsPhotosUntouched() async throws {
        let writer = AlbumImportWriter()
        await writer.failSaveOnce()
        let controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "首张尚未存入")
        let accepted = await controller.selectSource(try archive(album: album, count: 1))
        XCTAssertTrue(accepted)
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 0)
        XCTAssertEqual(controller.job?.failedCount, 1)
        let exists = await writer.hasAlbum(album.id)
        let emptyCreationCalls = await writer.ensureCallCount()
        XCTAssertFalse(exists)
        XCTAssertEqual(emptyCreationCalls, 0)
        let before = await writer.albumOperationCount()

        let deleted = await controller.deleteAlbum(albumID: album.id)

        XCTAssertTrue(deleted)
        let after = await writer.albumOperationCount()
        XCTAssertEqual(after, before, "Deleting the local record cannot mutate Photos")
    }

    func testSystemAlbumIsCreatedWithFirstConfirmedAssetInsteadOfEmptyBeforeSave() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "首张成功后才关联")
        _ = await controller.selectSource(try archive(album: album, count: 2))
        let existsBefore = await writer.hasAlbum(album.id)
        XCTAssertFalse(existsBefore)
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        let emptyCreationCalls = await writer.ensureCallCount()
        let savesAtFirstLink = await writer.firstLinkSaveCount()
        let members = await writer.memberCount(album.id)
        XCTAssertEqual(emptyCreationCalls, 0)
        XCTAssertEqual(savesAtFirstLink, 1)
        XCTAssertEqual(members, 2)
        XCTAssertEqual(controller.job?.membershipPendingCount, 0)
        XCTAssertEqual(controller.job?.albumLinkUnavailable, false)
    }

    func testFullSnapshots24Then26ThenSameThenOldOnlyWriteTwoNewAssets() async throws {
        let writer = AlbumImportWriter()
        let controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "2026-10-13")
        let first = try archive(album: album, count: 24)
        let second = try archive(album: album.revised(), count: 26)
        let selectedFirst = await controller.selectSource(first)
        XCTAssertTrue(selectedFirst, controller.message ?? "")
        XCTAssertEqual(controller.job?.isAlbumUpdate, false)
        controller.delaySeconds = 0; controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 24)
        let selectedSecond = await controller.selectSource(second)
        XCTAssertTrue(selectedSecond, controller.message ?? "")
        XCTAssertEqual(controller.previouslySavedCount, 24)
        XCTAssertEqual(controller.job?.pendingCount, 2)
        XCTAssertEqual(controller.job?.isAlbumUpdate, true)
        controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 26)
        let attempts = await writer.attemptCount()
        XCTAssertEqual(attempts, 26)
        let members = await writer.memberCount(album.id)
        XCTAssertEqual(members, 26)
        let same = await controller.selectSource(second)
        XCTAssertTrue(same)
        XCTAssertFalse(controller.canStart)
        XCTAssertEqual(controller.job?.isAlbumUpdate, true)
        let old = await controller.selectSource(first)
        XCTAssertTrue(old)
        XCTAssertEqual(controller.job?.album?.revision, 2)
        XCTAssertEqual(controller.job?.items.count, 26)
        XCTAssertEqual(controller.library.count, 1)
        XCTAssertFalse(controller.canStart)
        XCTAssertEqual(controller.job?.isAlbumUpdate, true)
    }

    func testFirstLaterRevisionStaysFirstSyncAfterPauseReopenAndReselect() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(revision: 4, title: "第一次收到的第四版")
        let source = try archive(album: album, count: 3)
        let accepted = await controller.selectSource(source)
        XCTAssertTrue(accepted)
        XCTAssertEqual(controller.job?.isAlbumUpdate, false)
        controller.delaySeconds = 0.5
        controller.start()
        let deadline = Date().addingTimeInterval(10)
        while controller.job?.savedCount == 0 {
            guard Date() < deadline else { return XCTFail("The first photo never saved") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        controller.pause()
        try await settle(controller)
        XCTAssertGreaterThan(controller.job?.pendingCount ?? 0, 0)
        XCTAssertEqual(controller.job?.isAlbumUpdate, false)

        let reopened = makeController(writer)
        try await settle(reopened)
        let activated = await reopened.activate(albumID: album.id)
        XCTAssertTrue(activated)
        XCTAssertGreaterThan(reopened.previouslySavedCount, 0, "Reconciliation marks saved items as duplicates")
        XCTAssertEqual(reopened.job?.isAlbumUpdate, false, "The same snapshot is still its first sync")
        let reselected = await reopened.selectSource(source)
        XCTAssertTrue(reselected)
        XCTAssertEqual(reopened.job?.isAlbumUpdate, false)
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: try XCTUnwrap(reopened.job)), .synchronize)
        reopened.delaySeconds = 0
        reopened.start()
        try await settle(reopened)
        XCTAssertEqual(reopened.job?.savedCount, 3)
        XCTAssertEqual(reopened.job?.isAlbumUpdate, false)
        let completeReopen = await reopened.activate(albumID: album.id)
        XCTAssertTrue(completeReopen)
        XCTAssertFalse(reopened.canStart)
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: try XCTUnwrap(reopened.job)), .synchronize)
    }

    func testGlobalDuplicatesInAnotherAlbumDoNotCreateAnAlbumUpdate() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        _ = await controller.selectSource(try archive(album: ShareAlbumMetadata(title: "原相册"), count: 2))
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        let unrelated = ShareAlbumMetadata(revision: 7, title: "不同的分享相册")
        let selected = await controller.selectSource(try archive(album: unrelated, count: 3))
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.previouslySavedCount, 2)
        XCTAssertEqual(controller.job?.pendingCount, 1)
        XCTAssertEqual(controller.job?.isAlbumUpdate, false)
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: try XCTUnwrap(controller.job)), .synchronize)
    }

    func testMetadataOnlyRevisionAndLaterSnapshotsKeepUpdateHistoryWithoutDuplicateSaves() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "海边")
        _ = await controller.selectSource(try archive(album: album, count: 2))
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        let renamed = try album.renamed(to: "海边旅行")
        let selected = await controller.selectSource(try archive(album: renamed, count: 2))
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.job?.isAlbumUpdate, true)
        XCTAssertFalse(controller.canStart, "A name-only revision must not save content again")
        let appended = try renamed.revised()
        let selectedAppend = await controller.selectSource(try archive(album: appended, count: 3))
        XCTAssertTrue(selectedAppend)
        XCTAssertEqual(controller.job?.isAlbumUpdate, true)
        XCTAssertEqual(controller.job?.pendingCount, 1)
        controller.start()
        try await settle(controller)
        let saves = await writer.attemptCount()
        XCTAssertEqual(saves, 3)
    }

    func testSameContentDifferentAlbumsReusesAssetsAndAddsBothMemberships() async throws {
        let writer = AlbumImportWriter()
        // Both same-name albums are intentionally unrelated portable IDs.
        let first = ShareAlbumMetadata(title: "2026-10-13")
        let second = ShareAlbumMetadata(title: "2026-10-13")
        let active = makeController(writer)
        _ = await active.selectSource(try archive(album: first, count: 2)); active.delaySeconds = 0
        active.start(); try await settle(active)
        _ = await active.selectSource(try archive(album: second, count: 2))
        XCTAssertEqual(active.previouslySavedCount, 2)
        active.start(); try await settle(active)
        let attempts = await writer.attemptCount(), firstMembers = await writer.memberCount(first.id), secondMembers = await writer.memberCount(second.id)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(firstMembers, 2); XCTAssertEqual(secondMembers, 2)
        XCTAssertEqual(active.library.count, 2)
    }

    func testDeletedAssetReimportsButUnknownPermissionNeverDuplicates() async throws {
        let writer = AlbumImportWriter()
        let active = makeController(writer), album = ShareAlbumMetadata(title: "2026-10-13")
        let source = try archive(album: album, count: 2)
        _ = await active.selectSource(source); active.delaySeconds = 0
        active.start(); try await settle(active)
        await writer.setUnknown(true)
        _ = await active.selectSource(source)
        XCTAssertEqual(active.previouslySavedCount, 2)
        XCTAssertFalse(active.canStart)
        await writer.setUnknown(false)
        await writer.deleteAsset("asset-1")
        _ = await active.selectSource(source)
        XCTAssertEqual(active.job?.pendingCount, 1)
        active.start(); try await settle(active)
        let attempts = await writer.attemptCount()
        XCTAssertEqual(attempts, 3)
    }

    func testSwitchingUnfinishedAlbumsKeepsBothCheckpoints() async throws {
        let writer = AlbumImportWriter()
        let active = makeController(writer)
        let a = ShareAlbumMetadata(title: "2026-10-13"), b = ShareAlbumMetadata(title: "2026-10-14")
        _ = await active.selectSource(try archive(album: a, count: 2))
        _ = await active.selectSource(try archive(album: b, count: 3))
        XCTAssertEqual(active.library.count, 2)
        let activated = await active.activate(albumID: a.id)
        XCTAssertTrue(activated)
        XCTAssertEqual(active.job?.pendingCount, 2)
        XCTAssertEqual(active.job?.albumID, a.id)
    }

    func testMembershipFailureRetriesOnlyLinkingWithoutSavingAgain() async throws {
        let writer = AlbumImportWriter()
        await writer.failMembershipOnce()
        let controller = makeController(writer), album = ShareAlbumMetadata(title: "2026-10-13")
        _ = await controller.selectSource(try archive(album: album, count: 1))
        controller.delaySeconds = 0; controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 1)
        XCTAssertEqual(controller.job?.membershipPendingCount, 1)
        XCTAssertTrue(controller.canStart)
        controller.start(); try await settle(controller)
        let attempts = await writer.attemptCount(), members = await writer.memberCount(album.id)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(members, 1)
        XCTAssertEqual(controller.job?.membershipPendingCount, 0)
    }

    func testExternalMembershipRepairClearsPendingWithoutSavingAgain() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "修复关联")
        await writer.failMembershipOnce()
        _ = await controller.selectSource(try archive(album: album, count: 1))
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        XCTAssertEqual(controller.job?.membershipPendingCount, 1)
        let asset = try XCTUnwrap(controller.job?.items.first?.assetIdentifier)
        _ = try await writer.addToAlbum(assetIdentifiers: [asset], id: album.id, title: album.title)
        let activated = await controller.activate(albumID: album.id)
        XCTAssertTrue(activated)
        XCTAssertEqual(controller.job?.membershipPendingCount, 0)
        XCTAssertFalse(controller.canStart)
        let saves = await writer.attemptCount()
        XCTAssertEqual(saves, 1)
    }

    func testRemovedAlbumMemberIsLinkedAgainWithoutDuplicatePhotoWrite() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "恢复成员")
        _ = await controller.selectSource(try archive(album: album, count: 2))
        controller.delaySeconds = 0
        controller.start()
        try await settle(controller)
        let asset = try XCTUnwrap(controller.job?.items.first?.assetIdentifier)
        await writer.removeMember(asset, from: album.id)
        let activated = await controller.activate(albumID: album.id)
        XCTAssertTrue(activated)
        XCTAssertEqual(controller.job?.membershipPendingCount, 1)
        XCTAssertEqual(controller.job?.pendingCount, 0)
        XCTAssertTrue(controller.canStart)
        controller.start()
        try await settle(controller)
        XCTAssertEqual(controller.job?.membershipPendingCount, 0)
        let saves = await writer.attemptCount(), members = await writer.memberCount(album.id)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(members, 2)
    }

    func testPermissionUpgradeAndDeletedAlbumRebuildMembershipWithoutDuplicateWrites() async throws {
        let writer = AlbumImportWriter()
        await writer.setUnknown(true)
        let controller = makeController(writer), album = ShareAlbumMetadata(title: "2026-10-13")
        _ = await controller.selectSource(try archive(album: album, count: 2))
        controller.delaySeconds = 0; controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 2)
        XCTAssertEqual(controller.job?.albumLinkUnavailable, true)
        XCTAssertFalse(controller.canStart)
        await writer.setUnknown(false)
        let reopened = await controller.activate(albumID: album.id)
        XCTAssertTrue(reopened)
        XCTAssertTrue(controller.canStart)
        controller.start(); try await settle(controller)
        let firstMembers = await writer.memberCount(album.id)
        XCTAssertEqual(firstMembers, 2)
        await writer.deleteAlbum(album.id)
        _ = await controller.activate(albumID: album.id)
        XCTAssertTrue(controller.canStart)
        controller.start(); try await settle(controller)
        let attempts = await writer.attemptCount(), secondMembers = await writer.memberCount(album.id)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(secondMembers, 2)
    }

    func testForgedManifestHashCannotCountAsAlreadySaved() async throws {
        let writer = AlbumImportWriter()
        let active = makeController(writer)
        _ = await active.selectSource(try archive(album: ShareAlbumMetadata(title: "original"), count: 1))
        active.delaySeconds = 0; active.start(); try await settle(active)
        let source = try archive(album: ShareAlbumMetadata(title: "forged"), count: 1)
        let zip = try Archive(url: source, accessMode: .update)
        let entry = try XCTUnwrap(zip["photo-0.jpg"])
        try zip.remove(entry)
        let file = root.appendingPathComponent("photo-0.jpg")
        try Data("different attacker bytes".utf8).write(to: file)
        try zip.addEntry(with: "photo-0.jpg", relativeTo: root, compressionMethod: .none)
        let accepted = await active.selectSource(source)
        XCTAssertFalse(accepted)
        let attempts = await writer.attemptCount()
        XCTAssertEqual(attempts, 1)
    }

    func testOnlyValidatedDropackBecomesSharedAndSenderTitleWinsRenamedFilename() async throws {
        let writer = AlbumImportWriter(), controller = makeController(AlbumImportWriter())
        let album = ShareAlbumMetadata(title: "海边的三天")
        let original = try archive(album: album, count: 2)
        let renamed = root.appendingPathComponent("someone-renamed-this.dropack")
        try FileManager.default.copyItem(at: original, to: renamed)
        let accepted = await controller.selectSource(renamed)
        XCTAssertTrue(accepted)
        XCTAssertEqual(controller.job?.displayTitle, album.title)
        XCTAssertEqual(controller.job?.isSharedAlbum, true)
        XCTAssertTrue(controller.canShareArchive)
        XCTAssertEqual(controller.library.count, 1)

        // Exported ZIP keeps its manifest/Live Photo information, but must not
        // create a shared-library entry or touch system album APIs.
        let zip = root.appendingPathComponent("ordinary-export.zip")
        try FileManager.default.copyItem(at: original, to: zip)
        let ordinary = ImportController(checkpoint: .init(url: root.appendingPathComponent("ordinary/progress.json")), photoWriter: writer)
        let selectedZIP = await ordinary.selectSource(zip)
        XCTAssertTrue(selectedZIP)
        XCTAssertEqual(ordinary.job?.isOneTimeImport, true)
        XCTAssertFalse(ordinary.canShareArchive)
        XCTAssertTrue(ordinary.library.isEmpty)
        ordinary.delaySeconds = 0; ordinary.start(); try await settle(ordinary)
        let albumCalls = await writer.albumOperationCount()
        XCTAssertEqual(albumCalls, 0)
        XCTAssertNil(ordinary.job?.systemAlbumIdentifier)
        XCTAssertNil(ordinary.job?.albumLinkUnavailable)
        XCTAssertEqual(ordinary.job?.savedCount, 2)
    }

    func testReceivedAlbumCanForwardOriginalArchiveBeforeSavingAnyPhotos() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let album = ShareAlbumMetadata(title: "海边三天", senderName: "小雨的 iPhone")
        let source = try archive(album: album, count: 2)
        let originalBytes = try Data(contentsOf: source)
        let accepted = await controller.selectSource(source)
        XCTAssertTrue(accepted, controller.message ?? "")
        XCTAssertEqual(controller.job?.pendingCount, 2)
        XCTAssertEqual(controller.job?.savedCount, 0)
        XCTAssertEqual(controller.job?.album?.senderName, album.senderName)
        XCTAssertTrue(controller.canShareArchive)
        let sharedURL = await controller.shareURL()
        let shared = try XCTUnwrap(sharedURL)
        XCTAssertEqual(shared.standardizedFileURL, source.standardizedFileURL, "Forward the existing archive without staging a huge duplicate")
        XCTAssertEqual(try Data(contentsOf: shared), originalBytes)
        XCTAssertEqual(controller.job?.savedCount, 0)
        let saves = await writer.attemptCount()
        XCTAssertEqual(saves, 0)
        controller.finishSharing()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        // The URL remains resolvable after releasing one share session.
        let secondShare = await controller.shareURL()
        XCTAssertEqual(secondShare?.standardizedFileURL, source.standardizedFileURL)
        controller.finishSharing()
    }

    func testForwardingMissingArchiveFailsWithoutWritingToPhotos() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let source = try archive(album: ShareAlbumMetadata(title: "旅行"), count: 1)
        let accepted = await controller.selectSource(source)
        XCTAssertTrue(accepted)
        try FileManager.default.removeItem(at: source)
        let sharedURL = await controller.shareURL()
        XCTAssertNil(sharedURL)
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(controller.job?.pendingCount, 1)
        let saves = await writer.attemptCount()
        XCTAssertEqual(saves, 0)
        controller.finishSharing()
    }

    func testFolderAndDisguisedZIPImportOnceAndFinishKeepsDedupHistory() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let folder = root.appendingPathComponent("camera.originals")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("camera bytes".utf8).write(to: folder.appendingPathComponent("camera.jpg"))
        let selected = await controller.selectSource(folder)
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.job?.displayTitle, "camera.originals")
        XCTAssertEqual(controller.job?.isOneTimeImport, true)
        XCTAssertTrue(controller.library.isEmpty)
        let prematureFinish = await controller.finishOneTimeImport()
        XCTAssertFalse(prematureFinish)
        XCTAssertNotNil(controller.job)
        controller.delaySeconds = 0; controller.start(); try await settle(controller)
        let finished = await controller.finishOneTimeImport()
        XCTAssertTrue(finished)
        XCTAssertNil(controller.job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("progress.json").path))
        let store = ReceivedAlbumStore(directory: root.appendingPathComponent("received-albums"))
        XCTAssertTrue(try store.loadOneTimeImports().isEmpty)

        // Merely renaming a ZIP to .dropack is not evidence of a shared album.
        let disguised = root.appendingPathComponent("fake.dropack")
        let zip = try Archive(url: disguised, accessMode: .create)
        try zip.addEntry(with: "camera.jpg", relativeTo: folder, compressionMethod: .none)
        let reopened = await controller.selectSource(disguised)
        XCTAssertTrue(reopened)
        XCTAssertEqual(controller.job?.isOneTimeImport, true)
        XCTAssertEqual(controller.previouslySavedCount, 1)
        XCTAssertEqual(controller.job?.phase, .completed)
        XCTAssertTrue(controller.library.isEmpty)
        let attempts = await writer.attemptCount(), albumCalls = await writer.albumOperationCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(albumCalls, 0)
    }

    func testOneTimePausedCheckpointSurvivesSwitchAndRelaunchOutsideSharedLibrary() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let media = root.appendingPathComponent("camera.jpg")
        try Data("resume this private source".utf8).write(to: media)
        _ = await controller.selectSource(media)
        let importID = try XCTUnwrap(controller.job?.id)
        let shared = try archive(album: ShareAlbumMetadata(title: "Shared"), count: 1)
        _ = await controller.selectSource(shared)
        XCTAssertEqual(controller.library.count, 1)
        let reopened = makeController(writer)
        try await settle(reopened)
        let reselected = await reopened.selectSource(media)
        XCTAssertTrue(reselected)
        XCTAssertEqual(reopened.job?.id, importID)
        XCTAssertEqual(reopened.job?.pendingCount, 1)
        XCTAssertEqual(reopened.job?.isOneTimeImport, true)
        XCTAssertEqual(reopened.library.count, 1)
        reopened.delaySeconds = 0; reopened.start(); try await settle(reopened)
        let finished = await reopened.finishOneTimeImport()
        XCTAssertTrue(finished)
        XCTAssertEqual(reopened.library.count, 1)
        let calls = await writer.albumOperationCount()
        XCTAssertEqual(calls, 2, "Only the genuine package scan asks for album presence and members")
    }

    func testDiscardOneTimeTaskPreservesUncertainLedgerAndDoesNotDeleteSharedAlbum() async throws {
        let writer = AlbumImportWriter(), controller = makeController(writer)
        let shared = try archive(album: ShareAlbumMetadata(title: "Keep this album"), count: 1)
        _ = await controller.selectSource(shared)
        let sharedID = try XCTUnwrap(controller.job?.albumID)
        let cannotDiscardShared = await controller.discardCurrentImport()
        XCTAssertFalse(cannotDiscardShared)
        let media = root.appendingPathComponent("uncertain.jpg")
        try Data("possibly saved photo".utf8).write(to: media)
        _ = await controller.selectSource(media)
        let item = try XCTUnwrap(controller.job?.items.first)
        let identity = try XCTUnwrap(item.contentIdentity)
        let jobID = try XCTUnwrap(controller.job?.id)
        let history = ImportHistoryStore(url: root.appendingPathComponent("import-history.sqlite"))
        _ = try history.begin(identity: identity, jobID: jobID, itemID: item.id, sourceIdentity: controller.job?.source.contentIdentity)
        _ = await controller.selectSource(media)
        XCTAssertEqual(controller.job?.uncertainCount, 1)
        let cannotFinish = await controller.finishOneTimeImport()
        XCTAssertFalse(cannotFinish)
        let discarded = await controller.discardCurrentImport()
        XCTAssertTrue(discarded)
        XCTAssertNil(controller.job)
        XCTAssertEqual(controller.library.map(\.albumID), [sharedID])
        XCTAssertEqual(try history.record(for: identity)?.state, .unresolved)
        _ = await controller.selectSource(media)
        XCTAssertEqual(controller.job?.uncertainCount, 1)
        XCTAssertFalse(controller.canStart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        let attempts = await writer.attemptCount()
        XCTAssertEqual(attempts, 0)
    }

    private func makeController(_ writer: AlbumImportWriter) -> ImportController {
        ImportController(checkpoint: .init(url: root.appendingPathComponent("progress.json")), photoWriter: writer)
    }
    private func archive(album: ShareAlbumMetadata, count: Int) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [PhotoPackageManifestItem] = []
        for index in 0..<count {
            let path = "photo-\(index).jpg", data = Data("stable photo bytes \(index)".utf8)
            try data.write(to: directory.appendingPathComponent(path))
            entries.append(.init(id: String(format: "00000000-0000-0000-0000-%012d", index), photoPath: path,
                photoSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        var manifest = PhotoPackageManifest(items: entries)
        manifest.album = album
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(PhotoPackageManifest.filename))
        let url = root.appendingPathComponent(UUID().uuidString + ".dropack")
        let output = try Archive(url: url, accessMode: .create)
        for entry in entries { try output.addEntry(with: try XCTUnwrap(entry.photoPath), relativeTo: directory, compressionMethod: .none) }
        try output.addEntry(with: PhotoPackageManifest.filename, relativeTo: directory, compressionMethod: .none)
        return url
    }
    private func settle(_ controller: ImportController) async throws {
        let limit = Date().addingTimeInterval(30)
        while controller.isBusy || controller.isPreparing {
            guard Date() < limit else { return XCTFail(controller.message ?? "Timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor AlbumImportWriter: PhotoLibraryWriting {
    private var attempts = 0
    private var existing = Set<String>()
    private var memberships: [UUID: Set<String>] = [:]
    private var unknown = false
    private var shouldFailMembership = false
    private var shouldFailSave = false
    private var albumOperations = 0
    private var ensureCalls = 0
    private var savedCountAtFirstLink: Int?
    func authorize() async throws {}
    func save(item: ImportItem, fileURL: URL, pairedVideoURL: URL?) async throws -> String? {
        attempts += 1
        if shouldFailSave {
            shouldFailSave = false
            throw PhotoLibraryWriterError.transactionFailed("Controlled first-save failure")
        }
        let id = "asset-\(attempts)"
        existing.insert(id)
        return id
    }
    func assetPresence(_ identifier: String) async -> SystemAssetPresence { unknown ? .unknown : existing.contains(identifier) ? .available : .missing }
    func ensureAlbum(id: UUID, title: String) async throws -> String? {
        albumOperations += 1
        ensureCalls += 1
        guard !unknown else { return nil }
        if memberships[id] == nil { memberships[id] = [] }
        return id.uuidString
    }
    func albumPresence(id: UUID) async throws -> SystemAssetPresence {
        albumOperations += 1
        return unknown ? .unknown : memberships[id] == nil ? .missing : .available
    }
    func albumMembers(id: UUID) async throws -> [String]? {
        albumOperations += 1
        return unknown ? nil : memberships[id].map(Array.init)
    }
    func addToAlbum(assetIdentifiers: [String], id: UUID, title: String) async throws -> String? {
        albumOperations += 1
        guard !unknown else { return nil }
        if savedCountAtFirstLink == nil { savedCountAtFirstLink = attempts }
        if shouldFailMembership {
            shouldFailMembership = false
            throw PhotoLibraryWriterError.transactionFailed("Controlled album membership failure")
        }
        memberships[id, default: []].formUnion(assetIdentifiers)
        return id.uuidString
    }
    func attemptCount() -> Int { attempts }
    func memberCount(_ id: UUID) -> Int { memberships[id]?.count ?? 0 }
    func setUnknown(_ value: Bool) { unknown = value }
    func deleteAsset(_ id: String) { existing.remove(id) }
    func deleteAlbum(_ id: UUID) { memberships.removeValue(forKey: id) }
    func removeMember(_ assetID: String, from albumID: UUID) { memberships[albumID]?.remove(assetID) }
    func failMembershipOnce() { shouldFailMembership = true }
    func failSaveOnce() { shouldFailSave = true }
    func hasAlbum(_ id: UUID) -> Bool { memberships[id] != nil }
    func ensureCallCount() -> Int { ensureCalls }
    func firstLinkSaveCount() -> Int? { savedCountAtFirstLink }
    func albumOperationCount() -> Int { albumOperations }
}
