import AVFoundation
import Combine
import ImageIO
import Photos
import UIKit
import XCTest
@testable import Dropack

@MainActor
final class MediaThumbnailTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testLargePhotoDownsamplesAndAppliesOriginalOrientation() async throws {
        let url = directory.appendingPathComponent("portrait.jpg")
        // A 6 MP landscape JPEG tagged for portrait display exercises both
        // downsampling and EXIF orientation without a Photos-library fetch.
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 3_000, height: 2_000,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(UIColor.systemOrange.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
        let original = try XCTUnwrap(bitmap.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let loaded = await MediaThumbnailLoader().thumbnail(fileURL: url, kind: .photo)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.height, MediaThumbnailLoader.maximumPixelSize)
        XCTAssertLessThan(image.width, image.height)
        XCTAssertLessThanOrEqual(image.bytesPerRow * image.height, 600_000)
    }

    func testVideoUsesSmallFrameAndCorruptMediaRemainsOptional() async throws {
        let url = directory.appendingPathComponent("clip.mov")
        try await makePreviewVideo(at: url)
        let loader = MediaThumbnailLoader()
        let loaded = await loader.thumbnail(fileURL: url, kind: .video)
        let image = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertLessThanOrEqual(max(image.width, image.height), MediaThumbnailLoader.maximumPixelSize)

        let corrupt = directory.appendingPathComponent("corrupt.jpg")
        try Data("Not an image or video".utf8).write(to: corrupt)
        let corruptPhoto = await loader.thumbnail(fileURL: corrupt, kind: .photo)
        let corruptVideo = await loader.thumbnail(fileURL: corrupt, kind: .video)
        XCTAssertNil(corruptPhoto)
        XCTAssertNil(corruptVideo)
    }

    func testCanceledPreviewCannotPublishAnImage() async throws {
        let url = directory.appendingPathComponent("photo.jpg")
        try previewJPEG().write(to: url)
        let loader = MediaThumbnailLoader()
        let work = Task { await loader.thumbnail(fileURL: url, kind: .photo) }
        // The actor task has not started yet because this main-actor test has
        // not yielded. Cancellation is checked before any decoding occurs.
        work.cancel()
        let image = await work.value
        XCTAssertNil(image)
    }
}

