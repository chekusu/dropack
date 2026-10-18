import Foundation
import RelayCore
import XCTest
import ZIPFoundation

final class PackageZIPReuseTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRetainedRawRecordsAreExactAndDeletedPayloadIsPhysicallyAbsent() throws {
        let source = root.appendingPathComponent("old.zip"), target = root.appendingPathComponent("new.zip")
        let secret = Data("DELETED-PRIVATE-VIDEO-SENTINEL-949823919".utf8)
        let keep = Data(repeating: 0x67, count: 2 * 1024 * 1024 + 13)
        let records = try make(source, entries: [("keep.mov", keep), ("delete.mov", secret), (PhotoPackageManifest.filename, Data("old-manifest".utf8))])
        _ = try make(target, entries: [])
        let backup = root.appendingPathComponent("directory-backup.bin")
        _ = try PackageRecovery.snapshot(archive: target, backup: backup)
        var lastCopied: UInt64 = 0
        try PackageZIPReuse.append(from: source, to: target, records: [records[0]], directoryBackup: backup) { bytes, total in
            XCTAssertLessThanOrEqual(bytes, total); lastCopied = bytes
        }
        XCTAssertGreaterThan(lastCopied, UInt64(keep.count))
        let archive = try Archive(url: target, accessMode: .read)
        XCTAssertEqual(Array(archive).map(\.path), ["keep.mov"])
        var result = Data()
        _ = try archive.extract(XCTUnwrap(archive["keep.mov"])) { result.append($0) }
        XCTAssertEqual(result, keep)
        XCTAssertNil(try Data(contentsOf: target).range(of: secret), "Deleted bytes cannot hide outside the central directory")
        XCTAssertNotNil(try Data(contentsOf: source).range(of: secret), "Old snapshots remain unchanged")
    }

    func testCancelledRawAppendRollsBackExactlyThenResumes() throws {
        let source = root.appendingPathComponent("old.zip"), target = root.appendingPathComponent("new.zip")
        let records = try make(source, entries: [("movie.mov", Data(repeating: 0x54, count: 3 * 1024 * 1024))])
        _ = try make(target, entries: [("first.jpg", Data("first".utf8))])
        let before = try Data(contentsOf: target)
        let backup = root.appendingPathComponent("directory-backup.bin")
        let transaction = try PackageRecovery.snapshot(archive: target, backup: backup)
        XCTAssertThrowsError(try PackageZIPReuse.append(from: source, to: target, records: records, directoryBackup: backup) { _, _ in throw CancellationError() })
        try PackageRecovery.rollback(transaction, archive: target, backup: backup)
        XCTAssertEqual(try Data(contentsOf: target), before)
        try PackageZIPReuse.append(from: source, to: target, records: records, directoryBackup: backup)
        XCTAssertEqual(Array(try Archive(url: target, accessMode: .read)).map(\.path), ["first.jpg", "movie.mov"])
    }

    func testCloneDropsManifestWithoutReadingPayloadAndOldInodeIsUntouched() throws {
        let source = root.appendingPathComponent("old.zip"), target = root.appendingPathComponent("new.zip")
        let records = try make(source, entries: [("keep.mov", Data(repeating: 0x4F, count: 3 * 1024 * 1024)),
            (PhotoPackageManifest.filename, Data("STALE-MANIFEST-PRIVATE-89876".utf8))])
        let before = try Data(contentsOf: source)
        let originalDestination = root.appendingPathComponent("empty.zip")
        _ = try make(originalDestination, entries: [])
        let emptyBytes = try Data(contentsOf: originalDestination)
        let backup = root.appendingPathComponent("directory-backup.bin")
        let transaction = try PackageRecovery.snapshot(archive: originalDestination, backup: backup)
        guard try PackageZIPReuse.cloneRemovingLastManifest(from: source, to: target, retained: [records[0]], manifest: records[1]) else {
            throw XCTSkip("Filesystem does not support clonefile; raw-copy fallback covered separately")
        }
        let oldInode = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        let newInode = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(oldInode, newInode)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(Array(try Archive(url: target, accessMode: .read)).map(\.path), ["keep.mov"])
        XCTAssertNil(try Data(contentsOf: target).range(of: Data("STALE-MANIFEST-PRIVATE-89876".utf8)))
        // ZIPFoundation must be able to append to our ZIP64 directory.
        let archive = try Archive(url: target, accessMode: .update)
        try archive.addEntry(with: "new.jpg", type: .file, uncompressedSize: Int64(3)) { _, _ in Data("new".utf8) }
        XCTAssertEqual(Array(archive).map(\.path), ["keep.mov", "new.jpg"])
        // Simulate the cloned archive being installed before its journal commit.
        try PackageRecovery.rollback(transaction, archive: target, backup: backup)
        XCTAssertEqual(try Data(contentsOf: target), emptyBytes)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testZIP64SourceOffsetsAreRelocatedAndForgedRecordIsRejected() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "zip64.zip", withExtension: nil, subdirectory: "Fixtures"))
        let target = root.appendingPathComponent("new.zip")
        _ = try make(target, entries: [])
        let sourceArchive = try Archive(url: source, accessMode: .read)
        let entry = try XCTUnwrap(sourceArchive["videos/clip.mov"])
        let record = PackageArchiveRecord(path: entry.path, byteCount: entry.uncompressedSize, checksum: entry.checksum)
        let backup = root.appendingPathComponent("directory-backup.bin")
        _ = try PackageRecovery.snapshot(archive: target, backup: backup)
        try PackageZIPReuse.append(from: source, to: target, records: [record], directoryBackup: backup)
        let archive = try Archive(url: target, accessMode: .read)
        var data = Data(); _ = try archive.extract(XCTUnwrap(archive[record.path])) { data.append($0) }
        XCTAssertEqual(data, Data("ZIP64 video payload".utf8))
        var wrong = record; wrong.checksum ^= 1
        XCTAssertThrowsError(try PackageZIPReuse.append(from: source, to: target, records: [wrong], directoryBackup: backup))
    }

    func testRetainedEntryOffsetUpgradesToZIP64BeyondFourGiB() throws {
        let source = root.appendingPathComponent("small.zip"), target = root.appendingPathComponent("sparse.zip")
        let payload = Data("retained after four gigabytes".utf8)
        let records = try make(source, entries: [("retained.mov", payload)])
        try makeSparseArchive(target)
        let backup = root.appendingPathComponent("directory-backup.bin")
        _ = try PackageRecovery.snapshot(archive: target, backup: backup)
        try PackageZIPReuse.append(from: source, to: target, records: records, directoryBackup: backup)
        let archive = try Archive(url: target, accessMode: .read)
        XCTAssertEqual(Array(archive).map(\.path), ["large.mov", "retained.mov"])
        var actual = Data()
        _ = try archive.extract(XCTUnwrap(archive["retained.mov"])) { actual.append($0) }
        XCTAssertEqual(actual, payload)
        XCTAssertGreaterThan(try PackageRecovery.fileSize(target), UInt64(UInt32.max))
    }

    /// Sparse bytes exercise real >4GiB offsets without allocating/reading a
    /// synthetic video or spending gigabytes of test storage.
    private func makeSparseArchive(_ url: URL) throws {
        func word(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        let name = Data("large.mov".utf8), size = UInt64(UInt32.max) + 4096
        var local = Data()
        for (v, n) in [(UInt64(0x04034b50),4),(45,2),(0,2),(0,2),(0,2),(0,2),(0,4),(UInt64(UInt32.max),4),(UInt64(UInt32.max),4),(UInt64(name.count),2),(20,2)] { local.append(word(v,n)) }
        local.append(name); local.append(word(1,2)); local.append(word(16,2)); local.append(word(size,8)); local.append(word(size,8))
        _ = FileManager.default.createFile(atPath: url.path, contents: local)
        let output = try FileHandle(forUpdating: url); defer { try? output.close() }
        let directoryOffset = UInt64(local.count) + size
        try output.seek(toOffset: directoryOffset)
        var central = Data()
        for (v,n) in [(UInt64(0x02014b50),4),(45,2),(45,2),(0,2),(0,2),(0,2),(0,2),(0,4),(UInt64(UInt32.max),4),(UInt64(UInt32.max),4),(UInt64(name.count),2),(20,2),(0,2),(0,2),(0,2),(0,4),(0,4)] { central.append(word(v,n)) }
        central.append(name); central.append(word(1,2)); central.append(word(16,2)); central.append(word(size,8)); central.append(word(size,8))
        try output.write(contentsOf: central)
        let zip64Offset = try output.offset()
        var tail = Data()
        for (v,n) in [(UInt64(0x06064b50),4),(44,8),(45,2),(45,2),(0,4),(0,4),(1,8),(1,8),(UInt64(central.count),8),(directoryOffset,8),(0x07064b50,4),(0,4),(zip64Offset,8),(1,4),(0x06054b50,4),(0,2),(0,2),(65535,2),(65535,2),(UInt64(UInt32.max),4),(UInt64(UInt32.max),4),(0,2)] { tail.append(word(v,n)) }
        try output.write(contentsOf: tail); try output.synchronize()
    }

    private func make(_ url: URL, entries: [(String, Data)]) throws -> [PackageArchiveRecord] {
        let archive = try Archive(url: url, accessMode: .create)
        var records: [PackageArchiveRecord] = []
        for (path, bytes) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .none) { position, size in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + size))
            }
            let entry = try XCTUnwrap(archive[path]); records.append(.init(path: path, byteCount: entry.uncompressedSize, checksum: entry.checksum))
        }
        return records
    }
}
