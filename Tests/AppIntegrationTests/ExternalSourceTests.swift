import XCTest
import CryptoKit
import Photos
@testable import Dropack

@MainActor
final class ExternalSourceTests: XCTestCase {
    func testPhotoKitFailureRetainsRawStagingForExplicitRetry() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Failure fixtures run only in the dedicated simulator, never on a personal library.")
        #endif
        guard ProcessInfo.processInfo.environment["DROPACK_QA"] == "1" else {
            throw XCTSkip("Set DROPACK_QA=1 on the dedicated QA simulator.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("Grant Photos add access on the dedicated QA simulator.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = root.appendingPathComponent("\(UUID().uuidString).mov")
        // Deliberately invalid media reaches PhotoKit after a successful raw copy.
        let content = Data(repeating: 0x7a, count: 300_000)
        try content.write(to: camera)
        let service = MediaSourceService()
        let receiver = ImportController(checkpoint: CheckpointStore(url: root.appendingPathComponent("progress.json")),
                                        sourceService: service)
        await receiver.selectSource(camera)
        let item = try XCTUnwrap(receiver.job?.items.first)
        let staged = try await service.prepareMedia(item: item, sourceURL: camera, kind: .mediaFile) { _ in }
        receiver.start()
        let deadline = Date().addingTimeInterval(30)
        while receiver.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(receiver.isBusy)
        XCTAssertEqual(receiver.job?.failedCount, 1, receiver.message ?? "PhotoKit did not reject the invalid video")
        XCTAssertEqual(receiver.job?.savedCount, 0)
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), content, "PhotoKit failure must not delete a complete raw copy.")
        let failedJob = try XCTUnwrap(receiver.job)
        await MediaSourceService().cleanupForResume(job: failedJob)
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), content)
        receiver.retryFailures()
        XCTAssertEqual(receiver.job?.pendingCount, 1)
        XCTAssertEqual(receiver.job?.savedCount, 0)
        await service.cleanup(staged)
    }

    func testSingleCameraVideoCanScanBookmarkRelinkAndRetainSavedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = root.appendingPathComponent("camera.MOV")
        try Data("scan-only video fixture".utf8).write(to: camera)
        let store = CheckpointStore(url: root.appendingPathComponent("checkpoint.json"))
        let receiver = ImportController(checkpoint: store)
        await receiver.selectSource(camera)
        XCTAssertEqual(receiver.job?.source.kind, .mediaFile)
        XCTAssertEqual(receiver.job?.items.count, 1, receiver.message ?? "No source")
        var stored = try XCTUnwrap(receiver.job)
        stored.items[0].state = .saved
        try store.save(stored)
        let newMount = root.appendingPathComponent("Reconnected", isDirectory: true)
        try FileManager.default.createDirectory(at: newMount, withIntermediateDirectories: true)
        let relinked = newMount.appendingPathComponent(camera.lastPathComponent)
        try FileManager.default.moveItem(at: camera, to: relinked)
        let restored = ImportController(checkpoint: store)
        await restored.relinkSource(relinked)
        XCTAssertEqual(restored.job?.savedCount, 1)
        XCTAssertEqual(restored.job?.pendingCount, 0)
        XCTAssertFalse(restored.needsRelink, restored.message ?? "Relink failed")
    }

    func testRawStagingSurvivesServiceRecreationAndChangedPrefixIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = root.appendingPathComponent("\(UUID().uuidString).mov")
        let data = Data((0..<(600_000)).map { UInt8($0 % 251) })
        try data.write(to: camera)
        let service = MediaSourceService()
        let scan = try await service.scan(url: camera, kind: .mediaFile) { _ in }
        let item = try XCTUnwrap(scan.items.first)
        let prepared = try await service.prepareMedia(item: item, sourceURL: camera, kind: .mediaFile) { _ in }
        XCTAssertTrue(prepared.isResumable)
        // Keep only the beginning, exactly as an interrupted copy would leave it.
        let partial = try FileHandle(forWritingTo: prepared.fileURL)
        try partial.truncate(atOffset: 300_000)
        try partial.close()
        let freshService = MediaSourceService()
        let job = ImportJob(source: .init(kind: .mediaFile, name: camera.lastPathComponent,
            bookmark: Data(), fingerprint: scan.fingerprint), items: [item])
        await freshService.cleanupForResume(job: job)
        XCTAssertEqual((try Data(contentsOf: prepared.fileURL)).count, 300_000)
        let resumed = try await freshService.prepareMedia(item: item, sourceURL: camera, kind: .mediaFile) { _ in }
        XCTAssertEqual(resumed.fileURL, prepared.fileURL)
        XCTAssertEqual(try Data(contentsOf: resumed.fileURL), data)

        var changed = data
        changed[140_000] ^= 0xff
        try changed.write(to: camera)
        if let modifiedAt = item.modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: camera.path)
        }
        do {
            _ = try await freshService.prepareMedia(item: item, sourceURL: camera, kind: .mediaFile) { _ in }
            XCTFail("Same-size/date changed source must not replace a retained prefix")
        } catch let error as MediaSourceError {
            guard case .itemChanged = error else { return XCTFail("Wrong failure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: resumed.fileURL), data)
        await freshService.cleanup(resumed)
    }
}
