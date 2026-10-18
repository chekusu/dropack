import Foundation
import XCTest
@testable import RelayCore

final class PackageRecoveryTests: XCTestCase {
    func testNewDropackAndLegacyZIPCheckpointsBothRecoverWithoutRenaming() throws {
        var job = PackageJob(assetIdentifiers: ["original-asset"])
        XCTAssertEqual(URL(fileURLWithPath: job.archiveFilename).pathExtension, "dropack")
        for suffix in ["dropack", "zip", "ZIP"] {
            job.archiveFilename = "Dropack-old-task.\(suffix)"
            job.phase = .packing
            let checkpoint = root.appendingPathComponent("format-\(suffix).json")
            try PackageRecovery.save(job, to: checkpoint)
            let restored = try XCTUnwrap(PackageRecovery.load(from: checkpoint))
            XCTAssertEqual(restored.archiveFilename, job.archiveFilename)
            XCTAssertEqual(restored.phase, .paused)
            XCTAssertEqual(restored.selectedAssetIdentifiers, ["original-asset"])
        }
        for invalid in ["outside.txt", "../outside.dropack", "folder/file.dropack", "folder\\file.dropack"] {
            job.archiveFilename = invalid
            XCTAssertThrowsError(try job.validate(), invalid)
        }
    }

    func testZIPExportAndLegacyDropackShareUseSameFileWithoutCopyingOrDestroyingOriginal() throws {
        // Sparse 30 GB models a very large finished package. Export must not read
        // or duplicate its payload; both names point to the same filesystem inode.
        let source = root.appendingPathComponent("large.dropack")
        try Data(repeating: 0, count: 22).write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 30_000_000_000)
        try handle.close()
        let zip = try PackageFileFormat.zip.shareURL(for: source)
        XCTAssertEqual(zip.pathExtension, "zip")
        XCTAssertEqual(try PackageRecovery.fileSize(zip), 30_000_000_000)
        let original = try FileManager.default.attributesOfItem(atPath: source.path)
        let exported = try FileManager.default.attributesOfItem(atPath: zip.path)
        XCTAssertEqual(original[.systemFileNumber] as? NSNumber, exported[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try PackageFileFormat.zip.shareURL(for: source), zip)
        XCTAssertEqual(try PackageFileFormat.dropack.shareURL(for: zip), source)
        try FileManager.default.removeItem(at: zip)
        XCTAssertEqual(try PackageRecovery.fileSize(source), 30_000_000_000)
    }

