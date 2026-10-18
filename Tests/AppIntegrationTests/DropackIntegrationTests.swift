import XCTest
import Photos
import UIKit
import AVFoundation
import CryptoKit
import ZIPFoundation
import UniformTypeIdentifiers
@testable import Dropack

@MainActor
final class SourcePreparationTests: XCTestCase {
    func testDropackDocumentRegistrationAndShareItemUseOwnedType() throws {
        let type = try XCTUnwrap(UTType(PackageFileFormat.typeIdentifier))
        XCTAssertEqual(type.preferredFilenameExtension, "dropack")
        XCTAssertTrue(type.conforms(to: .data))
        XCTAssertTrue(type.conforms(to: .content))
        let declarations = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let own = try XCTUnwrap(declarations.first { ($0["LSItemContentTypes"] as? [String])?.contains(PackageFileFormat.typeIdentifier) == true })
        XCTAssertEqual(own["LSHandlerRank"] as? String, "Owner")
        XCTAssertTrue(declarations.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.zip-archive") == true })
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        for format in [PackageFileFormat.dropack, .zip] {
            let url = URL(fileURLWithPath: "/tmp/Package.\(format.fileExtension)")
            let item = ArchiveActivityItem(url: url)
            XCTAssertEqual(item.activityViewController(controller, dataTypeIdentifierForActivityType: .airDrop), format.contentTypeIdentifier)
            XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .airDrop) as? URL, url)
        }
    }

    func testManifestSourcesFinishScanningAndKeepFinalCountWhileRecordingBookmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try (0..<6).map { index -> PhotoPackageManifestItem in
            let name = "photo-\(index).jpg"
            let content = Data("scan-only fixture \(index)".utf8)
            try content.write(to: folder.appendingPathComponent(name))
            return PhotoPackageManifestItem(id: UUID().uuidString, photoPath: name,
                photoSHA256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = PhotoPackageManifest(items: entries)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(PhotoPackageManifest.filename))
        let zip = root.appendingPathComponent("Received.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        for entry in entries {
            try archive.addEntry(with: try XCTUnwrap(entry.photoPath), relativeTo: folder, compressionMethod: .none)
        }
        try archive.addEntry(with: PhotoPackageManifest.filename, relativeTo: folder, compressionMethod: .none)
        let dropack = root.appendingPathComponent("Received.dropack")
        try FileManager.default.linkItem(at: zip, to: dropack)

        for (url, kind): (URL, SourceKind) in [(zip, .zip), (folder, .folder), (dropack, .zip)] {
            let service = MediaSourceService()
            let scan = try await service.scan(url: url, kind: kind) { _ in }
            XCTAssertEqual(scan.items.count, 6)
            let bookmark = try await service.makeBookmark(for: url)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            XCTAssertFalse(stale)
            XCTAssertEqual(resolved.standardizedFileURL, url.standardizedFileURL)
            let receiver = ImportController(checkpoint: CheckpointStore(
                url: root.appendingPathComponent("\(url.lastPathComponent)-checkpoint.json")))
            await receiver.selectSource(url)
            await Task.yield() // Let queued scan callbacks run after the final phase transition.
            XCTAssertEqual(receiver.scannedCount, 6)
            XCTAssertEqual(receiver.job?.items.count, 6)
            XCTAssertEqual(receiver.job?.source.kind, kind)
            XCTAssertEqual(receiver.job?.savedCount, 0, "Opening a received document must only scan, never automatically write to Photos.")
            XCTAssertFalse(receiver.isPreparing)
            XCTAssertEqual(receiver.currentStage, "")
        }
    }
}