@MainActor
final class PackageThumbnailReuseTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("Library") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testGridAndCoverShareOneDecodeAndOneCancellationDoesNotCancelTheOther() async throws {
        let job = try makeFixture()
        let decoder = CountedThumbnailGenerator(image: try testImage(), waitsForRelease: true)
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder)
        let grid = Task { await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id) }
        let cover = Task { await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id) }
        try await waitForDecodes(1, decoder: decoder)
        // Both main-actor callers get a turn while the decoder remains blocked.
        for _ in 0..<20 { await Task.yield() }
        grid.cancel()
        await decoder.release()
        let gridURL = await grid.value
        let coverURL = await cover.value
        XCTAssertNil(gridURL)
        XCTAssertNotNil(coverURL)
        let count = await decoder.callCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(coverURL, service.thumbnailURL(packageID: job.id, itemID: job.assets[0].id))
    }

    func testMissingPreviewDoesNotDecodeOnEveryShareRetryButCanRetryLater() async throws {
        let job = try makeFixture()
        let decoder = CountedThumbnailGenerator(image: nil)
        let clock = ThumbnailTestClock()
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder, thumbnailClock: { clock.now })
        for _ in 0..<12 {
            let result = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
            XCTAssertNil(result)
        }
        let firstCount = await decoder.callCount
        XCTAssertEqual(firstCount, 1, "Repeated share-related view updates must not restart an unsupported video decoder.")
        clock.advance(61)
        _ = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
        let laterCount = await decoder.callCount
        XCTAssertEqual(laterCount, 2, "Temporary source failures must remain retryable.")
    }

    func testWorkerJPEGImmediatelyOverridesFailedPreviewAndNewRevisionIsIndependent() async throws {
        let job = try makeFixture()
        let decoder = CountedThumbnailGenerator(image: nil)
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder)
        _ = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
        let store = PackageLibraryStore(root: root)
        let jpeg = try store.thumbnailURL(packageID: job.id, itemID: job.assets[0].id)
        try FileManager.default.createDirectory(at: jpeg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try previewJPEG().write(to: jpeg)
        let cached = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
        XCTAssertEqual(cached, jpeg, "The packaging worker's successful preview wins even within the retry window.")
        var revised = job
        revised.album = try job.album?.revised()
        revised.id = try XCTUnwrap(revised.album?.snapshotID)
        try store.save(revised)
        _ = await service.loadThumbnail(packageID: revised.id, itemID: revised.assets[0].id)
        let count = await decoder.callCount
        XCTAssertEqual(count, 2, "A different immutable revision must not inherit a negative result.")
    }

    func testChangedOriginalInSameDraftDoesNotInheritFailedPreview() async throws {
        var job = try makeFixture()
        let decoder = CountedThumbnailGenerator(image: nil)
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder)
        _ = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
        job.assets[0].fileSource?.modifiedAt = Date(timeIntervalSince1970: 99)
        try PackageLibraryStore(root: root).save(job)
        _ = await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id)
        let count = await decoder.callCount
        XCTAssertEqual(count, 2)
    }

    func testCancellingAllVisibleRequestsStopsQueuedDecodesAndPermitsRetry() async throws {
        let jobs = try (0..<8).map { _ in try makeFixture() }
        let decoder = CountedThumbnailGenerator(image: try testImage(), waitsForRelease: true)
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder)
        let tasks = jobs.map { job in
            Task { await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id) }
        }
        try await waitForDecodes(4, decoder: decoder)
        for task in tasks { task.cancel() }
        for task in tasks { let result = await task.value; XCTAssertNil(result) }
        let maximum = await decoder.maximumActive
        let callsAfterCancellation = await decoder.callCount
        XCTAssertEqual(maximum, 4)
        XCTAssertEqual(callsAfterCancellation, 4, "Offscreen queued cells must not continue starting decoders.")
        await decoder.release()
        let retried = await service.loadThumbnail(packageID: jobs[0].id, itemID: jobs[0].assets[0].id)
        XCTAssertNotNil(retried, "Cancellation is not a failed-source cache entry.")
    }

    func testDeletedPackageCannotBeRecreatedByLateThumbnail() async throws {
        let job = try makeFixture()
        let decoder = CountedThumbnailGenerator(image: try testImage(), waitsForRelease: true)
        let service = PhotoPackageService(root: root, thumbnailLoader: decoder)
        let task = Task { await service.loadThumbnail(packageID: job.id, itemID: job.assets[0].id) }
        try await waitForDecodes(1, decoder: decoder)
        try await service.deletePackage(id: job.id)
        await decoder.release()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(job.id.uuidString).path))
    }

    private func makeFixture() throws -> PackageJob {
        let file = directory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("bounded fake video; the injected decoder owns the result".utf8).write(to: file)
        var job = PackageJob(assetIdentifiers: ["file:" + UUID().uuidString])
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        job.assets[0].kind = .video
        job.assets[0].fileSource = PackageFileSource(bookmark: try file.bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil), relativePath: file.lastPathComponent,
            isFolder: false, byteCount: UInt64(try XCTUnwrap(values.fileSize)), modifiedAt: values.contentModificationDate)
        try PackageLibraryStore(root: root).save(job)
        return job
    }

    private func testImage() throws -> CGImage {
        // Match the generator's <= 360 px contract; the production writer
        // deliberately refuses an original-sized bitmap.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format)
            .image { context in
                UIColor.systemGreen.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }.cgImage)
    }

    private func waitForDecodes(_ expected: Int, decoder: CountedThumbnailGenerator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await decoder.callCount < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await decoder.callCount
        XCTAssertEqual(count, expected)
    }
}

private actor CountedThumbnailGenerator: MediaThumbnailGenerating {
    let image: CGImage?
    private var waitsForRelease: Bool
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0
    private var active = 0
    private(set) var maximumActive = 0

    init(image: CGImage?, waitsForRelease: Bool = false) {
        self.image = image; self.waitsForRelease = waitsForRelease
    }

    func thumbnail(fileURL: URL, kind: MediaKind) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        callCount += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if waitsForRelease {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        return Task.isCancelled ? nil : image
    }

    func release() {
        waitsForRelease = false
        let continuations = Array(waiting.values)
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.resume() }
}

private final class ThumbnailTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