    func testAlternateExportNeverOverwritesExistingDifferentFileOrAcceptsSymlinkSource() throws {
        let source = root.appendingPathComponent("conflict.dropack")
        let zip = root.appendingPathComponent("conflict.zip")
        let original = Data(repeating: 0x31, count: 22)
        let other = Data(repeating: 0x42, count: 22)
        try original.write(to: source)
        try other.write(to: zip)
        XCTAssertThrowsError(try PackageFileFormat.zip.shareURL(for: source))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: zip), other)
        let link = root.appendingPathComponent("symbolic.dropack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try PackageFileFormat.zip.shareURL(for: link))
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testWriterLimitsAgreeWithReceiverWithoutAllocatingHugeCollections() throws {
        try PackageFormatLimits.validateSelectionCount(PackageFormatLimits.maxSelectedAssets)
        XCTAssertThrowsError(try PackageFormatLimits.validateSelectionCount(PackageFormatLimits.maxSelectedAssets + 1))
        XCTAssertLessThan(PackageFormatLimits.maxSelectedAssets * 2 + 1, PackageFormatLimits.maxZIPEntries)
        try PackageFormatLimits.validateFinalization(resourceCount: PackageFormatLimits.maxZIPEntries - 1,
                                                     manifestByteCount: PackageFormatLimits.maxManifestBytes)
        XCTAssertThrowsError(try PackageFormatLimits.validateFinalization(resourceCount: PackageFormatLimits.maxZIPEntries,
                                                                           manifestByteCount: 1))
        XCTAssertThrowsError(try PackageFormatLimits.validateFinalization(resourceCount: 1,
                                                                           manifestByteCount: PackageFormatLimits.maxManifestBytes + 1))
    }

    func testLivePhotoManifestPreservesPairDateAndHashes() throws {
        let id = UUID().uuidString
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        let item = PhotoPackageManifestItem(id: id, photoPath: "media/\(id)/original.heic",
            videoPath: "media/\(id)/paired.mov", creationDate: date, isLivePhoto: true,
            photoSHA256: String(repeating: "a", count: 64), videoSHA256: String(repeating: "0", count: 64))
        let manifest = PhotoPackageManifest(items: [item])
        try manifest.validate()
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(PhotoPackageManifest.self, from: data), manifest)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("assetIdentifier"))
    }

    func testManifestRejectsAmbiguousPairsTraversalDuplicatesVersionsAndHashes() throws {
        let id = UUID().uuidString
        let good = PhotoPackageManifestItem(id: id, photoPath: "media/\(id)/original.jpg")
        try PhotoPackageManifest(items: [good]).validate()
        var invalid = good; invalid.isLivePhoto = true
        XCTAssertThrowsError(try PhotoPackageManifest(items: [invalid]).validate())
        invalid = good; invalid.photoPath = "../private.jpg"
        XCTAssertThrowsError(try PhotoPackageManifest(items: [invalid]).validate())
        invalid = good; invalid.id = UUID().uuidString
        XCTAssertThrowsError(try PhotoPackageManifest(items: [good, invalid]).validate())
        invalid = good; invalid.photoSHA256 = "bad"
        XCTAssertThrowsError(try PhotoPackageManifest(items: [invalid]).validate())
        invalid = good; invalid.videoSHA256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try PhotoPackageManifest(items: [invalid]).validate())
        XCTAssertThrowsError(try PhotoPackageManifest(version: 2, items: [good]).validate())
    }

    func testInterruptedCheckpointRetainsCompletedAssetsAndRollbackMarker() throws {
        var job = PackageJob(assetIdentifiers: ["asset-1", "asset-2"])
        let id = job.assets[0].id
        let path = "media/\(id)/original.heic"
        job.assets[0].manifestItem = PhotoPackageManifestItem(id: id, photoPath: path)
        job.assets[0].archiveRecords = [PackageArchiveRecord(path: path, byteCount: 30_000_000_000, checksum: 23)]
        job.phase = .packing
        job.transaction = PackageArchiveTransaction(originalSize: 100, directoryOffset: 50,
                                                     backupFilename: "directory-backup.bin")
        let url = root.appendingPathComponent("job.json")
        try PackageRecovery.save(job, to: url)
        let restored = try XCTUnwrap(PackageRecovery.load(from: url))
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertEqual(restored.completedCount, 1)
        XCTAssertEqual(restored.totalCount, 2)
        XCTAssertNil(restored.totalBytes)
        XCTAssertEqual(restored.completedBytes, 30_000_000_000)
        XCTAssertEqual(restored.transaction, job.transaction)
        XCTAssertEqual(restored.selectedAssetIdentifiers, ["asset-1", "asset-2"])
    }

    func testReadyCannotBeClaimedWithMissingManifestOrPartialAssets() throws {
        var job = PackageJob(assetIdentifiers: ["asset-1"])
        job.phase = .ready
        job.finalizedSize = 500
        XCTAssertThrowsError(try job.validate())
        let path = "media/\(job.assets[0].id)/original.jpg"
        job.assets[0].manifestItem = PhotoPackageManifestItem(id: job.assets[0].id, photoPath: path)
        job.assets[0].archiveRecords = [PackageArchiveRecord(path: path, byteCount: 10, checksum: 20)]
        XCTAssertThrowsError(try job.validate())
        job.manifestRecord = PackageArchiveRecord(path: PhotoPackageManifest.filename, byteCount: 30, checksum: 4)
        try job.validate()
        job.transaction = PackageArchiveTransaction(originalSize: 100, directoryOffset: 0, backupFilename: "directory-backup.bin")
        XCTAssertThrowsError(try job.validate())
    }

    func testBadJournalCannotBeLoadedOrOverwrittenBySave() throws {
        let url = root.appendingPathComponent("job.json")
        let corrupt = Data("unreadable checkpoint".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try PackageRecovery.load(from: url))
        var job = PackageJob(assetIdentifiers: ["duplicate", "duplicate"])
        XCTAssertThrowsError(try PackageRecovery.save(job, to: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        job = PackageJob(assetIdentifiers: ["asset-1"]); job.version = 999
        XCTAssertThrowsError(try PackageRecovery.save(job, to: url))
        job = PackageJob(assetIdentifiers: ["asset-1"]); job.archiveFilename = "../outside.zip"
        XCTAssertThrowsError(try PackageRecovery.save(job, to: url))
    }

    func testRollbackRestoresOverwrittenDirectoryAndTruncatesIncompletePayloadIdempotently() throws {
        let archive = root.appendingPathComponent("test.zip")
        let backup = root.appendingPathComponent("directory-backup.bin")
        // A long prefix models already committed payload; rollback must not change it.
        let original = Data(repeating: 0x77, count: 1_200_000) + emptyEnd(offset: 1_200_000)
        try original.write(to: archive)
        let transaction = try PackageRecovery.snapshot(archive: archive, backup: backup)
        XCTAssertEqual(try PackageRecovery.fileSize(backup), 22)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: transaction.directoryOffset)
        try handle.write(contentsOf: Data(repeating: 0x99, count: 2_500_000))
        try handle.close()
        try PackageRecovery.rollback(transaction, archive: archive, backup: backup)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        try PackageRecovery.rollback(transaction, archive: archive, backup: backup)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try ZipDirectoryValidator.validate(url: archive, byteCount: UInt64(original.count)).entryCount, 0)
    }

    func testRollbackRunsEvenWhenWorkerHasBeenCancelled() async throws {
        let archive = root.appendingPathComponent("test.zip")
        let backup = root.appendingPathComponent("directory-backup.bin")
        let original = emptyEnd(offset: 0)
        try original.write(to: archive)
        let transaction = try PackageRecovery.snapshot(archive: archive, backup: backup)
        try Data(repeating: 5, count: 300).write(to: archive)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try PackageRecovery.rollback(transaction, archive: archive, backup: backup)
        }
        task.cancel()
        try await task.value
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testMissingOrTruncatedRollbackBackupFailsWithoutMutatingArchive() throws {
        let archive = root.appendingPathComponent("test.zip")
        let backup = root.appendingPathComponent("directory-backup.bin")
        let original = emptyEnd(offset: 0)
        try original.write(to: archive)
        let transaction = try PackageRecovery.snapshot(archive: archive, backup: backup)
        try Data([1, 2]).write(to: backup)
        XCTAssertThrowsError(try PackageRecovery.rollback(transaction, archive: archive, backup: backup))
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    private func emptyEnd(offset: UInt32) -> Data {
        var data = Data(repeating: 0, count: 22)
        data.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x05, 0x06])
        for index in 0..<4 { data[16 + index] = UInt8(truncatingIfNeeded: offset >> (index * 8)) }
        return data
    }
}
