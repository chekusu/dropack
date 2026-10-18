import XCTest
@testable import RelayCore

final class MediaPolicyTests: XCTestCase {
    func testUnsafeArchivePathsAreRejected() {
        for path in ["../photo.jpg", "/photo.jpg", "a/../../photo.jpg", "a\\..\\photo.jpg", "C:\\photo.jpg", "a/./b.jpg", "a//b.jpg", "a\0b.jpg"] {
            XCTAssertFalse(MediaPolicy.isSafeRelativePath(path), path)
        }
        XCTAssertTrue(MediaPolicy.isSafeRelativePath("旅行/第二天/IMG_0001.HEIC"))
    }

    func testResourceForksAndHiddenMetadataAreIgnored() {
        for path in ["__MACOSX/IMG.jpg", "Trip/._IMG.jpg", ".DS_Store", "Trip/.cache/photo.jpg"] {
            XCTAssertTrue(MediaPolicy.shouldIgnore(path), path)
        }
        XCTAssertFalse(MediaPolicy.shouldIgnore("旅行/IMG.jpg"))
    }

    func testOnlySupportedMediaFormatsAreQueued() {
        XCTAssertEqual(MediaPolicy.kind(for: "trip/IMG.HEIC"), .photo)
        XCTAssertEqual(MediaPolicy.kind(for: "trip/MOV.Mp4"), .video)
        XCTAssertNil(MediaPolicy.kind(for: "index.txt"))
        XCTAssertNil(MediaPolicy.kind(for: "trip.zip"))
    }
}
