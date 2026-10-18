import Foundation
import XCTest
@testable import RelayCore

final class ShareAlbumTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testDateNameUsesCaptureRangeAndIsIndependentOfInputOrder() {
        let dayOne = date("2026-10-12T22:30:00Z")
        let dayTwo = date("2026-10-13T06:30:00Z")
        XCTAssertEqual(ShareAlbumNaming.title(dates: [dayTwo, dayOne], timeZone: utc), "2026-10-12 – 2026-10-13")
        XCTAssertEqual(ShareAlbumNaming.title(dates: [dayOne, dayOne.addingTimeInterval(30)], timeZone: utc), "2026-10-12")
        XCTAssertEqual(ShareAlbumNaming.title(dates: [], fallback: dayTwo, timeZone: utc), "2026-10-13")
    }

    func testInitialNameUsesSendersCalendarDayAndPersistedTitleSurvivesTravel() throws {
        let capture = date("2026-10-12T22:30:00Z")
        let japan = TimeZone(identifier: "Asia/Tokyo")!
        let title = ShareAlbumNaming.title(dates: [capture], timeZone: japan)
        XCTAssertEqual(title, "2026-10-13")
        let album = ShareAlbumMetadata(title: title)
        XCTAssertEqual(try album.revised().title, "2026-10-13")
    }

    func testInvalidCaptureDatesDoNotPolluteVisibleName() {
        let fallback = date("2026-10-13T06:30:00Z")
        XCTAssertEqual(ShareAlbumNaming.title(dates: [Date(timeIntervalSinceReferenceDate: .nan)], fallback: fallback, timeZone: utc), "2026-10-13")
        XCTAssertEqual(ShareAlbumNaming.title(dates: [], fallback: Date(timeIntervalSinceReferenceDate: .infinity), timeZone: utc), "1970-01-01")
    }

    func testNewSnapshotRetainsLogicalAlbumAndUserTitleAcrossMembershipChanges() throws {
        let created = date("2026-10-12T22:30:00Z")
        let original = ShareAlbumMetadata(title: "海边旅行", createdAt: created)
        let revised = try original.revised(at: created.addingTimeInterval(3_600))
        XCTAssertEqual(revised.id, original.id)
        XCTAssertNotEqual(revised.snapshotID, original.snapshotID)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.title, "海边旅行")
        XCTAssertEqual(revised.createdAt, created)
        XCTAssertGreaterThan(revised.updatedAt, created)
        let decoded = try JSONDecoder().decode(ShareAlbumMetadata.self, from: JSONEncoder().encode(revised))
        XCTAssertEqual(decoded, revised)
    }

    func testRenameCreatesSnapshotWithoutLosingIdentityAndClockCannotMoveBackwards() throws {
        let original = ShareAlbumMetadata(title: "2026-10-12", createdAt: date("2026-10-12T22:30:00Z"))
        let renamed = try original.renamed(to: "旅行与视频", at: date("2026-10-11T22:30:00Z"))
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.title, "旅行与视频")
        XCTAssertEqual(renamed.updatedAt, original.updatedAt)
        XCTAssertNotEqual(renamed.snapshotID, original.snapshotID)
    }

    func testLegacyAlbumWithoutSenderRemainsReadable() throws {
        let original = ShareAlbumMetadata(title: "旧旅行相册")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "senderName")
        let decoded = try JSONDecoder().decode(ShareAlbumMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        try decoded.validate()
        XCTAssertNil(decoded.senderName)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
    }

    func testSenderSurvivesRevisionRenameAndPortableManifestRoundTrip() throws {
        let album = ShareAlbumMetadata(title: "海边旅行", senderName: "小雨的 iPhone")
        let revision = try album.revised()
        let renamed = try revision.renamed(to: "周末海边")
        XCTAssertEqual(revision.senderName, album.senderName)
        XCTAssertEqual(renamed.senderName, album.senderName)
        let manifest = PhotoPackageManifest(items: [.init(id: UUID().uuidString, photoPath: "photo.jpg")], album: renamed)
        try manifest.validate()
        let decoded = try JSONDecoder().decode(PhotoPackageManifest.self, from: JSONEncoder().encode(manifest))
        try decoded.validate()
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.album?.senderName, "小雨的 iPhone")
        XCTAssertEqual(decoded.album?.id, album.id)
    }

    func testSenderRejectsBlankOversizedAndControlCharactersBeforeManifestUse() throws {
        let invalidNames = ["", "   ", "Alice\nBob", "Alice\tBob", "Alice\0Bob", "Alice\u{202E}Bob",
                            "Alice\u{2028}Bob", "Alice\u{2029}Bob", String(repeating: "a", count: 129),
                            String(repeating: "你", count: 43)]
        for sender in invalidNames {
            let album = ShareAlbumMetadata(title: "旅行", senderName: sender)
            XCTAssertThrowsError(try album.validate(), "Accepted an invalid sender: \(sender.debugDescription)")
            let manifest = PhotoPackageManifest(items: [.init(id: UUID().uuidString, photoPath: "photo.jpg")], album: album)
            XCTAssertThrowsError(try manifest.validate())
        }
        for sender in ["Alice’s iPhone", "مریم\u{200C}های", "👩🏽‍💻的 iPad", String(repeating: "a", count: 128)] {
            XCTAssertNoThrow(try ShareAlbumMetadata(title: "旅行", senderName: sender).validate())
        }
    }

    func testSystemDeviceLabelSanitizationPreservesUnicodeAndDoesNotInventIdentity() throws {
        XCTAssertNil(ShareAlbumNaming.senderName(deviceName: " \n\t\u{202E}"))
        XCTAssertEqual(ShareAlbumNaming.senderName(deviceName: "  Alice\n的\u{2028}iPhone  "), "Alice 的 iPhone")
        let grapheme = "👩🏽‍💻"
        let bounded = try XCTUnwrap(ShareAlbumNaming.senderName(deviceName: String(repeating: grapheme, count: 100)))
        XCTAssertLessThanOrEqual(bounded.utf8.count, 128)
        XCTAssertTrue(bounded.allSatisfy { String($0) == grapheme })
        try ShareAlbumMetadata(title: "旅行", senderName: bounded).validate()
    }

    func testMalformedMetadataCannotEnterManifest() throws {
        let valid = ShareAlbumMetadata(title: "旅行")
        try valid.validate()
        var invalid = valid; invalid.revision = 0
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.title = "\n\t"
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.title = "旅行\0照片"
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.updatedAt = invalid.createdAt.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.createdAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.revision = Int.max
        XCTAssertThrowsError(try invalid.revised())
        XCTAssertThrowsError(try valid.revised(title: ""))
    }

    func testFilenamesRemainMeaningfulButNeverBecomePaths() {
        let name = ShareAlbumNaming.safeFilename(title: "../../海边/旅行\\视频: ?", extension: "dropack")
        XCTAssertEqual(name, "海边 旅行 视频.dropack")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertTrue(MediaPolicy.isSafeRelativePath(name))
        XCTAssertEqual(ShareAlbumNaming.safeFilename(title: " ... ", extension: "ZIP"), "分享相册.zip")
        XCTAssertEqual(ShareAlbumNaming.safeFilename(title: "CON", extension: "zip"), "_CON.zip")
        XCTAssertEqual(ShareAlbumNaming.safeFilename(title: "2026-10-12 – 2026-10-13", extension: "../zip"), "2026-10-12 – 2026-10-13.dropack")
    }

    func testFilenameBudgetUsesBytesAndPreservesUnicodeClusters() {
        let grapheme = "👩🏽‍💻"
        let filename = ShareAlbumNaming.safeFilename(title: String(repeating: grapheme, count: 100), extension: "dropack")
        XCTAssertLessThanOrEqual(filename.utf8.count, 188)
        let stem = String(filename.dropLast(".dropack".count))
        XCTAssertTrue(stem.allSatisfy { String($0) == grapheme })
        XCTAssertFalse(stem.isEmpty)
    }
}
