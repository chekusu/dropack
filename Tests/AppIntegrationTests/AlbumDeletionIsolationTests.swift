import Foundation
import XCTest
@testable import Dropack

/// Deletion is local housekeeping. These fixtures contain durable Photos
/// identifiers, but never request permission or mutate the device photo library.
@MainActor
final class AlbumDeletionIsolationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    func testDeleteSelectedReceivedAlbumPreservesPhotosMembersAndDedupReceipts() async throws {
        let first = try receivedFixture(title: "同名相册", marker: "a")
        let other = try receivedFixture(title: "同名相册", marker: "b")
        let writer = DeletionIsolationPhotoWriter(jobs: [first, other])
        let controller = try makeController(selected: first, jobs: [first, other], writer: writer)
        try await settle(controller)
        let before = await writer.snapshot()

        let deleted = await controller.deleteAlbum(albumID: first.albumID)

        XCTAssertTrue(deleted)
        XCTAssertNil(controller.job)
        XCTAssertEqual(controller.library.map(\.albumID), [other.albumID])
        XCTAssertNil(try checkpoint.load())
        XCTAssertEqual(try receivedStore.load().map(\.albumID), [other.albumID])
        let after = await writer.snapshot()
        XCTAssertEqual(after, before, "Deleting a local album must not call any Photos operation")
        try assertReceiptAndSourcePreserved(first)
        try assertReceiptAndSourcePreserved(other)
    }

    func testDeleteHistoricalReceivedAlbumKeepsCurrentAlbumAndItsPhotosMembers() async throws {
        let old = try receivedFixture(title: "同名相册", marker: "c")
        let current = try receivedFixture(title: "同名相册", marker: "d")
        let writer = DeletionIsolationPhotoWriter(jobs: [old, current])
        let controller = try makeController(selected: current, jobs: [old, current], writer: writer)
        try await settle(controller)
        let before = await writer.snapshot()

        let deleted = await controller.deleteAlbum(albumID: old.albumID)

        XCTAssertTrue(deleted)
        XCTAssertEqual(controller.job?.albumID, current.albumID)
        XCTAssertEqual(try checkpoint.load()?.albumID, current.albumID)
        XCTAssertEqual(controller.library.map(\.albumID), [current.albumID])
        let after = await writer.snapshot()
        XCTAssertEqual(after, before)
        try assertReceiptAndSourcePreserved(old)
        try assertReceiptAndSourcePreserved(current)
    }

    func testClearSelectedImportPreservesPhotosMembersOtherAlbumAndReceipts() async throws {
        let clearing = try receivedFixture(title: "待清理", marker: "e")
        let retained = try receivedFixture(title: "保留", marker: "f")
        let writer = DeletionIsolationPhotoWriter(jobs: [clearing, retained])
        let controller = try makeController(selected: clearing, jobs: [clearing, retained], writer: writer)
        try await settle(controller)
        let before = await writer.snapshot()

        controller.clearJob()
        try await settle(controller)

        XCTAssertNil(controller.job)
        XCTAssertNil(try checkpoint.load())
        XCTAssertEqual(try receivedStore.load().map(\.albumID), [retained.albumID])
        let after = await writer.snapshot()
        XCTAssertEqual(after, before)
        try assertReceiptAndSourcePreserved(clearing)
        try assertReceiptAndSourcePreserved(retained)
    }

    func testDeleteOutgoingLogicalAlbumRemovesOnlyItsSnapshotsAndKeepsSourcesAndMapping() async throws {
        let packages = root.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: packages)
        var first = try await service.create(assetIdentifiers: ["photos-original-a"])
        let other = try await service.create(assetIdentifiers: ["photos-original-b"])
        let store = PackageLibraryStore(root: packages)
        let original = root.appendingPathComponent("original.mov")
        let originalBytes = Data("untouched original resource".utf8)
        try originalBytes.write(to: original)
        let source = PackageFileSource(bookmark: try original.bookmarkData(options: [],
            includingResourceValuesForKeys: nil, relativeTo: nil), relativePath: original.lastPathComponent,
            isFolder: false, byteCount: UInt64(originalBytes.count), modifiedAt: nil)
        first.assets[0].fileSource = source
        first.linkedPhotosAlbumIdentifier = "ordinary-photos-album"
        try store.save(first)
        var revision = PackageJob(assetIdentifiers: first.selectedAssetIdentifiers)
        revision.assets[0].fileSource = source
        revision.album = try first.album?.revised()
        revision.album?.snapshotID = revision.id
        revision.linkedPhotosAlbumIdentifier = "ordinary-photos-album"
        try store.save(revision)
        try store.select(revision.id)
        let mapping = root.appendingPathComponent("system-albums.json")
        let mappingBytes = Data("existing independent Photos mapping".utf8)
        try mappingBytes.write(to: mapping)

        try await service.deletePackage(id: first.id)

        XCTAssertNil(try store.load(id: first.id))
        XCTAssertNil(try store.load(id: revision.id))
        XCTAssertNotNil(try store.load(id: other.id))
        XCTAssertNil(try store.selectedID())
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: mapping), mappingBytes)
    }

    func testDeletingOlderSnapshotClearsCurrentNewerRevisionOfSameLogicalAlbum() async throws {
        let packages = root.appendingPathComponent("Packages")
        let service = PhotoPackageService(root: packages)
        let first = try await service.create(assetIdentifiers: ["not-a-real-photos-identifier"])
        let revision = try await service.rename(packageID: first.id, title: "第二版")
        XCTAssertEqual(revision.stableAlbumID, first.stableAlbumID)
        let controller = PackageController(service: service)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isBusy {
            guard ContinuousClock.now < deadline else { return XCTFail("Restoration did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.job?.id, revision.id)

        let deleted = await controller.deletePackage(id: first.id)

        XCTAssertTrue(deleted)
        XCTAssertNil(controller.job, "All revisions belong to the deleted logical album")
        XCTAssertNil(controller.archiveURL)
        XCTAssertFalse(controller.requiresReset)
        XCTAssertFalse(controller.canResume)
        XCTAssertTrue(controller.library.isEmpty)
        XCTAssertNil(try PackageLibraryStore(root: packages).selectedID())
    }

    private var checkpoint: CheckpointStore { CheckpointStore(url: root.appendingPathComponent("progress.json")) }
    private var receivedStore: ReceivedAlbumStore { ReceivedAlbumStore(directory: root.appendingPathComponent("received-albums")) }
    private var history: ImportHistoryStore { ImportHistoryStore(url: root.appendingPathComponent("import-history.sqlite")) }

    private func receivedFixture(title: String, marker: Character) throws -> ImportJob {
        let sourceURL = root.appendingPathComponent(UUID().uuidString + ".dropack")
        try Data("source retained after deleting \(marker)".utf8).write(to: sourceURL)
        let source = SourceDescriptor(kind: .zip, name: sourceURL.lastPathComponent,
            bookmark: try sourceURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        var item = ImportItem(id: "dropack:" + UUID().uuidString, relativePath: "photo.jpg",
            kind: .photo, byteCount: 3, state: .saved)
        item.assetIdentifier = "photos-asset-\(marker)"
        item.expectedSHA256 = String(repeating: String(marker), count: 64)
        item.contentIdentity = try ImportContentIdentity.verifiedManifest(item)
        var job = ImportJob(source: source, items: [item])
        job.album = ShareAlbumMetadata(title: title)
        job.purpose = .sharedAlbum
        job.systemAlbumIdentifier = "photos-album-\(marker)"
        job.phase = .completed
        return job
    }

    private func makeController(selected: ImportJob, jobs: [ImportJob], writer: DeletionIsolationPhotoWriter) throws -> ImportController {
        for var job in jobs {
            try receivedStore.save(job)
            try history.preserve(&job)
        }
        try checkpoint.save(selected)
        return ImportController(checkpoint: checkpoint, photoWriter: writer, history: history)
    }

    private func assertReceiptAndSourcePreserved(_ job: ImportJob) throws {
        let item = try XCTUnwrap(job.items.first)
        let receipt = try XCTUnwrap(history.record(for: XCTUnwrap(item.contentIdentity)))
        XCTAssertEqual(receipt.state, .confirmed)
        XCTAssertEqual(receipt.assetIdentifier, item.assetIdentifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(job.source.name).path))
    }

    private func settle(_ controller: ImportController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isBusy || controller.isPreparing {
            guard ContinuousClock.now < deadline else { return XCTFail(controller.message ?? "Deletion did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.requiresReset, controller.message ?? "")
    }
}

private actor DeletionIsolationPhotoWriter: PhotoLibraryWriting {
    struct Snapshot: Equatable, Sendable {
        let calls: Int
        let assets: Set<String>
        let members: [UUID: Set<String>]
    }
    private var calls = 0
    private let assets: Set<String>
    private let members: [UUID: Set<String>]

    init(jobs: [ImportJob]) {
        assets = Set(jobs.flatMap { $0.items.compactMap(\.assetIdentifier) })
        members = Dictionary(uniqueKeysWithValues: jobs.map { ($0.albumID, Set($0.items.compactMap(\.assetIdentifier))) })
    }
    func snapshot() -> Snapshot { Snapshot(calls: calls, assets: assets, members: members) }
    func authorize() async throws { calls += 1 }
    func save(item: ImportItem, fileURL: URL, pairedVideoURL: URL?) async throws -> String? { calls += 1; return nil }
    func assetPresence(_ identifier: String) async -> SystemAssetPresence { calls += 1; return assets.contains(identifier) ? .available : .missing }
    func ensureAlbum(id: UUID, title: String) async throws -> String? { calls += 1; return id.uuidString }
    func addToAlbum(assetIdentifiers: [String], id: UUID, title: String) async throws -> String? { calls += 1; return id.uuidString }
    func albumPresence(id: UUID) async throws -> SystemAssetPresence { calls += 1; return members[id] == nil ? .missing : .available }
    func albumMembers(id: UUID) async throws -> [String]? { calls += 1; return members[id].map(Array.init) }
}
