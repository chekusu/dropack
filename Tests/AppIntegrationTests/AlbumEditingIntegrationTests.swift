import CryptoKit
import Foundation
import XCTest
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation
@testable import Dropack

@MainActor
final class AlbumEditingIntegrationTests: XCTestCase {
    private var root: URL!
    private var files: URL!
    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("Library")
        files = directory.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func testAddMakesDraftAndShareReusesMissingOriginalWithoutExporter() async throws {
        let old = try file("large.mov", Data(repeating: 0x4A, count: 2 * 1024 * 1024 + 5))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [old])
        XCTAssertTrue(initial.isDraft); XCTAssertEqual(initial.packagingRequested, false)
        let packed = try await service.run(packageID: initial.id) { _ in }
        let originalJob = try XCTUnwrap(packed.job)
        let originalURL = try XCTUnwrap(packed.archiveURL)
        let oldBytes = try Data(contentsOf: originalURL)
        try FileManager.default.removeItem(at: old) // Any export or hash of old media now fails.
        let fresh = try file("new.jpg", Data("new image".utf8))
        let draft = try await service.add(fileURLs: [fresh], to: initial.id)
        XCTAssertTrue(draft.isDraft); XCTAssertEqual(draft.packagingRequested, false)
        XCTAssertEqual(draft.completedCount, 0)
        XCTAssertEqual(draft.assets[0].reuseSourcePackageID, initial.id)
        let preview = try await service.resolvePreviewArchive(packageID: draft.id, assetID: draft.assets[0].id)
        XCTAssertEqual(preview.url, originalURL)
        XCTAssertEqual(preview.asset.manifestItem, originalJob.assets[0].manifestItem)
        let emptyArchive = root.appendingPathComponent(draft.id.uuidString).appendingPathComponent(draft.archiveFilename)
        XCTAssertEqual(Array(try Archive(url: emptyArchive, accessMode: .read)).count, 0)
        let result = try await service.run(packageID: draft.id) { _ in }
        let finished = try XCTUnwrap(result.job)
        XCTAssertEqual(finished.completedCount, 2)
        XCTAssertTrue(["apfs-clone", "raw-record-copy"].contains(finished.reuseStrategy ?? ""))
        XCTAssertEqual(finished.assets[0].manifestItem, originalJob.assets[0].manifestItem)
        XCTAssertEqual(try Data(contentsOf: originalURL), oldBytes)
        let shared = try await service.sharePreparedURL(packageID: draft.id, format: .dropack)
        XCTAssertEqual(shared.lastPathComponent, draft.archiveFilename)
    }

    func testRemovalCopiesRetainedBytesOnlyAndLeavesOldSnapshotImmutable() async throws {
        let keep = try file("keep.mov", Data(repeating: 0x6C, count: 1024 * 1024 + 9))
        let secret = Data("REMOVED-VIDEO-SECRET-784936712341".utf8)
        let remove = try file("remove.mov", secret)
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [keep, remove])
        let old = try await service.run(packageID: initial.id) { _ in }
        let oldJob = try XCTUnwrap(old.job), oldURL = try XCTUnwrap(old.archiveURL)
        let deletedID = try XCTUnwrap(oldJob.assets.first { $0.title == "remove.mov" }?.id)
        let keptID = try XCTUnwrap(oldJob.assets.first { $0.title == "keep.mov" }?.id)
        try FileManager.default.removeItem(at: keep)
        let draft = try await service.remove(assetIDs: [deletedID], from: initial.id)
        XCTAssertTrue(draft.isDraft); XCTAssertEqual(draft.assets.map(\.id), [keptID])
        let result = try await service.run(packageID: draft.id) { _ in }
        XCTAssertEqual(result.job?.reuseStrategy, "raw-record-copy")
        let bytes = try Data(contentsOf: XCTUnwrap(result.archiveURL))
        XCTAssertNil(bytes.range(of: secret), "Removed original bytes must not survive as orphan ZIP entries")
        XCTAssertNotNil(try Data(contentsOf: oldURL).range(of: secret))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remove.path), "Removing membership never deletes original")
    }

    func testChangedOriginalInvalidatesReuseAndExactPreparedShareDoesNotRefresh() async throws {
        let photo = try file("photo.jpg", Data("old original".utf8))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [photo])
        let old = try await service.run(packageID: initial.id) { _ in }
        let changed = Data("new longer original contents".utf8)
        try changed.write(to: photo)
        let draft = try await service.refreshAlbum(packageID: initial.id)
        XCTAssertNotEqual(draft.id, initial.id); XCTAssertTrue(draft.isDraft)
        XCTAssertNil(draft.assets[0].reuseSourcePackageID)
        // Exact prepared revision remains intentionally shareable/previewable.
        let exact = try await service.sharePreparedURL(packageID: initial.id, format: .dropack)
        XCTAssertEqual(exact, old.archiveURL)
        let result = try await service.run(packageID: draft.id) { _ in }
        XCTAssertEqual(result.job?.assets[0].manifestItem?.photoSHA256,
            SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined())
    }

    func testDeletingLastMemberPreservesEmptyDraftAndRejectsPacking() async throws {
        let photo = try file("photo.jpg", Data("photo".utf8))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [photo])
        let empty = try await service.remove(assetIDs: initial.assets.map(\.id), from: initial.id)
        XCTAssertTrue(empty.isDraft); XCTAssertEqual(empty.totalCount, 0)
        let restored = try await service.activate(packageID: empty.id)
        XCTAssertTrue(restored.job?.isDraft == true)
        do { _ = try await service.run(packageID: empty.id) { _ in }; XCTFail("Empty album cannot produce a sharing package") }
        catch { XCTAssertTrue(error is PhotoPackageError) }
        let back = try await service.add(fileURLs: [photo], to: empty.id)
        XCTAssertEqual(back.totalCount, 1); XCTAssertTrue(back.isDraft)
    }

    func testRepeatedDraftEditsKeepOriginalReuseSource() async throws {
        let photo = try file("photo.jpg", Data("photo".utf8))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [photo])
        _ = try await service.run(packageID: initial.id) { _ in }
        let first = try await service.rename(packageID: initial.id, title: "First name")
        let second = try await service.rename(packageID: first.id, title: "Second name")
        XCTAssertEqual(second.assets[0].reuseSourcePackageID, initial.id)
        XCTAssertEqual(second.assets[0].id, initial.assets[0].id)
        XCTAssertTrue(second.isDraft)
        try FileManager.default.removeItem(at: photo)
        let result = try await service.run(packageID: second.id) { _ in }
        XCTAssertEqual(result.job?.phase, .ready)
    }

    func testRenamingPrivatePickerDraftPreservesGrantTokensWithoutReadingOriginals() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { _ in
            XCTFail("Metadata edit must not request original resources")
            return nil
        }
        let selection = PhotoPickerSelection(items: [.init(assetIdentifier: nil, provider: provider)])
        let service = PhotoPackageService(root: root)
        let first = try await service.create(selection: selection)
        let renamed = try await service.rename(packageID: first.id, title: "Private draft")
        XCTAssertTrue(renamed.isDraft)
        XCTAssertEqual(renamed.assets[0].pickerSelectionItemID, first.assets[0].pickerSelectionItemID)
        XCTAssertEqual(renamed.assets[0].id, first.assets[0].id)
        XCTAssertEqual(try selection.resources(for: renamed).count, 1)
        XCTAssertTrue(renamed.assets[0].pickerResourcePending == true)
    }

    func testChangedPhotoCannotInheritStaleThumbnailOrPortablePreview() async throws {
        func jpeg(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let photo = try file("photo.jpg", jpeg(.red))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [photo])
        _ = try await service.run(packageID: initial.id) { _ in }
        let oldThumbnail = try Data(contentsOf: XCTUnwrap(service.thumbnailURL(packageID: initial.id, itemID: initial.assets[0].id)))
        try jpeg(.green).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: photo.path)
        let draft = try await service.refreshAlbum(packageID: initial.id)
        XCTAssertNil(draft.assets[0].reuseSourcePackageID)
        XCTAssertNil(service.thumbnailURL(packageID: draft.id, itemID: draft.assets[0].id))
        let packed = try await service.run(packageID: draft.id) { _ in }
        let newThumbnail = try Data(contentsOf: XCTUnwrap(service.thumbnailURL(packageID: draft.id, itemID: draft.assets[0].id)))
        XCTAssertNotEqual(newThumbnail, oldThumbnail)
        let archive = try Archive(url: XCTUnwrap(packed.archiveURL), accessMode: .read)
        let previewPath = try XCTUnwrap(packed.job?.assets[0].manifestItem?.previewPath)
        var preview = Data(); _ = try archive.extract(XCTUnwrap(archive[previewPath])) { preview.append($0) }
        XCTAssertEqual(preview, newThumbnail)
    }

    func testEditingInterruptedHistoricalArchiveRepairsCheckpointBeforeReusingIt() async throws {
        let first = try file("first.mov", Data(repeating: 0x78, count: 1024 * 1024 + 11))
        let second = try file("second.jpg", Data("second".utf8))
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(fileURLs: [first, second])
        let worker = Task {
            try await service.run(packageID: initial.id) { update in
                if update.job?.completedCount == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await worker.value; XCTFail("Stop after first durable asset") }
        catch { XCTAssertTrue(error is CancellationError) }
        let store = PackageLibraryStore(root: root)
        var interrupted = try XCTUnwrap(store.load(id: initial.id))
        XCTAssertEqual(interrupted.completedCount, 1)
        let archive = try store.directory(id: initial.id).appendingPathComponent(initial.archiveFilename)
        let backup = try store.directory(id: initial.id).appendingPathComponent("directory-backup.bin")
        let durable = try Data(contentsOf: archive)
        interrupted.phase = .packing
        interrupted.transaction = try PackageRecovery.snapshot(archive: archive, backup: backup)
        try store.save(interrupted)
        let output = try FileHandle(forUpdating: archive)
        try output.seek(toOffset: XCTUnwrap(interrupted.transaction).directoryOffset)
        try output.write(contentsOf: Data("unfinished append corrupts tail".utf8)); try output.close()
        _ = try await service.create(fileURLs: [second]) // Different selected pointer.
        let draft = try await service.rename(packageID: initial.id, title: "Recovered draft")
        XCTAssertTrue(draft.isDraft)
        XCTAssertNil(try store.load(id: initial.id)?.transaction)
        XCTAssertEqual(try Data(contentsOf: archive), durable)
        let result = try await service.run(packageID: draft.id) { _ in }
        XCTAssertEqual(result.job?.phase, .ready)
        XCTAssertEqual(result.job?.completedCount, 2)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = files.appendingPathComponent(name); try data.write(to: url); return url
    }
}
