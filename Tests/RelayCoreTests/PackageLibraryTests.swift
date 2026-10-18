import Foundation
import XCTest
@testable import RelayCore

final class PackageLibraryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNewSelectionAndDeletionNeverReplaceAnotherPackagesJournalOrFiles() throws {
        let store = PackageLibraryStore(root: root)
        try store.prepare()
        var a = PackageJob(assetIdentifiers: ["a1", "a2"])
        a.phase = .paused
        let b = PackageJob(assetIdentifiers: ["b1"])
        try store.save(a); try store.select(a.id)
        let payload = try store.directory(id: a.id).appendingPathComponent(a.archiveFilename)
        let original = Data(repeating: 9, count: 22)
        try original.write(to: payload)
        let exported = try PackageFileFormat.zip.shareURL(for: payload)
        let thumbnail = try store.thumbnailURL(packageID: a.id, itemID: a.assets[0].id)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: thumbnail)
        try store.save(b); try store.select(b.id)
        XCTAssertEqual(try store.selectedID(), b.id)
        XCTAssertEqual(try store.load(id: a.id)?.selectedAssetIdentifiers, ["a1", "a2"])
        XCTAssertEqual(try store.load(id: b.id)?.selectedAssetIdentifiers, ["b1"])
        XCTAssertEqual(try store.entries().count, 2)
        let bJournal = try Data(contentsOf: store.checkpointURL(id: b.id))
        try store.delete(id: a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertEqual(try Data(contentsOf: store.checkpointURL(id: b.id)), bJournal)
        XCTAssertEqual(try store.selectedID(), b.id)
        try store.delete(id: b.id)
        XCTAssertNil(try store.selectedID())
    }

    func testLegacyZIPMigrationIsRepeatableAndPreservesArchiveRollbackAndExport() throws {
        let store = PackageLibraryStore(root: root)
        var job = PackageJob(assetIdentifiers: ["old-photo"])
        job.archiveFilename = "PhotoRelay-legacy.zip"
        job.phase = .packing
        job.transaction = .init(originalSize: 22, directoryOffset: 0, backupFilename: "directory-backup.bin")
        let directory = try store.directory(id: job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent(job.archiveFilename)
        let bytes = Data(repeating: 42, count: 22)
        try bytes.write(to: archive)
        let alternate = try PackageFileFormat.dropack.shareURL(for: archive)
        let backup = directory.appendingPathComponent("directory-backup.bin")
        try bytes.write(to: backup)
        try PackageRecovery.save(job, to: root.appendingPathComponent("package.json"))
        let inode = try FileManager.default.attributesOfItem(atPath: archive.path)[.systemFileNumber] as? NSNumber
        try store.prepare(); try store.prepare()
        let loaded = try XCTUnwrap(store.load(id: job.id))
        XCTAssertEqual(loaded.id, job.id)
        XCTAssertEqual(loaded.phase, .paused)
        XCTAssertEqual(loaded.transaction, job.transaction)
        XCTAssertEqual(try store.selectedID(), job.id)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try Data(contentsOf: alternate), bytes)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path))
    }

    func testMigrationDoesNotOverwriteAlreadyMigratedNewerCheckpoint() throws {
        let store = PackageLibraryStore(root: root)
        let original = PackageJob(assetIdentifiers: ["a"])
        try PackageRecovery.save(original, to: root.appendingPathComponent("package.json"))
        var updated = original; updated.phase = .failed; updated.lastMessage = "newer persisted error"
        try store.save(updated)
        try store.prepare()
        XCTAssertEqual(try store.load(id: original.id)?.lastMessage, updated.lastMessage)
    }

    func testStoredIDMismatchAndSymlinkCannotReadOrDeleteAnotherPackage() throws {
        let store = PackageLibraryStore(root: root)
        let a = PackageJob(assetIdentifiers: ["a"])
        let b = PackageJob(assetIdentifiers: ["b"])
        try store.save(a); try store.save(b)
        try PackageRecovery.save(b, to: store.checkpointURL(id: a.id))
        XCTAssertThrowsError(try store.load(id: a.id))
        let linkID = UUID()
        let link = root.appendingPathComponent(linkID.uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.directory(id: b.id))
        XCTAssertThrowsError(try store.load(id: linkID))
        XCTAssertThrowsError(try store.delete(id: linkID))
        XCTAssertNotNil(try store.load(id: b.id))
        XCTAssertThrowsError(try store.thumbnailURL(packageID: b.id, itemID: "../../elsewhere"))
    }

    func testLegacyAssetsDecodeWithNoThumbnailMetadataAndCountsUseManifest() throws {
        var job = PackageJob(assetIdentifiers: ["live", "video", "pending"])
        let liveID = job.assets[0].id
        job.assets[0].manifestItem = .init(id: liveID, photoPath: "media/a.jpg", videoPath: "media/a.mov", isLivePhoto: true)
        job.assets[0].archiveRecords = [.init(path: "media/a.jpg", byteCount: 4, checksum: 0), .init(path: "media/a.mov", byteCount: 9, checksum: 0)]
        job.assets[1].manifestItem = .init(id: job.assets[1].id, videoPath: "media/b.mov")
        job.assets[1].archiveRecords = [.init(path: "media/b.mov", byteCount: 3, checksum: 0)]
        let decoded = try JSONDecoder().decode(PackageJob.self, from: JSONEncoder().encode(job))
        try decoded.validate()
        let entry = PackageLibraryEntry(job: decoded)
        XCTAssertEqual(entry.photoCount, 1)
        XCTAssertEqual(entry.videoCount, 1)
        XCTAssertEqual(entry.completedCount, 2)
        XCTAssertEqual(entry.totalCount, 3)
        XCTAssertEqual(entry.bytes, 16)
        XCTAssertNil(entry.assets[0].title)
        XCTAssertNil(entry.assets[0].kind)
    }

    func testDamagedLegacyJournalIsIsolatedWithoutDeletingItsPayloadOrBlockingNewPackages() throws {
        let store = PackageLibraryStore(root: root)
        let oldID = UUID()
        let folder = try store.directory(id: oldID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = folder.appendingPathComponent("Original.zip")
        let original = Data("preserve this archive".utf8)
        try original.write(to: payload)
        let badJournal = Data("broken old checkpoint".utf8)
        try badJournal.write(to: root.appendingPathComponent("package.json"))
        try store.prepare(); try store.prepare()
        XCTAssertEqual(try store.selectedID(), oldID)
        XCTAssertEqual(try Data(contentsOf: store.checkpointURL(id: oldID)), badJournal)
        XCTAssertEqual(try Data(contentsOf: payload), original)
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.id, oldID)
        XCTAssertNotNil(entry.issue)
        XCTAssertEqual(entry.totalCount, 0)
        let fresh = PackageJob(assetIdentifiers: ["fresh"])
        try store.save(fresh); try store.select(fresh.id)
        XCTAssertEqual(try store.entries().count, 2)
        try store.delete(id: oldID)
        XCTAssertEqual(try store.entries().map(\.id), [fresh.id])
    }
}
