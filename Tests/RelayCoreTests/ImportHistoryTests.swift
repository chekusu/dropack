import XCTest
import CryptoKit
@testable import RelayCore

final class ImportHistoryTests: XCTestCase {
    private var root: URL!
    private var store: ImportHistoryStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImportHistoryStore(url: root.appendingPathComponent("history.sqlite"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func identity(_ string: String) throws -> String {
        try ImportContentIdentity.media(kind: .photo, primarySHA256: hash(Data(string.utf8)))
    }

    func testUnresolvedReservationSurvivesReopenAndIsNeverConfirmedByBegin() throws {
        let key = try identity("one"), job = UUID()
        XCTAssertNil(try store.begin(identity: key, jobID: job, itemID: "first", sourceIdentity: "archive-hash"))
        let reopened = ImportHistoryStore(url: store.url)
        let found = try XCTUnwrap(reopened.begin(identity: key, jobID: UUID(), itemID: "renamed", sourceIdentity: "different-archive"))
        XCTAssertEqual(found.state, .unresolved)
        XCTAssertEqual(found.jobID, job)
        XCTAssertEqual(try reopened.identity(source: "archive-hash", itemID: "first"), key)
        XCTAssertEqual(try reopened.record(for: key)?.state, .unresolved)
    }

    func testConfirmedHistorySurvivesTaskClearAndRenameAndCannotBeReleasedAsUnresolved() throws {
        let key = try identity("same bytes"), job = UUID()
        try store.confirm(identity: key, jobID: job, itemID: "photo.jpg", assetIdentifier: "photos-id", sourceIdentity: "archive-hash")
        let checkpoint = CheckpointStore(url: root.appendingPathComponent("progress.json"))
        try checkpoint.save(ImportJob(source: .init(kind: .zip, name: "old.zip", bookmark: Data()), items: []))
        try checkpoint.remove()
        try store.releaseUnresolved(identity: key)
        let renamed = try XCTUnwrap(ImportHistoryStore(url: store.url).begin(identity: key, jobID: UUID(), itemID: "new-name.jpg", sourceIdentity: "repacked-archive"))
        XCTAssertEqual(renamed.state, .confirmed)
        XCTAssertEqual(renamed.assetIdentifier, "photos-id")
        XCTAssertEqual(try store.identity(source: "repacked-archive", itemID: "new-name.jpg"), key)
    }

    func testDifferentContentAndLivePhotoResourceRolesDoNotCollide() throws {
        let a = hash(Data("AAA".utf8)), b = hash(Data("BBB".utf8))
        let values = try [ImportContentIdentity.media(kind: .photo, primarySHA256: a),
                          ImportContentIdentity.media(kind: .photo, primarySHA256: b),
                          ImportContentIdentity.media(kind: .video, primarySHA256: a),
                          ImportContentIdentity.media(kind: .photo, primarySHA256: a, pairedSHA256: b),
                          ImportContentIdentity.media(kind: .photo, primarySHA256: b, pairedSHA256: a)]
        XCTAssertEqual(Set(values).count, 5)
        XCTAssertThrowsError(try ImportContentIdentity.media(kind: .photo, primarySHA256: "crc32:12345"))
    }

    func testFailedHistoryWriteDoesNotManufactureConfirmedReceipt() throws {
        let key = try identity("confirmed only after real success")
        XCTAssertNil(try store.begin(identity: key, jobID: UUID(), itemID: "one", sourceIdentity: nil))
        let blocked = ImportHistoryStore(url: root.appendingPathComponent("directory"))
        try FileManager.default.createDirectory(at: blocked.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try blocked.confirm(identity: key, jobID: UUID(), itemID: "one", assetIdentifier: "asset", sourceIdentity: nil))
        XCTAssertEqual(try store.record(for: key)?.state, .unresolved)
    }

    func testFileIdentityUsesAllBytesNotNameSizeDateOrCRC() async throws {
        let a = root.appendingPathComponent("camera.jpg"), b = root.appendingPathComponent("renamed.jpg")
        let bytes = Data(repeating: 0x61, count: 600_000)
        try bytes.write(to: a); try bytes.write(to: b)
        let hasher = ImportContentHasher()
        let first = try await hasher.hashFile(a, expectedBytes: UInt64(bytes.count))
        let copied = try await hasher.hashFile(b, expectedBytes: UInt64(bytes.count))
        XCTAssertEqual(first, copied)
        XCTAssertEqual(first, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        var changed = bytes; changed[400_000] = 0x62; try changed.write(to: b)
        let different = try await hasher.hashFile(b, expectedBytes: UInt64(bytes.count))
        XCTAssertNotEqual(first, different)
    }

    func testLargeHistoryBatchRestoresOnWorkerWithoutRewritingConfirmedRows() async throws {
        var source = SourceDescriptor(kind: .zip, name: "large.zip", bookmark: Data())
        source.contentIdentity = "archive-full-hash"
        var items: [ImportItem] = []
        for index in 0..<2_000 {
            var item = ImportItem(id: "item-\(index)", relativePath: "photo-\(index).jpg", kind: .photo, byteCount: 5)
            item.state = .saved
            item.contentIdentity = try identity("unique image \(index)")
            item.assetIdentifier = "photos-\(index)"
            items.append(item)
        }
        let original = ImportJob(source: source, items: items)
        let worker = ImportHistoryWorker(store: store)
        _ = try await worker.preserve(original)
        let originalDatabase = try Data(contentsOf: store.url)
        _ = try await worker.preserve(original)
        XCTAssertEqual(try Data(contentsOf: store.url), originalDatabase,
                       "Restoring confirmed history must not rewrite each receipt or source mapping.")
        var reopened = ImportJob(source: source, items: items.map { item in
            var item = item; item.state = .pending; item.contentIdentity = nil; item.assetIdentifier = nil
            return item
        })
        reopened = try await worker.reconcile(reopened, markPreviouslyImported: true)
        XCTAssertEqual(reopened.savedCount, 2_000)
        XCTAssertEqual(reopened.items.filter { $0.alreadyImported == true }.count, 2_000)
        XCTAssertEqual(reopened.items.last?.assetIdentifier, "photos-1999")
    }

    func testOldCheckpointDecodesWithoutIdentityOrPreviouslyImportedFlags() throws {
        let item = ImportItem(id: "a", relativePath: "a.jpg", kind: .photo, byteCount: 1)
        let job = ImportJob(source: .init(kind: .zip, name: "archive.zip", bookmark: Data()), items: [item])
        let restored = try JSONDecoder().decode(ImportJob.self, from: JSONEncoder().encode(job))
        XCTAssertNil(restored.source.contentIdentity)
        XCTAssertNil(restored.items[0].contentIdentity)
        XCTAssertNil(restored.items[0].alreadyImported)
    }
}
