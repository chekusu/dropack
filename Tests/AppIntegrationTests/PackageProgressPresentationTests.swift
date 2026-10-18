import XCTest
@testable import Dropack

/// Regression cases for the sent album's independent progress readout and the
/// same resource fraction passed to the system Live Activity.
@MainActor
final class PackageProgressPresentationTests: XCTestCase {
    func testSingleLargeVideoShowsResourcePercentWhileCommittedCountIsZero() {
        let snapshot = PackageActivitySnapshot(completedCount: 0, totalCount: 1,
            stage: "正在打包", name: "large-video.mov", fraction: 0.42)
        let presentation = PackageProgressPresentation(snapshot: snapshot, isBusy: true,
            pauseRequested: false, phase: .packing)
        XCTAssertEqual(presentation.percentageText, "42%")
        XCTAssertEqual(presentation.compactText, "42%", "The navigation control must not stay at 0/1 for a long video.")
        XCTAssertEqual(presentation.countText, "0 / 1", "A partial resource must not be counted as a committed item.")
        XCTAssertEqual(presentation.name, "large-video.mov")
        XCTAssertEqual(presentation.barFraction, 0.42, accuracy: 0.0001)
    }

    func testNewResourceStageDoesNotPretendItsPercentIsAlbumByteProgress() {
        let hashing = PackageProgressPresentation(snapshot: .init(completedCount: 8, totalCount: 9,
            stage: "核对文件", name: "film.mov", fraction: 1), isBusy: true, pauseRequested: false, phase: .packing)
        let packaging = PackageProgressPresentation(snapshot: .init(completedCount: 8, totalCount: 9,
            stage: "正在打包", name: "film.mov", fraction: 0.12), isBusy: true, pauseRequested: false, phase: .packing)
        XCTAssertEqual(hashing.percentage, 100)
        XCTAssertEqual(packaging.percentage, 12)
        XCTAssertEqual(packaging.stage, "正在打包")
        XCTAssertEqual(packaging.countText, "8 / 9")
        XCTAssertEqual(packaging.barFraction, 0.12, accuracy: 0.0001,
            "The page labels a current file stage; it must not invent a byte-weighted album percentage.")
    }

    func testPausingKeepsLastObservedResourceThenPausedUsesOnlyCommittedCheckpoint() {
        let last = PackageActivitySnapshot(completedCount: 8, totalCount: 9,
            stage: "正在打包", name: "film.mov", fraction: 0.42)
        let pausing = PackageProgressPresentation(snapshot: last, isBusy: true,
            pauseRequested: true, phase: .packing)
        XCTAssertEqual(pausing.state, .pausing)
        XCTAssertEqual(pausing.stage, "暂停中")
        XCTAssertEqual(pausing.percentage, 42)

        let paused = PackageProgressPresentation(snapshot: last, isBusy: false,
            pauseRequested: false, phase: .paused)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.resourceFraction, "Rolled-back resource work must not look resumable from its previous byte position.")
        XCTAssertTrue(paused.name.isEmpty)
        XCTAssertEqual(paused.compactText, "8/9")

