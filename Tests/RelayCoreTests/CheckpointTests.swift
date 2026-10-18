import XCTest
@testable import RelayCore

final class CheckpointTests: XCTestCase {
    private var directory: URL!
    private var store: CheckpointStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = CheckpointStore(url: directory.appendingPathComponent("progress.json"))
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func makeJob() -> ImportJob {
        ImportJob(source: .init(kind: .folder, name: "Trip", bookmark: Data([3])), items: [
            .init(id: "a", relativePath: "a.heic", kind: .photo, byteCount: 10, state: .saved),
            .init(id: "b", relativePath: "b.mov", kind: .video, byteCount: 20, state: .inFlight)
        ])
    }

    func testAtomicRoundTripPreservesSavedItemsAndRecoversInFlight() throws {
        var original = makeJob(); original.phase = .running
        try store.save(original)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(loaded.source.bookmark, original.source.bookmark)
        XCTAssertEqual(loaded.items.map(\.state), [.saved, .uncertain])
        XCTAssertEqual(loaded.phase, .paused)
        try store.save(loaded)
        XCTAssertEqual(try store.load()?.items[1].state, .uncertain)
    }

    func testCorruptedJournalIsReportedAndPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }

    func testUnknownVersionIsNotSilentlyReset() throws {
        var original = makeJob(); original.version = 99
        try store.save(original)
        XCTAssertThrowsError(try store.load()) { error in
            guard case CheckpointError.unsupportedVersion(99) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testInvalidJournalRejectsDuplicateIDsAndInvalidPacing() throws {
        var original = makeJob(); original.items[1].id = original.items[0].id
        try store.save(original)
        XCTAssertThrowsError(try store.load())
        original = makeJob(); original.delaySeconds = -1
        try store.save(original)
        XCTAssertThrowsError(try store.load())
    }

    func testFailedJournalReplacementPreservesLastValidRecord() throws {
        let original = makeJob(); try store.save(original)
        let before = try Data(contentsOf: store.url)
        var invalid = original; invalid.delaySeconds = .infinity
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }

    func testClearRemovesOnlyJournal() throws {
        try store.save(makeJob())
        let source = directory.appendingPathComponent("trip.zip")
        try Data([4, 5]).write(to: source)
        try store.remove()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try Data(contentsOf: source), Data([4, 5]))
    }
}
