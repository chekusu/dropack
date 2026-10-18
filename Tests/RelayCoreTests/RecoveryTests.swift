import XCTest
@testable import RelayCore

final class RecoveryTests: XCTestCase {
    private func item(_ id: String, state: ItemState = .pending, size: UInt64 = 20) -> ImportItem {
        ImportItem(id: id, relativePath: "trip/\(id).jpg", kind: .photo, byteCount: size, state: state)
    }
    private func job(_ items: [ImportItem]) -> ImportJob {
        ImportJob(source: .init(kind: .zip, name: "trip.zip", bookmark: Data([1, 2])), items: items)
    }

    func testInterruptedPhotosCommitIsNeverAutomaticallyRetried() {
        var state = job([item("done", state: .saved), item("saving", state: .inFlight), item("next")])
        state.phase = .running
        state.recoverAfterInterruption()
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.items.map(\.state), [.saved, .uncertain, .pending])
        state.retryFailures()
        XCTAssertEqual(state.items[1].state, .uncertain)
        XCTAssertEqual(state.savedCount, 1)
    }

    func testUserCanResolveUncertainCommitWithoutResettingOtherItems() {
        var state = job([item("done", state: .saved), item("uncertain", state: .uncertain), item("pending")])
        state.resolveUncertain(id: "uncertain", asSaved: true)
        XCTAssertEqual(state.items.map(\.state), [.saved, .saved, .pending])
        state.resolveUncertain(id: "done", asSaved: false)
        XCTAssertEqual(state.items[0].state, .saved)
    }

    func testExplicitRetryResetsOnlyKnownFailures() {
        var state = job([item("failed", state: .failed), item("unknown", state: .uncertain), item("done", state: .saved)])
        state.phase = .completed
        state.retryFailures()
        XCTAssertEqual(state.items.map(\.state), [.pending, .uncertain, .saved])
        XCTAssertEqual(state.phase, .paused)
    }

    func testReplacementRequiresSameManifestIncludingDuplicateArchiveNames() {
        var first = item("entry-1")
        first.relativePath = "photo.jpg"; first.archiveIndex = 1; first.checksum = 123
        var second = first
        second.id = "entry-2"; second.archiveIndex = 2; second.checksum = 456
        let state = job([first, second])
        XCTAssertTrue(state.matchesReplacement([second, first]))
        XCTAssertFalse(state.matchesReplacement([first, first]))
        var changed = second; changed.byteCount += 1
        XCTAssertFalse(state.matchesReplacement([first, changed]))
        XCTAssertFalse(state.matchesReplacement([first]))
    }

    func testProgressDistinguishesSavedAndFailedAndSupportsLargeFiles() {
        let state = job([item("large", state: .saved, size: 24_000_000_000), item("failed", state: .failed), item("next")])
        XCTAssertEqual(state.savedCount, 1)
        XCTAssertEqual(state.failedCount, 1)
        XCTAssertEqual(state.processedCount, 2)
        XCTAssertEqual(state.progress, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(state.savedBytes, 24_000_000_000)
        XCTAssertEqual(state.totalBytes, 24_000_000_040)
    }

    func testByteTotalsDoNotOverflowOnMalformedSizes() {
        let state = job([item("a", size: .max), item("b", size: 1)])
        XCTAssertEqual(state.totalBytes, .max)
    }
}
