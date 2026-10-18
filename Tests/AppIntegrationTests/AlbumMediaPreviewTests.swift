import CryptoKit
import XCTest
import ZIPFoundation
@testable import Dropack

final class AlbumMediaPreviewTests: XCTestCase {
    func testOriginalSelectionNeverUsesEmbeddedThumbnailAndChoosesVideoForVideoItem() {
        XCTAssertEqual(AlbumMediaPreviewPolicy.primaryPath(photo: "media/a/original.heic", video: "media/a/paired.mov"), "media/a/original.heic")
        XCTAssertEqual(AlbumMediaPreviewPolicy.primaryPath(photo: nil, video: "media/b/original.mov"), "media/b/original.mov")
        XCTAssertNil(AlbumMediaPreviewPolicy.primaryPath(photo: "__dropack_previews/a.jpg", video: nil))
        for path in ["../a.jpg", "/a.jpg", "a/../../a.mov", "__dropack_previews/a.jpg", "folder/info.json", "__MACOSX/a.jpg"] {
            XCTAssertFalse(AlbumMediaPreviewPolicy.isOriginalPath(path), path)
        }
        XCTAssertEqual(AlbumMediaPreviewPolicy.requiredSpace(for: .max), .max)
    }

    func testFolderPreviewCannotFollowSymlinkOutsideSelectedFolder() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.mov")
        try Data("video".utf8).write(to: outside)
        let link = folder.appendingPathComponent("linked.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try AlbumMediaPreviewPolicy.sourceFile(root: folder, relativePath: "linked.mov", isFolder: true))
        XCTAssertEqual(try Data(contentsOf: outside), Data("video".utf8))
    }

    func testExtractsOnlyExactOriginalAndLeaseCleanupPreservesArchiveAndOtherPreviews() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try archiveFixture(root)
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let service = AlbumMediaPreviewService(temporaryRoot: previewRoot)
        let originalArchive = try Data(contentsOf: fixture.archive)
        let first = try await service.sentArchive(fixture.archive, asset: fixture.asset, progress: { _ in })
        let second = try await service.sentArchive(fixture.archive, asset: fixture.asset, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: first.url), fixture.bytes)
        XCTAssertEqual(first.url.pathExtension, "mov")
        XCTAssertNotEqual(first.url, second.url)
        first.close(); first.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), originalArchive)
        second.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previewRoot.path), [])
    }

    func testIntegrityFailureRemovesPartialPreviewWithoutChangingSource() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try archiveFixture(root)
        fixture.asset.manifestItem?.videoSHA256 = String(repeating: "0", count: 64)
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let service = AlbumMediaPreviewService(temporaryRoot: previewRoot)
        let originalArchive = try Data(contentsOf: fixture.archive)
        do {
            _ = try await service.sentArchive(fixture.archive, asset: fixture.asset, progress: { _ in })
            XCTFail("A different original must never be shown after an integrity failure")
        } catch { XCTAssertTrue(error is AlbumMediaPreviewError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previewRoot.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), originalArchive)
    }

    func testCancellationCannotPublishOrLeavePreviewFiles() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try archiveFixture(root)
        let previewRoot = root.appendingPathComponent("previews", isDirectory: true)
        let service = AlbumMediaPreviewService(temporaryRoot: previewRoot)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.sentArchive(fixture.archive, asset: fixture.asset, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Cancelled preview should not return a lease") }
        catch { XCTAssertTrue(error is CancellationError) }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: previewRoot.path)) ?? []
        XCTAssertTrue(children.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.archive.path))
    }

    func testDirectFileLeaseNeverDeletesSourceOnClose() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.mov")
        let bytes = Data("real original file".utf8)
        try bytes.write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let source = PackageFileSource(bookmark: try url.bookmarkData(), relativePath: url.lastPathComponent,
            isFolder: false, byteCount: UInt64(bytes.count), modifiedAt: values.contentModificationDate)
        let service = AlbumMediaPreviewService(temporaryRoot: root.appendingPathComponent("previews"))
        let lease = try await service.file(source)
        XCTAssertEqual(lease.url.standardizedFileURL, url.standardizedFileURL)
        lease.close()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSpaceLossDuringExtractionRemovesPartialPreviewAndPreservesArchive() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try archiveFixture(root)
        let previewRoot = root.appendingPathComponent("previews")
        let capacity = PreviewCapacityProbe()
        let service = AlbumMediaPreviewService(temporaryRoot: previewRoot,
            availableCapacity: { _ in capacity.next() }, spaceCheckInterval: 1024 * 1024)
        let originalArchive = try Data(contentsOf: fixture.archive)
        do {
            _ = try await service.sentArchive(fixture.archive, asset: fixture.asset, progress: { _ in })
            XCTFail("The preview must stop if concurrent writes consume its required space")
        } catch {
            guard case MediaSourceError.insufficientSpace = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertGreaterThanOrEqual(capacity.calls, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previewRoot.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), originalArchive)
    }

    func testCancellingAWaitingFileProviderCancelsCoordinationBeforeReading() async throws {
        let started = expectation(description: "Provider is waiting to grant access")
        let provider = PreviewWaitingProvider(onStart: { started.fulfill() })
        let coordinator = AlbumPreviewFileCoordinator(read: { url, accessor in
            provider.read(url, accessor: accessor)
        }, cancel: { provider.cancel() })
        let task = Task.detached {
            try await coordinator.read(URL(fileURLWithPath: "/unused-original.mov")) { _ in
                provider.recordRead(); return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled coordination cannot publish a preview") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(provider.cancelled)
        XCTAssertFalse(provider.wasRead)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DropackPreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func archiveFixture(_ root: URL) throws -> (archive: URL, asset: PackageAsset, bytes: Data) {
        let url = root.appendingPathComponent("album.dropack")
        let archive = try Archive(url: url, accessMode: .create)
        let bytes = Data(repeating: 0x4f, count: 2 * 1024 * 1024 + 17)
        let path = "media/video/original.mov"
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .none) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let preview = Data("small thumbnail must not be selected".utf8)
        try archive.addEntry(with: "__dropack_previews/video.jpg", type: .file, uncompressedSize: Int64(preview.count), compressionMethod: .none) { offset, count in
            preview.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let entry = try XCTUnwrap(archive[path])
        var asset = PackageAsset(assetIdentifier: "fixture-video")
        asset.kind = .video
        asset.manifestItem = PhotoPackageManifestItem(id: asset.id, videoPath: path,
            videoSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            previewPath: "__dropack_previews/video.jpg")
        asset.archiveRecords = [.init(path: path, byteCount: entry.uncompressedSize, checksum: entry.checksum)]
        return (url, asset, bytes)
    }
}

private final class PreviewCapacityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count == 1 ? .max : 0
    }
}

private final class PreviewWaitingProvider: @unchecked Sendable {
    private let condition = NSCondition()
    private let onStart: @Sendable () -> Void
    private var stopped = false
    private var accessed = false
    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }
    var cancelled: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    var wasRead: Bool { condition.lock(); defer { condition.unlock() }; return accessed }
    func recordRead() { condition.lock(); accessed = true; condition.unlock() }
    func read(_ url: URL, accessor: (URL) -> Void) -> Error? {
        condition.lock()
        onStart()
        let deadline = Date().addingTimeInterval(5)
        while !stopped && condition.wait(until: deadline) {}
        let shouldRead = !stopped
        condition.unlock()
        if shouldRead { accessor(url) }
        return nil
    }
    func cancel() {
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
    }
}
