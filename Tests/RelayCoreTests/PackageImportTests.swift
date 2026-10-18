import Foundation
import XCTest
@testable import RelayCore

final class PackageImportTests: XCTestCase {
    private func media(_ path: String, kind: MediaKind, index: Int) -> ImportItem {
        ImportItem(id: "zip-\(index)", relativePath: path, kind: kind, byteCount: 40,
                   archiveIndex: index, checksum: UInt32(index))
    }

    func testLivePhotoMapsTwoResourcesToOneResumableItem() throws {
        let id = UUID().uuidString
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = PhotoPackageManifest(items: [PhotoPackageManifestItem(
            id: id, photoPath: "media/a/original.heic", videoPath: "media/a/paired.mov",
            creationDate: date, isLivePhoto: true, photoSHA256: String(repeating: "a", count: 64))])
        let items = try PackageImportResolver.resolve(manifest, scanned: [
            media("media/a/original.heic", kind: .photo, index: 0),
            media("media/a/paired.mov", kind: .video, index: 1)])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "dropack:\(id)")
        XCTAssertEqual(items[0].resourceBytes, 80)
        XCTAssertEqual(items[0].creationDate, date)
        XCTAssertEqual(items[0].pairedVideo?.archiveIndex, 1)
        XCTAssertEqual(items[0].expectedSHA256, String(repeating: "a", count: 64))
        let source = SourceDescriptor(kind: .zip, name: "test.zip", bookmark: Data())
        let job = ImportJob(source: source, items: items)
        XCTAssertEqual(job.totalBytes, 80)
        XCTAssertEqual(job.largestItemBytes, 80)
    }

    func testMissingPairedResourceCannotSilentlyImportStillImage() throws {
        let manifest = PhotoPackageManifest(items: [PhotoPackageManifestItem(
            id: UUID().uuidString, photoPath: "a.jpg", videoPath: "a.mov", isLivePhoto: true)])
        XCTAssertThrowsError(try PackageImportResolver.resolve(manifest,
            scanned: [media("a.jpg", kind: .photo, index: 0)]))
    }

    func testDuplicateZIPPathReferencedByManifestIsRejected() throws {
        let manifest = PhotoPackageManifest(items: [PhotoPackageManifestItem(id: UUID().uuidString, photoPath: "a.jpg")])
        XCTAssertThrowsError(try PackageImportResolver.resolve(manifest, scanned: [
            media("a.jpg", kind: .photo, index: 0), media("a.jpg", kind: .photo, index: 1)]))
    }

    func testUnlistedMediaIsNotSilentlyDropped() throws {
        let manifest = PhotoPackageManifest(items: [PhotoPackageManifestItem(id: UUID().uuidString, photoPath: "a.jpg")])
        XCTAssertThrowsError(try PackageImportResolver.resolve(manifest, scanned: [
            media("a.jpg", kind: .photo, index: 0), media("b.jpg", kind: .photo, index: 1)]))
    }

    func testReplacementIncludesPairAndContentHashes() throws {
        var item = media("a.jpg", kind: .photo, index: 0)
        item.pairedVideo = ImportResource(item: media("a.mov", kind: .video, index: 1))
        let job = ImportJob(source: SourceDescriptor(kind: .zip, name: "a.zip", bookmark: Data()), items: [item])
        var changed = item
        changed.pairedVideo?.checksum = 999
        XCTAssertFalse(job.matchesReplacement([changed]))
        changed = item
        changed.expectedSHA256 = String(repeating: "0", count: 64)
        XCTAssertFalse(job.matchesReplacement([changed]))
        XCTAssertTrue(job.matchesReplacement([item]))
        let encoded = try JSONEncoder().encode(job)
        XCTAssertEqual(try JSONDecoder().decode(ImportJob.self, from: encoded).items, [item])
    }
}
