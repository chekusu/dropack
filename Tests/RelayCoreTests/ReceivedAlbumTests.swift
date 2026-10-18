import XCTest
@testable import RelayCore

final class ReceivedAlbumTests: XCTestCase {
    func testStableAlbumRevisionPolicyIgnoresNameAndRejectsOldSnapshots() throws {
        let source = SourceDescriptor(kind: .zip, name: "holiday.dropack", bookmark: Data())
        var first = ImportJob(source: source, items: [])
        first.purpose = .sharedAlbum
        first.album = ShareAlbumMetadata(title: "2026-10-13")
        var next = first
        next.album = try XCTUnwrap(first.album).revised()
        XCTAssertFalse(ReceivedAlbumStore.shouldKeepExisting(first, incoming: next))
        XCTAssertTrue(ReceivedAlbumStore.shouldKeepExisting(next, incoming: first))
        XCTAssertTrue(ReceivedAlbumStore.shouldKeepExisting(next, incoming: next))
        var unrelated = next
        unrelated.album = ShareAlbumMetadata(title: "2026-10-13")
        XCTAssertFalse(ReceivedAlbumStore.shouldKeepExisting(next, incoming: unrelated))
    }

    func testIndependentPausedAlbumsSurviveCurrentCheckpointRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedAlbumStore(directory: root.appendingPathComponent("albums"))
        let current = CheckpointStore(url: root.appendingPathComponent("current.json"))
        let source = SourceDescriptor(kind: .zip, name: "trip.dropack", bookmark: Data())
        var a = ImportJob(source: source, items: [.init(id: "a", relativePath: "a.jpg", kind: .photo, byteCount: 4)])
        a.purpose = .sharedAlbum
        a.album = ShareAlbumMetadata(title: "2026-10-13")
        var b = a
        b.id = UUID(); b.album = ShareAlbumMetadata(title: "2026-10-13")
        try store.save(a); try store.save(b); try current.save(a); try current.remove()
        XCTAssertEqual(try store.load().count, 2)
        try store.remove(albumID: a.albumID)
        XCTAssertEqual(try store.load().first?.albumID, b.albumID)
    }

    func testMissingAssetRemovalRequiresExactConfirmedIdentifierAndRetainsUncertain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        try store.confirm(identity: "confirmed", jobID: UUID(), itemID: "a", assetIdentifier: "real", sourceIdentity: nil)
        _ = try store.begin(identity: "uncertain", jobID: UUID(), itemID: "b", sourceIdentity: nil)
        try store.forgetMissingAsset(identity: "confirmed", assetIdentifier: "wrong")
        XCTAssertNotNil(try store.record(for: "confirmed"))
        try store.forgetMissingAsset(identity: "uncertain", assetIdentifier: "real")
        XCTAssertEqual(try store.record(for: "uncertain")?.state, .unresolved)
        try store.forgetMissingAsset(identity: "confirmed", assetIdentifier: "real")
        XCTAssertNil(try store.record(for: "confirmed"))
    }

    func testManifestPreviewIsNotAnImportedPhotoAndHasBoundedSize() throws {
        let id = UUID().uuidString
        let preview = "__dropack_previews/\(id).preview"
        let manifest = PhotoPackageManifest(items: [.init(id: id, photoPath: "photo.jpg", previewPath: preview)])
        let photo = ImportItem(id: "photo", relativePath: "photo.jpg", kind: .photo, byteCount: 30_000_000_000)
        var sidecar = ImportItem(id: "preview", relativePath: preview, kind: .photo, byteCount: 32_000)
        let resolved = try PackageImportResolver.resolve(manifest, scanned: [photo, sidecar])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.previewPath, preview)
        sidecar.byteCount = 1024 * 1024 + 1
        XCTAssertThrowsError(try PackageImportResolver.resolve(manifest, scanned: [photo, sidecar]))
    }

    func testLegacyOrdinarySourcesMigrateOutOfAlbumLibraryWithoutLosingCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedAlbumStore(directory: root.appendingPathComponent("albums"))
        for (kind, name, itemID) in [(SourceKind.folder, "USB Camera", "folder-1"),
                                     (.mediaFile, "video.mov", "media-1"),
                                     (.zip, "export.zip", "dropack:validated"),
                                     (.zip, "renamed.dropack", "zip-1")] {
            var legacy = ImportJob(source: .init(kind: kind, name: name, bookmark: Data()),
                items: [.init(id: itemID, relativePath: "photo.jpg", kind: .photo, byteCount: 4)])
            legacy.album = ShareAlbumMetadata(title: "Former synthetic album")
            legacy.systemAlbumIdentifier = "old-system-album"
            legacy.items[0].albumMembershipPending = true
            legacy.phase = .paused
            // Simulate a pre-classification on-disk library entry directly.
            try CheckpointStore(url: store.directory.appendingPathComponent(legacy.album!.id.uuidString + ".json")).save(legacy)
        }
        XCTAssertTrue(try store.load().isEmpty)
        let imports = try store.loadOneTimeImports()
        XCTAssertEqual(imports.count, 4)
        XCTAssertTrue(imports.allSatisfy { $0.isOneTimeImport && $0.phase == .paused && $0.pendingCount == 1 })
        XCTAssertTrue(imports.allSatisfy { $0.album == nil && $0.systemAlbumIdentifier == nil && $0.membershipPendingCount == 0 })
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.loadOneTimeImports().count, 4, "Migration is idempotent")
    }

    func testLegacyValidatedDropackRemainsSharedAndKeepsSenderTitle() throws {
        var legacy = ImportJob(source: .init(kind: .zip, name: "renamed-by-receiver.dropack", bookmark: Data()),
            items: [.init(id: "dropack:media-id", relativePath: "photo.jpg", kind: .photo, byteCount: 4)])
        legacy.album = ShareAlbumMetadata(title: "Sender's holiday")
        let decoded = try JSONDecoder().decode(ImportJob.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.purpose)
        legacy.migrateImportPurpose()
        XCTAssertTrue(legacy.isSharedAlbum)
        XCTAssertEqual(legacy.purpose, .sharedAlbum)
        XCTAssertEqual(legacy.displayTitle, "Sender's holiday")
    }
}