@MainActor
final class DropackIntegrationTests: XCTestCase {
    private var createdIDs: [String] = []
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("These fixtures run only in the dedicated simulator, never on a personal library.")
        #endif
        guard ProcessInfo.processInfo.environment["DROPACK_QA"] == "1" else {
            throw XCTSkip("Set DROPACK_QA=1 on the dedicated QA simulator.")
        }
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            XCTFail("Allow full Photos access through the QA system prompt before running this test suite.")
            throw NSError(domain: "DropackQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "QA Photos permission is missing"])
        }
    }

    override func tearDown() async throws {
        // Fixtures stay in this disposable QA simulator. Deleting through
        // PhotoKit requires a system confirmation, which a hosted unit test
        // cannot dismiss. Erase/delete the dedicated simulator after QA.
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testOriginalPhotosAndVideoPackageThenImportWithoutRepeatedResume() async throws {
        let photo = temporaryDirectory.appendingPathComponent("原图.jpg")
        try jpeg().write(to: photo)
        let movie = temporaryDirectory.appendingPathComponent("video.mov")
        try await makeVideo(at: movie)
        let first = try await addAsset(photo, type: .photo)
        let second = try await addAsset(photo, type: .photo) // Identical original filenames remain distinct.
        let third = try await addAsset(movie, type: .video)

        // A hosted test shares the simulator app container. Never restore or
        // clear the app's real selected package; own a disposable service root.
        let packagingRoot = temporaryDirectory.appendingPathComponent("Packaging", isDirectory: true)
        let sender = PackageController(service: PhotoPackageService(root: packagingRoot))
        try await waitUntilIdle { sender.isBusy }
        XCTAssertNil(sender.job)
        XCTAssertTrue(sender.library.isEmpty)
        let accessGranted = await sender.requestPhotoAccess()
        XCTAssertTrue(accessGranted)
        await sender.create(assetIdentifiers: [first, second, third])
        try await waitUntilIdle { sender.isBusy }
        XCTAssertTrue(sender.job?.isDraft == true)
        XCTAssertNil(sender.archiveURL, "Selecting media prepares an album, not an automatic sharing package.")
        let sharedPackage = await sender.shareURL()
        XCTAssertNotNil(sharedPackage, sender.message ?? "Explicit share did not prepare a package")
        let packaged = try XCTUnwrap(sender.archiveURL, sender.message ?? "Package did not finalize")
        XCTAssertTrue(packaged.standardizedFileURL.path.hasPrefix(packagingRoot.standardizedFileURL.path + "/"),
                      "All package outputs must stay inside this test's disposable root.")
        XCTAssertEqual(packaged.pathExtension, "dropack")
        XCTAssertEqual(sender.job?.completedCount, 3)
        let preparedZIP = await sender.shareURL(format: .zip)
        let standardZIP = try XCTUnwrap(preparedZIP)
        XCTAssertEqual(standardZIP.pathExtension, "zip")
        let preparedDefault = await sender.shareURL()
        let defaultShare = try XCTUnwrap(preparedDefault)
        XCTAssertEqual(defaultShare.pathExtension, "dropack")
        let copy = temporaryDirectory.appendingPathComponent("Received.dropack")
        try FileManager.default.copyItem(at: packaged, to: copy)
        let archive = try Archive(url: copy, accessMode: .read)
        let entries = Array(archive)
        XCTAssertEqual(entries.filter { MediaPolicy.kind(for: $0.path) != nil }.count, 3)
        XCTAssertEqual(entries.filter { $0.path == PhotoPackageManifest.filename }.count, 1)
        for entry in entries {
            let crc = try archive.extract(entry, bufferSize: 262_144, skipCRC32: false) { _ in }
            XCTAssertEqual(crc, entry.checksum)
        }

        let checkpoint = CheckpointStore(url: temporaryDirectory.appendingPathComponent("import.json"))
        let receiver = ImportController(checkpoint: checkpoint)
        await receiver.selectSource(copy)
        XCTAssertEqual(receiver.job?.items.count, 3, receiver.message ?? "No manifest")
        receiver.delaySeconds = 0
        receiver.start()
        try await waitUntilIdle { receiver.isBusy }
        XCTAssertEqual(receiver.job?.savedCount, 3, receiver.message ?? "Import not complete")
        XCTAssertEqual(receiver.job?.failedCount, 0)
        let received = receiver.job?.items.compactMap(\.assetIdentifier) ?? []
        createdIDs.append(contentsOf: received)
        XCTAssertEqual(received.count, 3)
        for id in received {
            XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count, 1)
        }

        let restored = ImportController(checkpoint: checkpoint)
        try await waitUntilIdle { restored.isPreparing }
        XCTAssertEqual(restored.job?.savedCount, 3)
        XCTAssertFalse(restored.canStart)
        restored.start()
        XCTAssertFalse(restored.isBusy, "A completed job must not create duplicate Photos assets.")
        let systemAlbumID = try XCTUnwrap(sender.job?.linkedPhotosAlbumIdentifier)
        XCTAssertEqual(receiver.job?.systemAlbumIdentifier, systemAlbumID,
                       "Sending and receiving this same album on one device must link the same system album")
        let collection = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [systemAlbumID], options: nil).firstObject)
        var membersBeforeDeletion = Set<String>()
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            membersBeforeDeletion.insert(asset.localIdentifier)
        }
        XCTAssertFalse(membersBeforeDeletion.isEmpty)
        sender.clear()
        try await waitUntilIdle { sender.isBusy }
        let retainedCollection = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [systemAlbumID], options: nil).firstObject,
            "Deleting a local sharing package must retain its system Photos album")
        var membersAfterDeletion = Set<String>()
        PHAsset.fetchAssets(in: retainedCollection, options: nil).enumerateObjects { asset, _, _ in
            membersAfterDeletion.insert(asset.localIdentifier)
        }
        XCTAssertEqual(membersAfterDeletion, membersBeforeDeletion,
                       "Deleting a local sharing package must not remove any system Photos album members")
        let receivedAlbumID = try XCTUnwrap(receiver.job?.albumID)
        let deletedReceived = await receiver.deleteAlbum(albumID: receivedAlbumID)
        XCTAssertTrue(deletedReceived)
        let afterReceivedDeletion = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [systemAlbumID], options: nil).firstObject,
            "Deleting the received album record must retain its system Photos album")
        var membersAfterReceivedDeletion = Set<String>()
        PHAsset.fetchAssets(in: afterReceivedDeletion, options: nil).enumerateObjects { asset, _, _ in
            membersAfterReceivedDeletion.insert(asset.localIdentifier)
        }
        XCTAssertEqual(membersAfterReceivedDeletion, membersBeforeDeletion,
                       "Deleting a received album record must not remove system Photos album members")
        for id in [first, second, third] + received {
            XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count, 1)
        }
    }

    func testManifestContentHashMismatchStopsBeforePhotoCommit() async throws {
        let image = temporaryDirectory.appendingPathComponent("a.jpg")
        try jpeg().write(to: image)
        let manifest = PhotoPackageManifest(items: [PhotoPackageManifestItem(
            id: UUID().uuidString, photoPath: "a.jpg", photoSHA256: String(repeating: "0", count: 64))])
        let manifestURL = temporaryDirectory.appendingPathComponent(PhotoPackageManifest.filename)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let zip = temporaryDirectory.appendingPathComponent("corrupt.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "a.jpg", relativeTo: temporaryDirectory, compressionMethod: .none)
        try archive.addEntry(with: PhotoPackageManifest.filename, relativeTo: temporaryDirectory, compressionMethod: .none)
        for (url, kind): (URL, SourceKind) in [(zip, .zip), (temporaryDirectory, .folder)] {
            let service = MediaSourceService()
            let scan = try await service.scan(url: url, kind: kind) { _ in }
            XCTAssertEqual(scan.items.count, 1)
            do {
                let prepared = try await service.prepareMedia(item: scan.items[0], sourceURL: url, kind: kind) { _ in }
                await service.cleanup(prepared)
                XCTFail("A correct ZIP CRC must not override an incorrect manifest content digest.")
            } catch let error as MediaSourceError {
                guard case .corruptItem = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
    }

    private func addAsset(_ file: URL, type: PHAssetResourceType) async throws -> String {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
            request.addResource(with: type, fileURL: file, options: nil)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        let id = try XCTUnwrap(identifier)
        createdIDs.append(id)
        return id
    }

    private func jpeg() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            ("Dropack QA" as NSString).draw(at: CGPoint(x: 28, y: 70),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.white])
        }
    }

    private func waitUntilIdle(_ busy: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while busy(), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(busy(), "The job exceeded the test deadline.")
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        memset(baseAddress, 100, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for frame in 0..<10 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video fixture failed")
    }
}
