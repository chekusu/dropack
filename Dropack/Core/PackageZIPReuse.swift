import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Copies complete local ZIP records without opening originals, inflating or
/// hashing their payloads. Only explicitly retained records enter the new ZIP.
/// The caller journals PackageRecovery.snapshot before invoking append.
public enum PackageZIPReuse {
    fileprivate struct Entry: Sendable {
        let path: String
        let offset: UInt64
        let localBytes: UInt64
        let compressedBytes: UInt64
        let bytes: UInt64
        let checksum: UInt32
        let central: Data
    }

    /// One bounded metadata index per immutable source, avoiding a directory
    /// rescan for every asset in a very large album.
    public struct Source: Sendable {
        fileprivate let url: URL
        fileprivate let entries: [String: Entry]
    }
    public static func prepare(_ source: URL, records: [PackageArchiveRecord]) throws -> Source {
        let entries = try selectedEntries(source, records: records)
        return Source(url: source, entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) }))
    }

    public static func append(from source: URL, to destination: URL,
                              records: [PackageArchiveRecord], directoryBackup: URL,
                              progress: (UInt64, UInt64) throws -> Void = { _, _ in }) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL, !records.isEmpty else {
            throw PackageModelError.invalidCheckpoint
        }
        try append(from: prepare(source, records: records), to: destination, records: records,
                   directoryBackup: directoryBackup, progress: progress)
    }

    public static func append(from source: Source, to destination: URL,
                              records: [PackageArchiveRecord], directoryBackup: URL,
                              progress: (UInt64, UInt64) throws -> Void = { _, _ in }) throws {
        guard source.url.standardizedFileURL != destination.standardizedFileURL,
              !records.isEmpty, Set(records.map(\.path)).count == records.count else { throw PackageModelError.invalidCheckpoint }
        let entries = try records.map { record -> Entry in
            guard let entry = source.entries[record.path], entry.bytes == record.byteCount,
                  entry.checksum == record.checksum else { throw PackageModelError.invalidCheckpoint }
            return entry
        }
        let existing = try ZipDirectoryValidator.validate(url: destination, byteCount: PackageRecovery.fileSize(destination))
        guard existing.entryCount + UInt64(entries.count) <= UInt64(PackageFormatLimits.maxZIPEntries) else {
            throw PackageLimitError.archiveTooLarge
        }
        let input = try FileHandle(forReadingFrom: source.url)
        let backup = try FileHandle(forReadingFrom: directoryBackup)
        let output = try FileHandle(forUpdating: destination)
        defer { try? input.close(); try? backup.close(); try? output.close() }
        try output.seek(toOffset: existing.offset)
        let total = entries.reduce(UInt64(0)) { $0 + $1.localBytes }
        var copied: UInt64 = 0
        var rewritten: [Data] = [] // At most original + paired video + preview.
        for entry in entries {
            try Task.checkCancellation()
            let offset = try output.offset()
            try input.seek(toOffset: entry.offset)
            try copy(input, output, count: entry.localBytes) { amount in
                copied += amount; try progress(copied, total)
            }
            rewritten.append(try relocated(entry, offset: offset))
        }
        let directoryOffset = try output.offset()
        try copy(backup, output, count: existing.byteCount)
        for data in rewritten { try output.write(contentsOf: data) }
        let directoryBytes = try output.offset() - directoryOffset
        try finish(output, count: existing.entryCount + UInt64(entries.count), offset: directoryOffset, bytes: directoryBytes)
    }

    /// APFS clone is copy-on-write, never a hard link. This path reads ZIP
    /// headers/directories only; no retained video payload is read or copied.
    /// It is intentionally opportunistic: unsupported filesystems return false.
    public static func cloneRemovingLastManifest(from source: URL, to destination: URL,
                                                retained: [PackageArchiveRecord], manifest: PackageArchiveRecord) throws -> Bool {
        let all = try selectedEntries(source, records: retained + [manifest])
        guard let last = all.last, last.path == PhotoPackageManifest.filename else { throw PackageModelError.invalidCheckpoint }
        let directory = try ZipDirectoryValidator.validate(url: source, byteCount: PackageRecovery.fileSize(source))
        guard UInt64(all.count) == directory.entryCount, last.offset + last.localBytes == directory.offset,
              all.dropLast().allSatisfy({ $0.offset + $0.localBytes <= last.offset }) else {
            throw PackageModelError.invalidCheckpoint
        }
        #if canImport(Darwin)
        let cloned = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                clonefile(sourcePath!, destinationPath!, 0) == 0
            }
        }
        guard cloned else { return false }
        #else
        return false
        #endif
        do {
            let output = try FileHandle(forUpdating: destination)
            defer { try? output.close() }
            try output.seek(toOffset: last.offset)
            for entry in all.dropLast() { try Task.checkCancellation(); try output.write(contentsOf: entry.central) }
            let bytes = try output.offset() - last.offset
            try finish(output, count: UInt64(all.count - 1), offset: last.offset, bytes: bytes)
            return true
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    private static func selectedEntries(_ url: URL, records: [PackageArchiveRecord]) throws -> [Entry] {
        let size = try PackageRecovery.fileSize(url)
        let directory = try ZipDirectoryValidator.validate(url: url, byteCount: size)
        guard Set(records.map(\.path)).count == records.count else { throw PackageModelError.invalidCheckpoint }
        let expected = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var cursor = directory.offset
        var found: [String: Entry] = [:]
        for _ in 0..<directory.entryCount {
            try Task.checkCancellation()
            try input.seek(toOffset: cursor)
            let header = try read(input, 46)
            guard header.u32(0) == 0x02014b50 else { throw PackageModelError.invalidCheckpoint }
            let nameCount = Int(header.u16(28)), extraCount = Int(header.u16(30)), commentCount = Int(header.u16(32))
            let rest = try read(input, nameCount + extraCount + commentCount)
            let central = header + rest
            cursor += UInt64(central.count)
            guard cursor <= directory.offset + directory.byteCount,
                  let path = String(data: rest.prefix(nameCount), encoding: .utf8) else { throw PackageModelError.invalidCheckpoint }
            guard let record = expected[path] else { continue }
            guard found[path] == nil, header.u16(8) & 0x0009 == 0 else { throw PackageModelError.invalidCheckpoint }
            var bytes = UInt64(header.u32(24)), compressed = UInt64(header.u32(20)), offset = UInt64(header.u32(42))
            let extra = Data(rest.dropFirst(nameCount).prefix(extraCount))
            var p = 0, zip64: Data?
            while p < extra.count {
                guard p + 4 <= extra.count else { throw PackageModelError.invalidCheckpoint }
                let length = Int(extra.u16(p + 2))
                guard p + 4 + length <= extra.count else { throw PackageModelError.invalidCheckpoint }
                if extra.u16(p) == 1 { guard zip64 == nil else { throw PackageModelError.invalidCheckpoint }; zip64 = Data(extra[(p+4)..<(p+4+length)]) }
                p += 4 + length
            }
            var q = 0
            func extended(_ value: UInt64) throws -> UInt64 {
                guard value == UInt64(UInt32.max) else { return value }
                guard let zip64, q + 8 <= zip64.count else { throw PackageModelError.invalidCheckpoint }
                defer { q += 8 }; return zip64.u64(q)
            }
            bytes = try extended(bytes); compressed = try extended(compressed); offset = try extended(offset)
            guard bytes == record.byteCount, header.u32(16) == record.checksum,
                  offset < directory.offset else { throw PackageModelError.invalidCheckpoint }
            try input.seek(toOffset: offset)
            let local = try read(input, 30)
            guard local.u32(0) == 0x04034b50, local.u16(6) == header.u16(8), local.u16(8) == header.u16(10) else {
                throw PackageModelError.invalidCheckpoint
            }
            let localName = try read(input, Int(local.u16(26)))
            guard localName == rest.prefix(nameCount) else { throw PackageModelError.invalidCheckpoint }
            let localHeaderBytes = UInt64(30 + Int(local.u16(26)) + Int(local.u16(28)))
            guard localHeaderBytes <= directory.offset - offset,
                  compressed <= directory.offset - offset - localHeaderBytes else { throw PackageModelError.invalidCheckpoint }
            found[path] = Entry(path: path, offset: offset, localBytes: localHeaderBytes + compressed,
                compressedBytes: compressed, bytes: bytes, checksum: record.checksum, central: central)
        }
        guard found.count == records.count else { throw PackageModelError.invalidCheckpoint }
        // Caller order is stable (original, paired, preview, final manifest).
        return try records.map { guard let value = found[$0.path] else { throw PackageModelError.invalidCheckpoint }; return value }
    }

    private static func relocated(_ entry: Entry, offset: UInt64) throws -> Data {
        var header = Data(entry.central.prefix(46))
        let nameCount = Int(header.u16(28)), extraCount = Int(header.u16(30))
        let name = Data(entry.central[46..<(46 + nameCount)])
        let oldExtra = Data(entry.central[(46 + nameCount)..<(46 + nameCount + extraCount)])
        let comment = Data(entry.central.dropFirst(46 + nameCount + extraCount))
        var extra = Data(), p = 0
        while p < oldExtra.count {
            guard p + 4 <= oldExtra.count else { throw PackageModelError.invalidCheckpoint }
            let length = Int(oldExtra.u16(p + 2))
            guard p + 4 + length <= oldExtra.count else { throw PackageModelError.invalidCheckpoint }
            if oldExtra.u16(p) != 1 { extra.append(oldExtra[p..<(p+4+length)]) }
            p += 4 + length
        }
        var extended = Data()
        for value in [entry.bytes, entry.compressedBytes, offset] where value >= UInt64(UInt32.max) { extended.put64(value) }
        if !extended.isEmpty {
            extra.put16(1); extra.put16(UInt16(extended.count)); extra.append(extended)
            header.set16(6, max(header.u16(6), 45))
        }
        guard extra.count <= Int(UInt16.max) else { throw PackageModelError.invalidCheckpoint }
        header.set16(30, UInt16(extra.count)); header.set16(34, 0)
        header.set32(20, UInt32(min(entry.compressedBytes, UInt64(UInt32.max))))
        header.set32(24, UInt32(min(entry.bytes, UInt64(UInt32.max))))
        header.set32(42, UInt32(min(offset, UInt64(UInt32.max))))
        return header + name + extra + comment
    }

    private static func finish(_ output: FileHandle, count: UInt64, offset: UInt64, bytes: UInt64) throws {
        let zip64Offset = try output.offset()
        var tail = Data()
        tail.put32(0x06064b50); tail.put64(44); tail.put16(45); tail.put16(45)
        tail.put32(0); tail.put32(0); tail.put64(count); tail.put64(count); tail.put64(bytes); tail.put64(offset)
        tail.put32(0x07064b50); tail.put32(0); tail.put64(zip64Offset); tail.put32(1)
        tail.put32(0x06054b50); tail.put16(0); tail.put16(0); tail.put16(UInt16.max); tail.put16(UInt16.max)
        tail.put32(UInt32.max); tail.put32(UInt32.max); tail.put16(0)
        try output.write(contentsOf: tail); try output.truncate(atOffset: output.offset()); try output.synchronize()
    }

    private static func read(_ input: FileHandle, _ count: Int) throws -> Data {
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else { throw PackageModelError.invalidCheckpoint }; return data
    }
    private static func copy(_ input: FileHandle, _ output: FileHandle, count: UInt64,
                             progress: (UInt64) throws -> Void = { _ in }) throws {
        var remaining = count
        while remaining > 0 {
            try autoreleasepool {
                try Task.checkCancellation()
                let data = try read(input, Int(min(remaining, 1024 * 1024)))
                try output.write(contentsOf: data); remaining -= UInt64(data.count); try progress(UInt64(data.count))
            }
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset+1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset+2)) << 16 }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset+4)) << 32 }
    mutating func put16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(truncatingIfNeeded: value)); put16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func put64(_ value: UInt64) { put32(UInt32(truncatingIfNeeded: value)); put32(UInt32(truncatingIfNeeded: value >> 32)) }
    mutating func set16(_ offset: Int, _ value: UInt16) { self[offset] = UInt8(truncatingIfNeeded: value); self[offset+1] = UInt8(truncatingIfNeeded: value >> 8) }
    mutating func set32(_ offset: Int, _ value: UInt32) { set16(offset, UInt16(truncatingIfNeeded: value)); set16(offset+2, UInt16(truncatingIfNeeded: value >> 16)) }
}
