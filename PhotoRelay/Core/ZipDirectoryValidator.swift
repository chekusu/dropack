import Foundation

public enum ZipValidationError: Error, Sendable {
    case invalid(String)
    case encrypted
    case multipart
}

public struct ZipDirectory: Sendable {
    public var entryCount: UInt64
    public var offset: UInt64
    public var byteCount: UInt64
    public var boundary: UInt64
}

/// A bounded-memory check of ZIP and ZIP64 directory metadata before ZIPFoundation enumeration.
public enum ZipDirectoryValidator {
    /// ZIPFoundation 0.9.20 silently ends iteration at an encrypted or malformed entry.
    /// Inspect only fixed-size headers and small extra fields so those cases cannot look like success.
    /// ZIP64 offsets and sizes stay UInt64 throughout; no complete-archive Data allocation occurs.
    public static func validate(url: URL, byteCount: UInt64) throws -> ZipDirectory {
        guard byteCount >= 22, byteCount <= UInt64(Int64.max) else {
            throw ZipValidationError.invalid("文件长度不正确。")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ZipValidationError.invalid("（\(error.localizedDescription)）") }
        defer { try? handle.close() }
        do {
            let tailLength = Int(min(byteCount, UInt64(22 + Int(UInt16.max))))
            let tailOffset = byteCount - UInt64(tailLength)
            let tail = try readExactly(handle, offset: tailOffset, count: tailLength)
            var endIndex: Int?
            for index in stride(from: tail.count - 22, through: 0, by: -1) {
                if tail.le32(index) == 0x06054b50,
                   index + 22 + Int(tail.le16(index + 20)) == tail.count {
                    endIndex = index
                    break
                }
            }
            guard let endIndex else { throw ZipValidationError.invalid("缺少 ZIP 目录结尾。") }
            let endOffset = tailOffset + UInt64(endIndex)
            let disk = tail.le16(endIndex + 4)
            let directoryDisk = tail.le16(endIndex + 6)
            let diskEntries = tail.le16(endIndex + 8)
            let entries = tail.le16(endIndex + 10)
            let size = tail.le32(endIndex + 12)
            let offset = tail.le32(endIndex + 16)
            guard disk == 0, directoryDisk == 0 else { throw ZipValidationError.multipart }
            var directory = ZipDirectory(entryCount: UInt64(entries), offset: UInt64(offset),
                                         byteCount: UInt64(size), boundary: endOffset)
            let isZIP64 = entries == UInt16.max || diskEntries == UInt16.max
                || size == UInt32.max || offset == UInt32.max
            if isZIP64 {
                guard endOffset >= 20 else { throw ZipValidationError.invalid("缺少 ZIP64 定位信息。") }
                let locator = try readExactly(handle, offset: endOffset - 20, count: 20)
                guard locator.le32(0) == 0x07064b50 else {
                    throw ZipValidationError.invalid("缺少 ZIP64 定位信息。")
                }
                guard locator.le32(4) == 0, locator.le32(16) == 1 else {
                    throw ZipValidationError.multipart
                }
                let zip64Offset = locator.le64(8)
                guard zip64Offset <= endOffset - 20,
                      endOffset - 20 - zip64Offset >= 56 else {
                    throw ZipValidationError.invalid("ZIP64 目录位置不正确。")
                }
                let record = try readExactly(handle, offset: zip64Offset, count: 56)
                guard record.le32(0) == 0x06064b50, record.le64(4) >= 44,
                      record.le64(4) <= endOffset - 20 - zip64Offset - 12 else {
                    throw ZipValidationError.invalid("ZIP64 目录记录不完整。")
                }
                guard record.le32(16) == 0, record.le32(20) == 0,
                      record.le64(24) == record.le64(32) else {
                    throw ZipValidationError.multipart
                }
                directory = ZipDirectory(entryCount: record.le64(32), offset: record.le64(48),
                                         byteCount: record.le64(40), boundary: zip64Offset)
            } else if diskEntries != entries { throw ZipValidationError.multipart }
            guard directory.offset <= directory.boundary,
                  directory.byteCount <= directory.boundary - directory.offset,
                  directory.entryCount <= directory.byteCount / 46 else {
                throw ZipValidationError.invalid("ZIP 目录范围不正确。")
            }
            let centralEnd = directory.offset + directory.byteCount
            var position = directory.offset
            var scanned: UInt64 = 0
            while scanned < directory.entryCount {
                try Task.checkCancellation()
                guard position <= centralEnd, centralEnd - position >= 46 else {
                    throw ZipValidationError.invalid("ZIP 目录记录不完整。")
                }
                let header = try readExactly(handle, offset: position, count: 46)
                guard header.le32(0) == 0x02014b50 else {
                    throw ZipValidationError.invalid("ZIP 目录记录不正确。")
                }
                let flags = header.le16(8)
                if flags & 0x0001 != 0 || flags & 0x0040 != 0 { throw ZipValidationError.encrypted }
                let nameLength = UInt64(header.le16(28))
                let extraLength = UInt64(header.le16(30))
                let commentLength = UInt64(header.le16(32))
                let length = 46 + nameLength + extraLength + commentLength
                guard length <= centralEnd - position else {
                    throw ZipValidationError.invalid("ZIP 文件名或扩展记录不完整。")
                }
                let startDisk = header.le16(34)
                if startDisk == UInt16.max {
                    let extra = try readExactly(handle, offset: position + 46 + nameLength,
                                                count: Int(extraLength))
                    let diskNumber = try zip64StartDisk(extra: extra, header: header)
                    guard diskNumber == 0 else { throw ZipValidationError.multipart }
                } else if startDisk != 0 { throw ZipValidationError.multipart }
                position += length
                scanned += 1
            }
            return directory
        } catch is CancellationError { throw CancellationError() }
        catch let error as ZipValidationError { throw error }
        catch { throw ZipValidationError.invalid("（\(error.localizedDescription)）") }
    }

    private static func zip64StartDisk(extra: Data, header: Data) throws -> UInt32 {
        var position = 0
        while position + 4 <= extra.count {
            let kind = extra.le16(position)
            let length = Int(extra.le16(position + 2))
            guard length <= extra.count - position - 4 else { break }
            if kind == 0x0001 {
                var diskOffset = position + 4
                if header.le32(24) == UInt32.max { diskOffset += 8 }
                if header.le32(20) == UInt32.max { diskOffset += 8 }
                if header.le32(42) == UInt32.max { diskOffset += 8 }
                guard diskOffset + 4 <= position + 4 + length else { break }
                return extra.le32(diskOffset)
            }
            position += 4 + length
        }
        throw ZipValidationError.invalid("ZIP64 磁盘信息不完整。")
    }

    private static func readExactly(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        try handle.seek(toOffset: offset)
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: count - data.count) }), !chunk.isEmpty else {
                throw ZipValidationError.invalid("ZIP 记录被截断。")
            }
            data.append(chunk)
        }
        return data
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | (UInt32(le16(offset + 2)) << 16)
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | (UInt64(le32(offset + 4)) << 32)
    }
}
