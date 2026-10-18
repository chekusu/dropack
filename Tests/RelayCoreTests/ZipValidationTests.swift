import XCTest
@testable import RelayCore

final class ZipValidationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func put(_ value: UInt64, at offset: Int, width: Int, in data: inout Data) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    /// Central records are sufficient for this metadata validator; extraction is ZIPFoundation's job.
    private func central(flags: UInt64 = 0, name: String = "photo.jpg") -> Data {
        var result = Data(repeating: 0, count: 46)
        put(0x02014b50, at: 0, width: 4, in: &result)
        put(20, at: 6, width: 2, in: &result)
        put(flags, at: 8, width: 2, in: &result)
        put(UInt64(name.utf8.count), at: 28, width: 2, in: &result)
        result.append(contentsOf: name.utf8)
        return result
    }
    private func end(offset: UInt64, size: UInt64, count: UInt64 = 1, disk: UInt64 = 0) -> Data {
        var result = Data(repeating: 0, count: 22)
        put(0x06054b50, at: 0, width: 4, in: &result)
        put(disk, at: 4, width: 2, in: &result)
        put(count, at: 8, width: 2, in: &result)
        put(count, at: 10, width: 2, in: &result)
        put(size, at: 12, width: 4, in: &result)
        put(offset, at: 16, width: 4, in: &result)
        return result
    }
    private func write(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }
    private func validate(_ data: Data) throws -> ZipDirectory {
        try ZipDirectoryValidator.validate(url: write(data), byteCount: UInt64(data.count))
    }

    func testOrdinaryDirectoryAndEmptyZIP() throws {
        let record = central()
        let parsed = try validate(record + end(offset: 0, size: UInt64(record.count)))
        XCTAssertEqual(parsed.entryCount, 1)
        XCTAssertEqual(parsed.byteCount, UInt64(record.count))
        XCTAssertEqual(try validate(end(offset: 0, size: 0, count: 0)).entryCount, 0)
    }

    func testEncryptedArchiveCannotSilentlyScanAsEmpty() throws {
        for flags: UInt64 in [1, 0x40] {
            let record = central(flags: flags)
            XCTAssertThrowsError(try validate(record + end(offset: 0, size: UInt64(record.count)))) { error in
                guard case ZipValidationError.encrypted = error else { return XCTFail("Unexpected: \(error)") }
            }
        }
    }

    func testMultipartArchiveIsExplicitlyRejected() throws {
        let record = central()
        XCTAssertThrowsError(try validate(record + end(offset: 0, size: UInt64(record.count), disk: 1))) { error in
            guard case ZipValidationError.multipart = error else { return XCTFail("Unexpected: \(error)") }
        }
    }

    func testTruncationAndOversizedFilenameAreRejected() throws {
        let record = central()
        let archive = record + end(offset: 0, size: UInt64(record.count))
        XCTAssertThrowsError(try validate(Data(archive.dropLast())))
        var damaged = record
        put(65_535, at: 28, width: 2, in: &damaged)
        XCTAssertThrowsError(try validate(damaged + end(offset: 0, size: UInt64(damaged.count))))
        XCTAssertThrowsError(try validate(record + end(offset: 1000, size: UInt64(record.count))))
    }

    func testZIPCommentContainingEndSignatureDoesNotConfuseSearch() throws {
        let record = central()
        var ending = end(offset: 0, size: UInt64(record.count))
        let comment = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 30))
        put(UInt64(comment.count), at: 20, width: 2, in: &ending)
        XCTAssertEqual(try validate(record + ending + comment).entryCount, 1)
    }

    func testZIP64OffsetsBeyondFourGBUseBoundedReads() throws {
        // Sparse file exercises actual UInt64 file offsets without allocating or reading 5 GB.
        let offset: UInt64 = 5_000_000_000
        let record = central()
        let zip64Offset = offset + UInt64(record.count)
        var zip64 = Data(repeating: 0, count: 56)
        put(0x06064b50, at: 0, width: 4, in: &zip64)
        put(44, at: 4, width: 8, in: &zip64)
        put(45, at: 12, width: 2, in: &zip64)
        put(45, at: 14, width: 2, in: &zip64)
        put(1, at: 24, width: 8, in: &zip64)
        put(1, at: 32, width: 8, in: &zip64)
        put(UInt64(record.count), at: 40, width: 8, in: &zip64)
        put(offset, at: 48, width: 8, in: &zip64)
        var locator = Data(repeating: 0, count: 20)
        put(0x07064b50, at: 0, width: 4, in: &locator)
        put(zip64Offset, at: 8, width: 8, in: &locator)
        put(1, at: 16, width: 4, in: &locator)
        let ending = end(offset: UInt64(UInt32.max), size: UInt64(UInt32.max), count: UInt64(UInt16.max))
        let url = try write(Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: record + zip64 + locator + ending)
        try handle.close()
        let parsed = try ZipDirectoryValidator.validate(url: url, byteCount: zip64Offset + 56 + 20 + 22)
        XCTAssertEqual(parsed.offset, offset)
        XCTAssertEqual(parsed.entryCount, 1)
        XCTAssertEqual(parsed.boundary, zip64Offset)
    }

    func testZIP64SentinelsWithoutLocatorAreRejected() throws {
        let record = central()
        XCTAssertThrowsError(try validate(record + end(offset: UInt64(UInt32.max), size: UInt64(record.count))))
    }
}
