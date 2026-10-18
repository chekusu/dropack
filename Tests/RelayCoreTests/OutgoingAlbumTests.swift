import Foundation
import XCTest
@testable import RelayCore

final class OutgoingAlbumTests: XCTestCase {
    func testNewAlbumHasMeaningfulFilenameAndStableSnapshotIdentity() throws {
        let job = PackageJob(assetIdentifiers: ["photo", "video"])
        XCTAssertEqual(job.stableAlbumID, job.id)
        XCTAssertEqual(job.album?.snapshotID, job.id)
        XCTAssertFalse(job.archiveFilename.contains(job.id.uuidString.prefix(8)))
        XCTAssertTrue(job.archiveFilename.hasSuffix(".dropack"))
        XCTAssertEqual(job.displayTitle, ShareAlbumNaming.title(dates: [], fallback: job.createdAt))
        try job.validate()
    }

    func testManifestAlbumAndPreviewAreOptionalForLegacyVersionOne() throws {
        let id = UUID().uuidString
        let legacy = Data("{\"version\":1,\"items\":[{\"id\":\"\(id)\",\"photoPath\":\"a.jpg\",\"isLivePhoto\":false}]}".utf8)
        let manifest = try JSONDecoder().decode(PhotoPackageManifest.self, from: legacy)
        try manifest.validate()
        XCTAssertNil(manifest.album)
        XCTAssertNil(manifest.items[0].previewPath)
        var modern = manifest
        modern.album = ShareAlbumMetadata(title: "2026-10-13")
        modern.items[0].previewPath = "__dropack_previews/\(id).preview"
        try modern.validate()
        XCTAssertEqual(try JSONDecoder().decode(PhotoPackageManifest.self, from: JSONEncoder().encode(modern)), modern)
        modern.items[0].previewPath = "../../escape.jpg"
        XCTAssertThrowsError(try modern.validate())
    }

    func testSenderLabelPersistsThroughLocalPackageCheckpoint() throws {
        let job = PackageJob(assetIdentifiers: ["photo"], senderName: "iPad")
        let encoded = try JSONEncoder().encode(job)
        let restored = try JSONDecoder().decode(PackageJob.self, from: encoded)
        try restored.validate()
        XCTAssertEqual(restored.album?.senderName, "iPad")
        XCTAssertEqual(restored.stableAlbumID, job.stableAlbumID)
    }

    func testLegacyJobKeepsImmutableFilenameButDisplaysCaptureDate() throws {
        var job = PackageJob(assetIdentifiers: ["legacy"])
        job.archiveFilename = "Dropack-AABBCCDD.dropack"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "album")
        object.removeValue(forKey: "linkedPhotosAlbumIdentifier")
        let legacy = try JSONDecoder().decode(PackageJob.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        XCTAssertNil(legacy.album)
        XCTAssertEqual(legacy.archiveFilename, "Dropack-AABBCCDD.dropack")
        XCTAssertEqual(legacy.displayTitle, ShareAlbumNaming.title(dates: [], fallback: legacy.createdAt))
    }

    func testLibraryOnlyShowsNewestRevisionWhilePreservingOldSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PackageLibraryStore(root: root)
        try store.prepare()
        let old = PackageJob(assetIdentifiers: ["one"])
        var new = PackageJob(assetIdentifiers: ["one", "two"])
        new.album = try old.album?.revised(title: "海边旅行")
        new.id = try XCTUnwrap(new.album?.snapshotID)
        try store.save(old); try store.save(new)
        XCTAssertEqual(try store.entries().map(\.id), [new.id])
        XCTAssertEqual(try store.allEntries().count, 2)
        XCTAssertNotNil(try store.load(id: old.id))
        XCTAssertEqual(try store.latest(albumID: old.stableAlbumID)?.displayTitle, "海边旅行")
        XCTAssertEqual(try store.latest(albumID: old.stableAlbumID)?.album?.revision, 2)
    }

    func testLegacySharingUsesFriendlyAliasWithoutRenamingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Dropack-AABBCCDD.zip")
        let bytes = Data(repeating: 7, count: 22)
        try bytes.write(to: archive)
        let alias = try PackageFileFormat.dropack.shareURL(for: archive, title: "2026-10-13")
        XCTAssertEqual(alias.lastPathComponent, "2026-10-13.dropack")
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try Data(contentsOf: alias), bytes)
        XCTAssertEqual(try PackageFileFormat.dropack.shareURL(for: archive, title: "2026-10-13"), alias)
    }

    func testFileBookmarksNeverLeavePortableManifest() throws {
        var asset = PackageAsset(assetIdentifier: "file:local")
        asset.fileSource = PackageFileSource(bookmark: Data("private bookmark".utf8), relativePath: "DCIM/a.jpg",
            isFolder: true, byteCount: 12, modifiedAt: nil)
        let manifest = PhotoPackageManifest(items: [.init(id: asset.id, photoPath: "media/a.jpg")],
            album: ShareAlbumMetadata(title: "2026-10-13"))
        let json = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        XCTAssertFalse(json.contains("bookmark"))
        XCTAssertFalse(json.contains("file:local"))
        XCTAssertFalse(json.contains("DCIM"))
    }
}
