import Foundation
import RelayCore
import XCTest
import ZIPFoundation

final class ZIPIntegrationTests: XCTestCase {
    func testOrdinaryArchiveDirectoryMatchesRealZIPFoundationEnumeration() throws {
        let url = try fixture("ordinary.zip")
        let directory = try validate(url)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        XCTAssertEqual(UInt64(entries.count), directory.entryCount)
        XCTAssertEqual(entries.count, 5)
        for entry in entries where entry.type == .file {
            var written = 0
            let crc = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { data in
                written += data.count
            }
            XCTAssertEqual(crc, entry.checksum)
            XCTAssertEqual(UInt64(written), entry.uncompressedSize)
        }
    }

    func testDuplicatePathsRemainDistinctByArchiveIndex() throws {
        let archive = try Archive(url: fixture("ordinary.zip"), accessMode: .read)
        let duplicates = Array(archive.enumerated()).filter { $0.element.path == "photos/duplicate.jpg" }
        XCTAssertEqual(duplicates.map(\.offset), [1, 2])
        XCTAssertNotEqual(duplicates[0].element, duplicates[1].element)
        var extracted: [Data] = []
        for (_, entry) in duplicates {
            var bytes = Data()
            let crc = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { bytes.append($0) }
            XCTAssertEqual(crc, entry.checksum)
            extracted.append(bytes)
        }
        XCTAssertEqual(extracted, [Data("first photo".utf8), Data("second photo".utf8)])
    }

    func testZIP64DirectoryAndEntriesWorkWithRealZIPFoundation() throws {
        let url = try fixture("zip64.zip")
        let directory = try validate(url)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        XCTAssertEqual(UInt64(entries.count), directory.entryCount)
        XCTAssertEqual(entries.map(\.path), ["photos/large-layout.jpg", "videos/clip.mov"])
        var extracted: [Data] = []
        for entry in entries {
            var bytes = Data()
            let crc = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { bytes.append($0) }
            XCTAssertEqual(crc, entry.checksum)
            XCTAssertEqual(UInt64(bytes.count), entry.uncompressedSize)
            extracted.append(bytes)
        }
        XCTAssertEqual(extracted, [Data("ZIP64 photo payload".utf8), Data("ZIP64 video payload".utf8)])
    }

    func testConsumerExtractionReturnsMismatchedCRCRatherThanThrowing() throws {
        let url = try fixture("bad-crc.zip")
        _ = try validate(url)
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive.makeIterator().next())
        var written: UInt64 = 0
        let crc = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { data in
            written += UInt64(data.count)
        }
        XCTAssertEqual(written, entry.uncompressedSize)
        XCTAssertNotEqual(crc, entry.checksum,
                          "The application must compare the returned CRC itself after consumer extraction.")
    }

    func testEncryptedEntryCannotSilentlyLookLikeEmptySuccessfulScan() throws {
        let url = try fixture("encrypted-flag.zip")
        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertEqual(Array(archive).count, 0, "ZIPFoundation ends its iterator at encrypted entries.")
        XCTAssertThrowsError(try validate(url)) { error in
            guard case ZipValidationError.encrypted = error else {
                return XCTFail("Expected encrypted error, received \(error)")
            }
        }
    }

    func testMultipartAndTruncatedSourcesAreRejected() throws {
        XCTAssertThrowsError(try validate(fixture("multipart.zip"))) { error in
            guard case ZipValidationError.multipart = error else {
                return XCTFail("Expected multipart error, received \(error)")
            }
        }
        XCTAssertThrowsError(try validate(fixture("truncated.zip"))) { error in
            guard case ZipValidationError.invalid = error else {
                return XCTFail("Expected invalid archive error, received \(error)")
            }
        }
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    private func validate(_ url: URL) throws -> ZipDirectory {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try ZipDirectoryValidator.validate(url: url,
            byteCount: UInt64(try XCTUnwrap(values.fileSize)))
    }
}