        let resumed = PackageProgressPresentation(snapshot: .init(completedCount: 8, totalCount: 9,
            stage: "继续打包"), isBusy: true, pauseRequested: false, phase: .paused)
        XCTAssertEqual(resumed.state, .running, "The active controller takes precedence over the durable paused phase while resuming.")
        XCTAssertTrue(resumed.isIndeterminate)
    }

    func testFinalVerificationDoesNotShowFakeZeroOrHundredPercent() {
        let verifying = PackageProgressPresentation(snapshot: .init(completedCount: 1, totalCount: 1,
            stage: "核对照片包", name: "", fraction: 0), isBusy: true, pauseRequested: false, phase: .packing)
        XCTAssertNil(verifying.percentage)
        XCTAssertTrue(verifying.isIndeterminate)
        XCTAssertEqual(verifying.stage, "核对照片包")
        XCTAssertEqual(verifying.countText, "1 / 1")
    }

    func testOldLiveActivityPayloadStillDecodesWithoutResourceFraction() throws {
        let data = Data(#"{"completed":2,"total":4,"stage":"running","languageCode":"ar"}"#.utf8)
        let state = try JSONDecoder().decode(TransferActivityAttributes.ContentState.self, from: data)
        XCTAssertNil(state.currentFraction)
        XCTAssertNil(state.currentReadBytes)
        XCTAssertEqual(state.languageCode, "ar")
        XCTAssertEqual(state.progress, 0.5)
    }

    func testLiveActivityAdvancesWithinSingleResourceAndDiscardsUncommittedPauseProgress() {
        var state = TransferActivityAttributes.ContentState(completed: 0, total: 1,
            stage: .running, currentFraction: 0.42)
        XCTAssertEqual(state.progress, 0.42, accuracy: 0.0001)
        state.stage = .paused
        XCTAssertEqual(state.progress, 0)
        state.stage = .failed
        XCTAssertEqual(state.progress, 0)
        state.completed = 1
        state.stage = .finished
        XCTAssertEqual(state.progress, 1)
    }

    func testDecodedLiveActivityFractionIsClampedAtRenderBoundary() throws {
        let data = Data(#"{"completed":8,"total":9,"stage":"running","currentFraction":5}"#.utf8)
        let decoded = try JSONDecoder().decode(TransferActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.displayedCurrentFraction, 1)
        XCTAssertEqual(decoded.progress, 1)
        let invalid = TransferActivityAttributes.ContentState(completed: 0, total: 1,
            stage: .running, currentFraction: .nan)
        XCTAssertNil(invalid.currentFraction)
        XCTAssertEqual(invalid.progress, 0)
    }

    func testUnknownPhotoResourceSizeShowsRealBytesWithoutInventingPercentage() {
        let bytes: UInt64 = 384_000_000
        let reading = PackageProgressPresentation(snapshot: .init(completedCount: 0, totalCount: 1,
            stage: "读取原片", name: "film.mov", fraction: 1, readBytes: bytes),
            isBusy: true, pauseRequested: false, phase: .packing)
        XCTAssertEqual(reading.readBytes, bytes)
        XCTAssertTrue(reading.isIndeterminate)
        XCTAssertNil(reading.percentage, "Unknown total size must win over any placeholder fraction.")
        XCTAssertFalse(reading.compactText.contains("%"))
        XCTAssertNotEqual(reading.compactText, "0/1", "Actual bytes must be visible before the first resource commits.")
        XCTAssertEqual(reading.countText, "0 / 1")
        XCTAssertEqual(reading.barFraction, 0)
    }

    func testReadByteCounterClearsOnKnownSizeStageAndPause() {
        let readingSnapshot = PackageActivitySnapshot(completedCount: 8, totalCount: 9,
            stage: "读取原片", name: "film.mov", fraction: 0, readBytes: 0)
        let reading = PackageProgressPresentation(snapshot: readingSnapshot,
            isBusy: true, pauseRequested: false, phase: .packing)
        XCTAssertNotNil(reading.readBytesText, "Zero bytes still identifies an unknown-total read, not zero percent.")
        XCTAssertNil(reading.percentage)
        let paused = PackageProgressPresentation(snapshot: readingSnapshot,
            isBusy: false, pauseRequested: false, phase: .paused)
        XCTAssertNil(paused.readBytes)
        XCTAssertEqual(paused.compactText, "8/9")

        let hashing = PackageProgressPresentation(snapshot: .init(completedCount: 8, totalCount: 9,
            stage: "核对文件", name: "film.mov", fraction: 0.42),
            isBusy: true, pauseRequested: false, phase: .packing)
        XCTAssertNil(hashing.readBytes)
        XCTAssertEqual(hashing.compactText, "42%")
    }

    func testLiveActivityUnknownReadSizeSuppressesRatioAndClearsAtPause() throws {
        var state = TransferActivityAttributes.ContentState(completed: 0, total: 1,
            stage: .running, currentFraction: 0.99, currentReadBytes: 384_000_000)
        XCTAssertTrue(state.isReadingUnknownTotal)
        XCTAssertNil(state.displayedCurrentFraction)
        XCTAssertNotNil(state.readBytesText)
        XCTAssertEqual(state.progress, 0, "A byte counter without total size cannot contribute a percent.")
        let decoded = try JSONDecoder().decode(TransferActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.currentReadBytes, state.currentReadBytes)
        state.stage = .paused
        XCTAssertFalse(state.isReadingUnknownTotal)
        XCTAssertNil(state.readBytesText, "Provisional reads must not look like a persisted byte resume point.")
    }

    func testLiveActivityZeroAndLargeByteCountersRemainValid() {
        let zero = TransferActivityAttributes.ContentState(completed: 0, total: 1,
            stage: .running, currentReadBytes: 0)
        XCTAssertTrue(zero.isReadingUnknownTotal)
        XCTAssertNotNil(zero.readBytesText)
        let large = TransferActivityAttributes.ContentState(completed: 0, total: 1,
            stage: .running, currentReadBytes: .max)
        XCTAssertFalse(large.readBytesText?.isEmpty ?? true, "Formatting must not trap when decoding a large UInt64.")
        XCTAssertEqual(large.progress, 0)
    }
}
