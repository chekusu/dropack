import Foundation
import XCTest
@testable import RelayCore

final class AlbumDetailPolicyTests: XCTestCase {
    private func album(revision: Int, alreadyImported: Bool = false) -> ImportJob {
        var old = ImportItem(id: "dropack:one", relativePath: "one.jpg", kind: .photo, byteCount: 1, state: .saved)
        old.alreadyImported = alreadyImported
        let next = ImportItem(id: "dropack:two", relativePath: "two.jpg", kind: .photo, byteCount: 1)
        var job = ImportJob(source: SourceDescriptor(kind: .zip, name: "Album.dropack", bookmark: Data()), items: [old, next])
        job.purpose = .sharedAlbum
        job.album = ShareAlbumMetadata(revision: revision, title: "Trip")
        return job
    }

    func testPausedFirstSyncKeepsSyncActionAfterSavingSomePhotos() {
        var job = album(revision: 1)
        job.phase = .paused
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .synchronize)
    }

    func testNewRecipientOfLaterRevisionStillStartsWithSync() {
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: album(revision: 4)), .synchronize)
    }

    func testConfirmedAlbumUpdateUsesUpdateUntilCompleted() {
        var job = album(revision: 2, alreadyImported: true)
        job.isAlbumUpdate = true
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .update)
        job.items[1].state = .saved
        job.phase = .completed
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .synchronize)
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job).titleKey, "同步到相册")
    }

    func testSameFirstRevisionDoesNotTurnDuplicatesIntoAnUpdate() {
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: album(revision: 1, alreadyImported: true)), .synchronize)
    }

    func testReopenedFirstImportDoesNotTreatGlobalDuplicatesAsAnAlbumUpdate() {
        var job = album(revision: 4, alreadyImported: true)
        job.phase = .paused
        job.isAlbumUpdate = false
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .synchronize)
        job.isAlbumUpdate = nil
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .synchronize)
    }

    func testCompletedOrdinaryImportRetainsFinishAction() {
        var job = album(revision: 1)
        job.purpose = .oneTimeImport
        job.items[1].state = .saved
        job.phase = .completed
        XCTAssertEqual(AlbumDetailPolicy.primaryAction(for: job), .finish)
        XCTAssertTrue(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: false, needsRelink: true))
    }

    func testCompleteSharedAlbumStaysDisabledAfterSourceIsDisconnected() {
        var job = album(revision: 2)
        job.isAlbumUpdate = true
        job.items[1].state = .saved
        job.phase = .completed
        XCTAssertFalse(job.hasUnresolvedItems)
        XCTAssertFalse(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: false, needsRelink: true))
        XCTAssertFalse(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: false, needsRelink: false))
    }

    func testIncompleteSharedAlbumCanReconnectToFinishItsImport() {
        let job = album(revision: 1)
        XCTAssertTrue(job.hasUnresolvedItems)
        XCTAssertTrue(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: false, needsRelink: true))
        XCTAssertTrue(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: true, needsRelink: false))
        XCTAssertFalse(AlbumDetailPolicy.canPerformPrimaryAction(for: job, canStart: false, needsRelink: false))
    }

    func testDateRangeOmitsUnknownAndNonfiniteDates() {
        XCTAssertNil(AlbumDetailPolicy.captureDateRange([]))
        XCTAssertNil(AlbumDetailPolicy.captureDateRange([Date(timeIntervalSinceReferenceDate: .nan)]))
        let first = Date(timeIntervalSince1970: 100)
        let last = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(AlbumDetailPolicy.captureDateRange([last, first, Date(timeIntervalSinceReferenceDate: .infinity)]), first...last)
    }
}
