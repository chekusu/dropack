import XCTest
import CryptoKit
import ZIPFoundation
@testable import Dropack

/// Actual source scans, extraction, hashing, checkpoint/SQLite persistence and
/// controller transitions; a deterministic writer counts commit attempts without
/// touching Photos. Real PhotoKit success/failure boundary is also exercised by
/// the separate ImportPreviewTests on the authorized disposable simulator.
@MainActor
final class ImportDeduplicationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var checkpoint: CheckpointStore { .init(url: root.appendingPathComponent("progress.json")) }
    private var history: ImportHistoryStore { .init(url: root.appendingPathComponent("import-history.sqlite")) }

    func testReceivedPackageReopenAndRenamedCopyPreserveSavedHistoryAfterClear() async throws {
        for withManifest in [true, false] {
            let writer = CountingImportWriter()
            let suffix = withManifest ? "dropack" : "zip"
            let archive = try makeArchive(name: "first.\(suffix)", payloads: ["a-\(suffix)", "b-\(suffix)"], manifest: withManifest)
            let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
            assertTrue(await controller.selectSource(archive))
            controller.delaySeconds = 0
            controller.start(); try await settle(controller)
            XCTAssertEqual(controller.job?.savedCount, 2, controller.message ?? "")
            let originalJobID = controller.job?.id
            assertTrue(await controller.replaceSource(archive))
            XCTAssertEqual(controller.job?.id, originalJobID)
            XCTAssertEqual(controller.previouslySavedCount, 2)
            XCTAssertFalse(controller.canStart)
            let copy = root.appendingPathComponent("renamed-\(UUID().uuidString).\(suffix)")
            try FileManager.default.copyItem(at: archive, to: copy)
            controller.clearJob(); try await settle(controller)
            let reopened = ImportController(checkpoint: checkpoint, photoWriter: writer)
            assertTrue(await reopened.selectSource(copy))
            XCTAssertEqual(reopened.previouslySavedCount, 2)
            XCTAssertEqual(reopened.job?.phase, .completed)
            reopened.start(); try await settle(reopened)
            assertEqual(await writer.attemptCount(), 2, "Same content must never open another Photos transaction.")
            reopened.clearJob(); try await settle(reopened)
        }
    }

    func testPartialSuccessReentryWritesOnlyRemainingAndDifferentContentsRemainNew() async throws {
        let writer = CountingImportWriter(failOnceAt: 2)
        let archive = try makeArchive(name: "partial.zip", payloads: ["first", "second"], manifest: false)
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        assertTrue(await controller.selectSource(archive)); controller.delaySeconds = 0
        controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 1)
        XCTAssertEqual(controller.job?.failedCount, 1)
        controller.clearJob(); try await settle(controller)
        let copy = root.appendingPathComponent("partial-copy.zip")
        try FileManager.default.copyItem(at: archive, to: copy)
        assertTrue(await controller.selectSource(copy))
        XCTAssertEqual(controller.previouslySavedCount, 1)
        XCTAssertEqual(controller.job?.pendingCount, 1)
        controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 2)
        assertEqual(await writer.attemptCount(), 3)
        // Same media names and byte counts, different bytes: no metadata-only match.
        let different = try makeArchive(name: "different.zip", payloads: ["FIRST", "SECOND"], manifest: false)
        assertTrue(await controller.replaceSource(different))
        XCTAssertEqual(controller.job?.savedCount, 0)
        controller.start(); try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 2)
        assertEqual(await writer.attemptCount(), 5)
    }

    func testRawFileRenameAndRepackedContainerUseResourceContentHash() async throws {
        let writer = CountingImportWriter()
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        let raw = root.appendingPathComponent("camera.jpg")
        try Data("identical photo bytes".utf8).write(to: raw)
        assertTrue(await controller.selectSource(raw));controller.delaySeconds = 0
        controller.start();try await settle(controller)
        let renamed = root.appendingPathComponent("new-name.jpg")
        try FileManager.default.copyItem(at: raw, to: renamed)
        assertTrue(await controller.replaceSource(renamed))
        XCTAssertEqual(controller.previouslySavedCount, 1)
        let repacked = try makeArchive(name: "repacked.dropack", payloads: ["identical photo bytes"], manifest: true)
        assertTrue(await controller.replaceSource(repacked))
        controller.start();try await settle(controller)
        XCTAssertEqual(controller.previouslySavedCount, 1)
        assertEqual(await writer.attemptCount(), 1)
    }

    func testUnresolvedHistoryIsNotSwallowedByClearOrDifferentSourcePath() async throws {
        let archive = try makeArchive(name: "uncertain.dropack", payloads: ["uncertain bytes"], manifest: true)
        let writer = CountingImportWriter()
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        assertTrue(await controller.selectSource(archive))
        let job = try XCTUnwrap(controller.job), item = try XCTUnwrap(job.items.first)
        let key = try XCTUnwrap(ImportContentIdentity.verifiedManifest(item))
        _ = try history.begin(identity: key, jobID: job.id, itemID: item.id, sourceIdentity: job.source.contentIdentity)
        controller.clearJob(); try await settle(controller)
        let copy = root.appendingPathComponent("uncertain-copy.dropack")
        try FileManager.default.copyItem(at: archive, to: copy)
        assertTrue(await controller.selectSource(copy))
        XCTAssertEqual(controller.job?.uncertainCount, 1)
        XCTAssertEqual(controller.job?.savedCount, 0)
        XCTAssertFalse(controller.canStart)
        controller.start();try await settle(controller)
        assertEqual(await writer.attemptCount(), 0)
        controller.resolveUncertain(id: try XCTUnwrap(controller.job?.items.first?.id), asSaved: false)
        try await settle(controller)
        XCTAssertTrue(controller.canStart)
        controller.start();try await settle(controller)
        XCTAssertEqual(controller.job?.savedCount, 1)
        assertEqual(await writer.attemptCount(), 1)
    }

    func testPhotosSuccessThenLedgerFailureStopsUncertainWithoutAutomaticRetry() async throws {
        let ledgerURL = history.url
        let writer = CountingImportWriter(afterSuccess: {
            try FileManager.default.moveItem(at: ledgerURL, to: ledgerURL.appendingPathExtension("backup"))
            try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: false)
        })
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        let archive = try makeArchive(name: "ledger-failure.zip", payloads: ["one", "two"], manifest: false)
        assertTrue(await controller.selectSource(archive));controller.delaySeconds = 0
        controller.start();try await settle(controller)
        XCTAssertEqual(controller.job?.uncertainCount, 1)
        XCTAssertEqual(controller.job?.savedCount, 0)
        XCTAssertEqual(controller.savedPreviewSequence, 0)
        assertEqual(await writer.attemptCount(), 1)
        controller.start();try await settle(controller)
        assertEqual(await writer.attemptCount(), 1)
        try FileManager.default.removeItem(at: ledgerURL)
        try FileManager.default.moveItem(at: ledgerURL.appendingPathExtension("backup"), to: ledgerURL)
        let restored = ImportController(checkpoint: checkpoint, photoWriter: writer)
        try await settle(restored)
        XCTAssertEqual(restored.job?.uncertainCount, 1)
        XCTAssertFalse(restored.canStart)
    }

    func testConfirmedLedgerRecoversAfterSuccessCheckpointFailure() async throws {
        let checkpointURL = checkpoint.url
        let writer = CountingImportWriter(afterSuccess: {
            try FileManager.default.removeItem(at: checkpointURL)
            try FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: false)
        })
        let archive = try makeArchive(name: "checkpoint-failure.zip", payloads: ["confirmed"], manifest: false)
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        assertTrue(await controller.selectSource(archive))
        controller.start();try await settle(controller)
        XCTAssertEqual(controller.job?.uncertainCount, 1)
        XCTAssertEqual(controller.savedPreviewSequence, 0)
        try FileManager.default.removeItem(at: checkpointURL)
        let reopened = ImportController(checkpoint: checkpoint, photoWriter: writer)
        assertTrue(await reopened.selectSource(archive))
        XCTAssertEqual(reopened.job?.savedCount, 1)
        XCTAssertEqual(reopened.previouslySavedCount, 1)
        XCTAssertFalse(reopened.canStart)
        assertEqual(await writer.attemptCount(), 1)
    }

    func testFailedNewSelectionRetainsOldCompletedJobAndIsNotAccepted() async throws {
        let writer = CountingImportWriter()
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        let archive = try makeArchive(name: "original.zip", payloads: ["original"], manifest: false)
        assertTrue(await controller.selectSource(archive))
        controller.start();try await settle(controller)
        let originalID = controller.job?.id
        assertFalse(await controller.replaceSource(root.appendingPathComponent("missing.zip")))
        XCTAssertEqual(controller.job?.id, originalID)
        XCTAssertEqual(controller.job?.savedCount, 1)
    }

    func testRelinkRejectsDifferentBytesEvenWhenNameSizeAndTimestampMatch() async throws {
        let writer = CountingImportWriter()
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        let a = root.appendingPathComponent("camera.jpg")
        try Data("AAAA".utf8).write(to: a)
        // setAttributes round-trips sub-microsecond Date precision differently
        // from copyItem. Use an exactly representable timestamp on BOTH files so
        // the negative case really reaches full-hash verification.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: a.path)
        assertTrue(await controller.selectSource(a))
        controller.start(); try await settle(controller)
        let previous = try XCTUnwrap(controller.job)
        let folder = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let b = folder.appendingPathComponent("camera.jpg")
        try Data("BBBB".utf8).write(to: b)
        let date = try XCTUnwrap(previous.items.first?.modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let mutatedScan = try await MediaSourceService().scan(url: b, kind: .mediaFile, progress: { _ in })
        XCTAssertTrue(previous.matchesReplacement(mutatedScan.items), "Fixture metadata must match; only SHA should reject it.")
        XCTAssertEqual(previous.source.fingerprint, mutatedScan.fingerprint)
        assertFalse(await controller.relinkSource(b))
        XCTAssertEqual(controller.job?.id, previous.id)
        XCTAssertEqual(controller.job?.source.contentIdentity, previous.source.contentIdentity)
        XCTAssertEqual(controller.job?.items.first?.assetIdentifier, previous.items.first?.assetIdentifier)
        assertEqual(await writer.attemptCount(), 1)
    }

    func testFolderRelinkVerifiesSavedBytesAndRejectsLegacyUnknownIdentities() async throws {
        let original = root.appendingPathComponent("folder-original", isDirectory: true)
        let copied = root.appendingPathComponent("folder-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let originalFile = original.appendingPathComponent("camera.jpg")
        try Data("AAAA".utf8).write(to: originalFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: originalFile.path)
        let writer = CountingImportWriter()
        let controller = ImportController(checkpoint: checkpoint, photoWriter: writer)
        assertTrue(await controller.selectSource(original))
        controller.start(); try await settle(controller)
        let saved = try XCTUnwrap(controller.job)
        XCTAssertEqual(saved.savedCount, 1)
        try FileManager.default.copyItem(at: original, to: copied)
        let copyFile = copied.appendingPathComponent("camera.jpg")
        let date = try XCTUnwrap(saved.items.first?.modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copyFile.path)
        let copyAccepted = await controller.relinkSource(copied)
        XCTAssertTrue(copyAccepted, controller.message ?? "Same-content folder copy should relink.")
        XCTAssertEqual(controller.job?.id, saved.id)
        XCTAssertEqual(controller.job?.savedCount, 1)
        try Data("BBBB".utf8).write(to: copyFile)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copyFile.path)
        let mutatedScan = try await MediaSourceService().scan(url: copied, kind: .folder, progress: { _ in })
        XCTAssertTrue(saved.matchesReplacement(mutatedScan.items), "Fixture metadata must match; only SHA should reject it.")
        assertFalse(await controller.relinkSource(copied))
        XCTAssertEqual(controller.job?.items.first?.contentIdentity, saved.items.first?.contentIdentity)
        assertEqual(await writer.attemptCount(), 1)

        // A pre-upgrade ordinary-folder checkpoint carries no cryptographic
        // evidence. Rebinding it must not invent a receipt for today's bytes.
        var legacy = saved
        legacy.items[0].contentIdentity = nil
        legacy.items[0].expectedSHA256 = nil
        let legacyStore = CheckpointStore(url: root.appendingPathComponent("legacy/progress.json"))
        try legacyStore.save(legacy)
        let oldController = ImportController(checkpoint: legacyStore, photoWriter: writer)
        try await settle(oldController)
        assertFalse(await oldController.relinkSource(original))
        XCTAssertNil(oldController.job?.items.first?.contentIdentity)
        XCTAssertTrue(oldController.message?.contains("没有可验证的内容记录") == true)
        assertEqual(await writer.attemptCount(), 1)
    }

    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
    private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, file: file, line: line)
    }
    private func assertEqual(_ value: Int, _ expected: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private func makeArchive(name: String, payloads: [String], manifest: Bool) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [PhotoPackageManifestItem] = []
        for (index, text) in payloads.enumerated() {
            let path = "image-\(index).jpg", data = Data(text.utf8)
            try data.write(to: directory.appendingPathComponent(path))
            entries.append(.init(id: UUID().uuidString, photoPath: path,
                photoSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        if manifest { try JSONEncoder().encode(PhotoPackageManifest(items: entries)).write(to: directory.appendingPathComponent(PhotoPackageManifest.filename)) }
        let url = root.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries { try archive.addEntry(with: try XCTUnwrap(entry.photoPath), relativeTo: directory, compressionMethod: .none) }
        if manifest { try archive.addEntry(with: PhotoPackageManifest.filename, relativeTo: directory, compressionMethod: .none) }
        return url
    }

    private func settle(_ controller: ImportController) async throws {
        let deadline = Date().addingTimeInterval(30)
        while controller.isBusy || controller.isPreparing {
            guard Date() < deadline else { return XCTFail("Import did not settle: \(controller.message ?? "")") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor CountingImportWriter: PhotoLibraryWriting {
    private var attempts = 0
    private let failOnceAt: Int?
    private let afterSuccess: (@Sendable () throws -> Void)?
    init(failOnceAt: Int? = nil, afterSuccess: (@Sendable () throws -> Void)? = nil) {
        self.failOnceAt = failOnceAt; self.afterSuccess = afterSuccess
    }
    func authorize() async throws {}
    func save(item: ImportItem, fileURL: URL, pairedVideoURL: URL?) async throws -> String? {
        attempts += 1
        if attempts == failOnceAt { throw PhotoLibraryWriterError.transactionFailed("Controlled test failure before commit") }
        try afterSuccess?()
        return "test-confirmed-\(attempts)"
    }
    func attemptCount() -> Int { attempts }
}
