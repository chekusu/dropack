import CryptoKit
import Foundation
import UIKit
import XCTest
import ZIPFoundation
@testable import Dropack

@MainActor
final class OutgoingAlbumIntegrationTests: XCTestCase {
    private var root: URL!
    private var files: URL!
    override func setUp() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = temporary.appendingPathComponent("Library")
        files = temporary.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func testFileHashIncludesEveryChunkAndRejectsShortOrGrowingSources() throws {
        let file = files.appendingPathComponent("multi-chunk.mov")
        var data = Data(repeating: 0x6A, count: 3 * 1024 * 1024 + 17)
        data[1024 * 1024] = 0x9B
        data[data.count - 1] = 0x2C
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try PackageFileAccess.hash(file, byteCount: UInt64(data.count)), expected)
        XCTAssertThrowsError(try PackageFileAccess.hash(file, byteCount: UInt64(data.count - 1)))
        XCTAssertThrowsError(try PackageFileAccess.hash(file, byteCount: UInt64(data.count + 1)))
    }

    func testFilesCreateFullAlbumAndSmallPreviewWithoutPhotosOrSourceMutation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let url = files.appendingPathComponent("camera.jpg")
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try original.write(to: url)
        let service = PhotoPackageService(root: root)
        let job = try await service.create(fileURLs: [url, url])
        XCTAssertEqual(job.totalCount, 1)
        XCTAssertEqual(job.album?.senderName, ShareAlbumNaming.senderName(deviceName: AppPreferences.shared.sharingName)
            ?? ShareAlbumNaming.senderName(deviceName: UIDevice.current.name))
        XCTAssertTrue(job.isFileAlbum)
        XCTAssertNil(job.linkedPhotosAlbumIdentifier)
        let ready = try await service.run(packageID: job.id) { _ in }
        let finished = try XCTUnwrap(ready.job)
        XCTAssertEqual(finished.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let packagedItem = try XCTUnwrap(finished.assets.first?.manifestItem)
        XCTAssertEqual(packagedItem.photoSHA256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        let archive = try Archive(url: XCTUnwrap(ready.archiveURL), accessMode: .read)
        let preview = try XCTUnwrap(archive[XCTUnwrap(packagedItem.previewPath)])
        XCTAssertLessThan(preview.uncompressedSize, 1024 * 1024)
        var encodedManifest = Data()
        _ = try archive.extract(XCTUnwrap(archive[PhotoPackageManifest.filename])) { encodedManifest.append($0) }
        let manifest = try JSONDecoder().decode(PhotoPackageManifest.self, from: encodedManifest)
        XCTAssertEqual(manifest.album?.id, job.stableAlbumID)
        XCTAssertEqual(manifest.album?.senderName, job.album?.senderName)
        XCTAssertFalse(String(decoding: encodedManifest, as: UTF8.self).contains("bookmark"))
    }

    func testFileChangedAfterSelectionStopsWithoutSavingOrModifyingSource() async throws {
        let url = files.appendingPathComponent("camera.jpg")
        try Data("before".utf8).write(to: url)
        let service = PhotoPackageService(root: root)
        let job = try await service.create(fileURLs: [url])
        let changed = Data("changed after selection".utf8)
        try changed.write(to: url)
        do { _ = try await service.run(packageID: job.id) { _ in }; XCTFail("Changed input must not silently enter snapshot") }
        catch { XCTAssertTrue(error is MediaSourceError) }
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertEqual(try PackageLibraryStore(root: root).load(id: job.id)?.completedCount, 0)
    }

    func testRenamedRevisionKeepsOldArchiveAndSharesLatestSnapshotOnly() async throws {
        let url = files.appendingPathComponent("photo.jpg")
        try Data("original photo resource".utf8).write(to: url)
        let service = PhotoPackageService(root: root)
        let first = try await service.create(fileURLs: [url])
        let ready = try await service.run(packageID: first.id) { _ in }
        let oldURL = try XCTUnwrap(ready.archiveURL)
        let oldBytes = try Data(contentsOf: oldURL)
        let renamed = try await service.rename(packageID: first.id, title: "海边旅行")
        XCTAssertEqual(renamed.stableAlbumID, first.stableAlbumID)
        XCTAssertNotEqual(renamed.id, first.id)
        XCTAssertEqual(renamed.album?.revision, 2)
        XCTAssertEqual(renamed.album?.senderName, first.album?.senderName)
        do { _ = try await service.shareURL(packageID: first.id, format: .dropack); XCTFail("Do not send stale ready revision") }
        catch { XCTAssertTrue(error is PackageModelError) }
        _ = try await service.run(packageID: renamed.id) { _ in }
        let newURL = try await service.shareURL(packageID: first.id, format: .dropack)
        XCTAssertEqual(newURL.lastPathComponent, "海边旅行.dropack")
        XCTAssertNotEqual(newURL, oldURL)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        let library = try await service.library()
        XCTAssertEqual(library.count, 1)
        try await service.deletePackage(id: renamed.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