@MainActor
final class ImportPreviewTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Preview import fixtures run only in the dedicated QA simulator.")
        #endif
        guard ProcessInfo.processInfo.environment["DROPACK_QA"] == "1" else {
            throw XCTSkip("Set DROPACK_QA=1 on the dedicated QA simulator.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            XCTFail("Allow full Photos access in the app's system prompt on the QA simulator before running these tests.")
            throw NSError(domain: "DropackPreviewQA", code: 1)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Real PhotoKit fixtures remain in this disposable QA simulator. Their
        // identifiers are checked below; no personal device/library is touched.
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSavedEventsFollowDurablePhotosSuccessAndRetainOnlyThreePreviews() async throws {
        let folder = directory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<5 {
            try previewJPEG(variant: index).write(to: folder.appendingPathComponent("photo-\(index).jpg"))
        }
        let checkpoint = CheckpointStore(url: directory.appendingPathComponent("progress.json"))
        let controller = ImportController(checkpoint: checkpoint)
        await controller.selectSource(folder)
        controller.delaySeconds = 0
        var events: [String] = []
        var observerError: Error?
        let subscription = controller.activity.$savedPreviewSequence.dropFirst().sink { sequence in
            do {
                let preview = try XCTUnwrap(controller.lastSavedPreview)
                let durable = try XCTUnwrap(checkpoint.load())
                let item = try XCTUnwrap(durable.items.first { $0.id == preview.itemID })
                XCTAssertEqual(item.state, .saved, "An animation must never precede the durable success record.")
                let assetID = try XCTUnwrap(item.assetIdentifier)
                XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).count, 1)
                XCTAssertNotNil(preview.image)
                XCTAssertLessThanOrEqual(controller.recentSavedPreviews.count, 3)
                events.append(item.id)
                XCTAssertEqual(sequence, UInt64(events.count))
            } catch { observerError = error }
        }
        defer { subscription.cancel() }
        controller.start()
        try await waitForPreviewImport(controller)
        if let observerError { throw observerError }
        XCTAssertEqual(controller.job?.savedCount, 5, controller.message ?? "Import failed")
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(Set(events).count, 5)
        XCTAssertEqual(controller.recentSavedPreviews.count, 3)
        XCTAssertNil(controller.activePreview)
        XCTAssertFalse(controller.isSavingToPhotos)

        // Resuming a finished task cannot replay old success animations. A new
        // task drops the old images while leaving the event nonce monotonic.
        controller.start()
        XCTAssertEqual(controller.savedPreviewSequence, 5)
        controller.clearJob()
        try await waitForPreviewImport(controller)
        XCTAssertTrue(controller.recentSavedPreviews.isEmpty)
        XCTAssertNil(controller.lastSavedPreview)
        XCTAssertEqual(controller.savedPreviewSequence, 5)
    }

    func testJournalFailureAfterPhotosSuccessDoesNotEmitSavedAnimation() async throws {
        let url = directory.appendingPathComponent("photo.jpg")
        try previewJPEG().write(to: url)
        let checkpoint = CheckpointStore(url: directory.appendingPathComponent("progress.json"))
        let controller = ImportController(checkpoint: checkpoint)
        await controller.selectSource(url)
        var blockedCheckpoint = false
        var setupError: Error?
        let subscription = controller.activity.$isSavingToPhotos.sink { saving in
            guard saving, !blockedCheckpoint else { return }
            do {
                // The in-flight journal exists before PhotoKit begins. Turn
                // its destination into a directory so the *success* write fails.
                XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.url.path))
                try FileManager.default.removeItem(at: checkpoint.url)
                try FileManager.default.createDirectory(at: checkpoint.url, withIntermediateDirectories: false)
                blockedCheckpoint = true
            } catch { setupError = error }
        }
        defer { subscription.cancel() }
        controller.start()
        try await waitForPreviewImport(controller)
        if let setupError { throw setupError }
        XCTAssertTrue(blockedCheckpoint)
        XCTAssertEqual(controller.job?.uncertainCount, 1, controller.message ?? "Expected uncertain journal result")
        let identifier = try XCTUnwrap(controller.job?.items.first?.assetIdentifier)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count, 1,
            "The PhotoKit transaction actually succeeded; only journaling failed.")
        XCTAssertEqual(controller.savedPreviewSequence, 0)
        XCTAssertTrue(controller.recentSavedPreviews.isEmpty)
        XCTAssertNil(controller.activePreview)
    }
}

@MainActor
private func previewJPEG(variant: Int = 0) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480), format: format)
        .jpegData(withCompressionQuality: 0.85) { context in
            UIColor(hue: CGFloat(variant + 1) / 7, saturation: 0.65, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
}

@MainActor
private func waitForPreviewImport(_ controller: ImportController) async throws {
    let deadline = Date().addingTimeInterval(40)
    while (controller.isBusy || controller.isPreparing), Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertFalse(controller.isBusy || controller.isPreparing, "Preview import exceeded its test deadline.")
}

private func makePreviewVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video,
        outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480,
        kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
    memset(baseAddress, 100, CVPixelBufferGetDataSize(pixel))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    for frame in 0..<3 {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        XCTAssertTrue(adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video fixture failed")
}
