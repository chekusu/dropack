import XCTest
@testable import RelayCore

final class ResumableFileCopyTests: XCTestCase {
    private func fixture(_ body: (URL, URL, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("camera.mov")
        let staged = root.appendingPathComponent("partial.mov")
        let content = Data((0..<(1024 * 1024 + 73)).map { UInt8($0 % 251) })
        try content.write(to: source)
        try body(source, staged, content)
    }

    func testPauseRetainsPrefixAndFreshCopyResumesWithoutRewritingIt() throws {
        try fixture { source, staged, content in
            var written: UInt64 = 0
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count), chunkSize: 65_536,
                checkCancellation: {
                    if written >= 196_608 { throw CancellationError() }
                }, progress: { written = $0 })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: staged), content.prefix(196_608))
            var firstProgress: UInt64?
            var consumed = Data()
            let resumedAt = try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count), chunkSize: 65_536,
                consume: { consumed.append($0) }, progress: { if firstProgress == nil { firstProgress = $0 } })
            XCTAssertEqual(resumedAt, 196_608)
            XCTAssertEqual(firstProgress, 196_608)
            XCTAssertEqual(consumed, content, "Digest consumers must see both the verified prefix and new bytes exactly once.")
            XCTAssertEqual(try Data(contentsOf: staged), content)
        }
    }

    func testChangedSameSizeSourceCannotBeSplicedOntoRetainedPrefix() throws {
        try fixture { source, staged, content in
            let originalPrefix = Data(content.prefix(200_000))
            try originalPrefix.write(to: staged)
            var changed = content
            changed[100_003] ^= 0xff // Not just the first/last chunk: the full prefix must be checked.
            try changed.write(to: source)
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count))) { error in
                guard case ResumableCopyError.sourceChanged = error else { return XCTFail("Wrong error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: staged), originalPrefix)
        }
    }

    func testUnavailableSourceLeavesDurablePrefixForRelink() throws {
        try fixture { source, staged, content in
            let prefix = Data(content.prefix(300_000))
            try prefix.write(to: staged)
            let reconnected = source.deletingLastPathComponent().appendingPathComponent("reconnected.mov")
            try FileManager.default.moveItem(at: source, to: reconnected)
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count))) { error in
                guard case ResumableCopyError.sourceReadFailed = error else { return XCTFail("Wrong error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: staged), prefix)
            XCTAssertEqual(try ResumableFileCopy.copy(from: reconnected, to: staged,
                expectedBytes: UInt64(content.count)), 300_000)
            XCTAssertEqual(try Data(contentsOf: staged), content)
        }
    }

    func testTruncatedSourceAndOversizedPartialAreRejected() throws {
        try fixture { source, staged, content in
            try Data(content.prefix(100)).write(to: source)
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count))) { error in
                guard case ResumableCopyError.sourceChanged = error else { return XCTFail("Wrong error: \(error)") }
            }
            try content.write(to: staged)
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged, expectedBytes: 100))
            XCTAssertEqual(try Data(contentsOf: staged), content)
        }
    }

    func testPauseDuringPrefixVerificationDoesNotDiscardOrModifyPartial() throws {
        try fixture { source, staged, content in
            let prefix = Data(content.prefix(900_000))
            try prefix.write(to: staged)
            var checks = 0
            XCTAssertThrowsError(try ResumableFileCopy.copy(from: source, to: staged,
                expectedBytes: UInt64(content.count), chunkSize: 65_536, checkCancellation: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }))
            XCTAssertEqual(try Data(contentsOf: staged), prefix)
        }
    }

    func testRawFileKindSurvivesCheckpointAndSavedItemsStaySaved() throws {
        try fixture { source, _, _ in
            let item = ImportItem(id: "video", relativePath: source.lastPathComponent,
                                  kind: .video, byteCount: 24_000_000_000, state: .saved)
            let store = CheckpointStore(url: source.deletingLastPathComponent().appendingPathComponent("progress.json"))
            try store.save(ImportJob(source: .init(kind: .mediaFile, name: "camera.mov", bookmark: Data()), items: [item]))
            let restored = try XCTUnwrap(store.load())
            XCTAssertEqual(restored.source.kind, .mediaFile)
            XCTAssertEqual(restored.savedCount, 1)
            XCTAssertEqual(restored.pendingCount, 0)
        }
    }
}
