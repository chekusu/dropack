import CryptoKit
import Foundation
import ImageIO
import XCTest
import ZIPFoundation
@testable import Dropack

/// Filesystem/ZIP integration with app services; no permissions, simulator media
/// mutations, or PhotoKit originals are needed for the library identity tests.
@MainActor
final class PackageLibraryIntegrationTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    func testCreateAThenBShareByIDAndDeleteAWithoutRepackingOrChangingB() async throws {
        let service = PhotoPackageService(root: root)
        let a = try await service.create(assetIdentifiers: ["only-A"])
        try finalizeFixture(a, content: Data("content A".utf8))
        let b = try await service.create(assetIdentifiers: ["only-B", "only-B"])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(b.selectedAssetIdentifiers, ["only-B"])
        try finalizeFixture(b, content: Data("different content B".utf8))
        let store = PackageLibraryStore(root: root)
        let bArchive = try store.directory(id: b.id).appendingPathComponent(b.archiveFilename)
        let beforeHash = SHA256.hash(data: try Data(contentsOf: bArchive))
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: bArchive.path)
        let bShare = try await service.shareURL(packageID: b.id, format: .dropack)
        let aShare = try await service.shareURL(packageID: a.id, format: .dropack)
        XCTAssertEqual(bShare, bArchive)
        XCTAssertNotEqual(aShare, bShare)
        _ = try await service.activate(packageID: a.id)
        let explicitB = try await service.shareURL(packageID: b.id, format: .zip)
        XCTAssertEqual(explicitB.deletingLastPathComponent(), bShare.deletingLastPathComponent())
        for _ in 0..<3 { _ = try await service.shareURL(packageID: b.id, format: .dropack) }
        try await service.deletePackage(id: a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aShare.path))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: bArchive)), beforeHash)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: bArchive.path)
        XCTAssertEqual(beforeAttributes[.modificationDate] as? Date, afterAttributes[.modificationDate] as? Date)
        XCTAssertEqual(beforeAttributes[.systemFileNumber] as? NSNumber, afterAttributes[.systemFileNumber] as? NSNumber)
        let remaining = try await service.library()
        XCTAssertEqual(remaining.map(\.id), [b.id])
        let ready = try await service.run(packageID: b.id) { _ in XCTFail("A finished archive must not be repackaged.") }
        XCTAssertEqual(ready.job?.id, b.id)
        XCTAssertEqual(ready.archiveURL, bShare)
    }

    func testLegacyReadyZIPMigratesAndSharesWithoutRenamingOrReadingOriginalPhoto() async throws {
        let store = PackageLibraryStore(root: root)
        var old = PackageJob(assetIdentifiers: ["no-longer-authorized-photo"])
        old.archiveFilename = "PhotoRelay-old.zip"
        try store.save(old)
        try finalizeFixture(old, content: Data("preserved original".utf8))
        let ready = try XCTUnwrap(store.load(id: old.id))
        try PackageRecovery.save(ready, to: root.appendingPathComponent("package.json"))
        try FileManager.default.removeItem(at: store.checkpointURL(id: old.id))
        let service = PhotoPackageService(root: root)
        let restored = try await service.restore()
        XCTAssertEqual(restored.job?.id, old.id)
        XCTAssertEqual(restored.archiveURL?.pathExtension, "zip")
        let shared = try await service.shareURL(packageID: old.id, format: .dropack)
        XCTAssertEqual(shared.pathExtension, "dropack")
        XCTAssertEqual(try PackageRecovery.fileSize(shared), ready.finalizedSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path))
    }

    func testRapidControllerShareRequestsReuseReadyArchiveWithoutStartingPackaging() async throws {
        let service = PhotoPackageService(root: root)
        let initial = try await service.create(assetIdentifiers: ["unchanged-photo-unavailable-to-PhotoKit"])
        try finalizeFixture(initial, content: Data(repeating: 0x42, count: 2 * 1024 * 1024))
        let controller = PackageController(service: service)
        try await waitUntilIdle(controller)
        let archive = try XCTUnwrap(controller.archiveURL)
        let original = try FileManager.default.attributesOfItem(atPath: archive.path)
        let checksum = SHA256.hash(data: try Data(contentsOf: archive))
        var createdSnapshots = 0
        let urls = await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<20 {
                group.addTask { @MainActor in
                    await controller.shareURL(packageID: initial.id, onCreated: { _ in createdSnapshots += 1 })
                }
            }
            var urls: [URL] = []
            for await value in group { if let value { urls.append(value) } }
            return urls
        }
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0 == archive })
        XCTAssertEqual(createdSnapshots, 0, "Repeated share requests must not create or start another packaging operation.")
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.canPause)
        let after = try FileManager.default.attributesOfItem(atPath: archive.path)
        XCTAssertEqual(original[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(original[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: archive)), checksum)
        XCTAssertEqual(controller.library.map(\.id), [initial.id])
    }

    func testInterruptedHistoricalAppendRollsBackOnlyItsOwnPackage() async throws {
        let service = PhotoPackageService(root: root)
        let a = try await service.create(assetIdentifiers: ["a"])
        let b = try await service.create(assetIdentifiers: ["b"])
        let store = PackageLibraryStore(root: root)
        let archiveA = try store.directory(id: a.id).appendingPathComponent(a.archiveFilename)
        let archiveB = try store.directory(id: b.id).appendingPathComponent(b.archiveFilename)
        let original = try Data(contentsOf: archiveA)
        let untouchedB = try Data(contentsOf: archiveB)
        var interrupted = a
        interrupted.phase = .packing
        interrupted.transaction = try PackageRecovery.snapshot(archive: archiveA,
            backup: store.directory(id: a.id).appendingPathComponent("directory-backup.bin"))
        try store.save(interrupted)
        try Data(repeating: 0x99, count: 4096).write(to: archiveA)
        let resumed = try await service.activate(packageID: a.id)
        XCTAssertEqual(resumed.job?.phase, .paused)
        XCTAssertNil(resumed.job?.transaction)
        XCTAssertEqual(try Data(contentsOf: archiveA), original)
        XCTAssertEqual(try Data(contentsOf: archiveB), untouchedB)
        do {
            _ = try await service.shareURL(packageID: a.id, format: .dropack)
            XCTFail("A paused package must never be offered for sharing.")
        } catch { XCTAssertTrue(error is PackageModelError) }
        let library = try await service.library()
        XCTAssertEqual(library.count, 2)
    }

    func testControllerHistoricalShareKeepsCurrentIDAndMissingPreviewDoesNotChangeUIState() async throws {
        let service = PhotoPackageService(root: root)
        let a = try await service.create(assetIdentifiers: ["missing-a"])
        try finalizeFixture(a, content: Data("a".utf8))
        let b = try await service.create(assetIdentifiers: ["missing-b"])
        try finalizeFixture(b, content: Data("b".utf8))
        let controller = PackageController(service: service)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.job?.id, b.id)
        let sharedA = await controller.shareURL(packageID: a.id)
        XCTAssertEqual(sharedA?.deletingLastPathComponent().lastPathComponent, a.id.uuidString)
        XCTAssertEqual(controller.job?.id, b.id)
        let oldMessage = controller.message
        let preview = await controller.loadThumbnail(packageID: a.id, itemID: a.assets[0].id)
        XCTAssertNil(preview)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.message, oldMessage)
        XCTAssertEqual(controller.library.count, 2)
        let deleted = await controller.deletePackage(id: a.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(controller.job?.id, b.id)
        XCTAssertEqual(controller.library.map(\.id), [b.id])
    }

    func testBrokenSelectedArchiveCanBeClearedWithoutBlockingOrDeletingHealthyHistory() async throws {
        let service = PhotoPackageService(root: root)
        let healthy = try await service.create(assetIdentifiers: ["healthy"])
        try finalizeFixture(healthy, content: Data("keep me".utf8))
        let broken = try await service.create(assetIdentifiers: ["broken"])
        try finalizeFixture(broken, content: Data("missing archive".utf8))
        let store = PackageLibraryStore(root: root)
        try FileManager.default.removeItem(at: store.directory(id: broken.id).appendingPathComponent(broken.archiveFilename))
        let controller = PackageController(service: service)
        try await waitUntilIdle(controller)
        XCTAssertTrue(controller.requiresReset)
        XCTAssertEqual(controller.recoveryFailureID, broken.id)
        XCTAssertEqual(controller.job?.id, broken.id)
        let healthyShare = await controller.shareURL(packageID: healthy.id)
        XCTAssertNotNil(healthyShare)
        controller.clear()
        try await waitUntilIdle(controller)
        XCTAssertFalse(controller.requiresReset)
        XCTAssertNil(controller.job)
        XCTAssertEqual(controller.library.map(\.id), [healthy.id])
        XCTAssertNotNil(try store.load(id: healthy.id))
        let new = try await service.create(assetIdentifiers: ["newest selection"])
        XCTAssertNotEqual(new.id, healthy.id)
        XCTAssertNotNil(try store.load(id: healthy.id))
    }

    func testMalformedSelectedJournalRemainsDeletableAndHealthyLibraryStillShares() async throws {
        let service = PhotoPackageService(root: root)
        let healthy = try await service.create(assetIdentifiers: ["healthy"])
        try finalizeFixture(healthy, content: Data("healthy payload".utf8))
        let damaged = try await service.create(assetIdentifiers: ["damaged"])
        let store = PackageLibraryStore(root: root)
        try Data("invalid JSON".utf8).write(to: store.checkpointURL(id: damaged.id))
        let controller = PackageController(service: service)
        try await waitUntilIdle(controller)
        XCTAssertTrue(controller.requiresReset)
        XCTAssertNil(controller.job)
        XCTAssertEqual(controller.recoveryFailureID, damaged.id)
        XCTAssertEqual(controller.library.count, 2)
        XCTAssertNotNil(controller.library.first(where: { $0.id == damaged.id })?.issue)
        let healthyShare = await controller.shareURL(packageID: healthy.id)
        XCTAssertNotNil(healthyShare)
        controller.clear()
        try await waitUntilIdle(controller)
        XCTAssertFalse(controller.requiresReset)
        XCTAssertEqual(controller.library.map(\.id), [healthy.id])
    }

    private func waitUntilIdle(_ controller: PackageController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isBusy)
    }

    private func finalizeFixture(_ initial: PackageJob, content: Data) throws {
        let store = PackageLibraryStore(root: root)
        var job = initial
        let folder = try store.directory(id: job.id)
        let url = folder.appendingPathComponent(job.archiveFilename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        let item = PhotoPackageManifestItem(id: job.assets[0].id, photoPath: "media/\(job.assets[0].id)/original.jpg")
        let path = try XCTUnwrap(item.photoPath)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(content.count), compressionMethod: .none) { position, count in
            content.subdata(in: Int(position)..<(Int(position) + count))
        }
        let entry = try XCTUnwrap(archive[path])
        job.assets[0].manifestItem = item
        job.assets[0].archiveRecords = [.init(path: path, byteCount: entry.uncompressedSize, checksum: entry.checksum)]
        let manifest = try JSONEncoder().encode(PhotoPackageManifest(items: [item]))
        try archive.addEntry(with: PhotoPackageManifest.filename, type: .file, uncompressedSize: Int64(manifest.count), compressionMethod: .none) { position, count in
            manifest.subdata(in: Int(position)..<(Int(position) + count))
        }
        let manifestEntry = try XCTUnwrap(archive[PhotoPackageManifest.filename])
        job.phase = .ready
        job.manifestRecord = .init(path: PhotoPackageManifest.filename, byteCount: manifestEntry.uncompressedSize, checksum: manifestEntry.checksum)
        job.finalizedSize = try PackageRecovery.fileSize(url)
        try store.save(job)
    }
}
