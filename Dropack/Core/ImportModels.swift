import Foundation

public enum SourceKind: String, Codable, Sendable { case zip, folder, mediaFile }
public enum MediaKind: String, Codable, Sendable { case photo, video }
public enum ItemState: String, Codable, Sendable {
    case pending, inFlight, saved, failed, uncertain, skipped
}
public enum JobPhase: String, Codable, Sendable { case ready, running, paused, completed }
public enum ImportPurpose: String, Codable, Sendable { case sharedAlbum, oneTimeImport }

/// A second file that belongs to the same logical Photos asset (Live Photo).
public struct ImportResource: Codable, Equatable, Sendable {
    public var relativePath: String
    public var byteCount: UInt64
    public var modifiedAt: Date?
    public var archiveIndex: Int?
    public var checksum: UInt32?
    public var sha256: String?

    public init(item: ImportItem) {
        relativePath = item.relativePath; byteCount = item.byteCount
        modifiedAt = item.modifiedAt; archiveIndex = item.archiveIndex
        checksum = item.checksum; sha256 = item.expectedSHA256
    }

    public var asItem: ImportItem {
        var item = ImportItem(id: relativePath, relativePath: relativePath, kind: .video,
                              byteCount: byteCount, modifiedAt: modifiedAt,
                              archiveIndex: archiveIndex, checksum: checksum)
        item.expectedSHA256 = sha256
        return item
    }
}

public struct SourceFingerprint: Codable, Equatable, Sendable {
    public var byteCount: UInt64
    public var modifiedAt: Date?
    public init(byteCount: UInt64, modifiedAt: Date? = nil) {
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct SourceDescriptor: Codable, Sendable {
    public var kind: SourceKind
    public var name: String
    public var bookmark: Data
    public var fingerprint: SourceFingerprint?
    /// Full source bytes, independent of its filename or bookmark.
    public var contentIdentity: String?
    public init(kind: SourceKind, name: String, bookmark: Data, fingerprint: SourceFingerprint? = nil) {
        self.kind = kind; self.name = name; self.bookmark = bookmark; self.fingerprint = fingerprint
    }
}

public struct ImportItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var relativePath: String
    public var kind: MediaKind
    public var byteCount: UInt64
    public var modifiedAt: Date?
    public var archiveIndex: Int?
    public var checksum: UInt32?
    public var state: ItemState
    public var errorMessage: String?
    public var assetIdentifier: String?
    public var pairedVideo: ImportResource?
    public var creationDate: Date?
    public var expectedSHA256: String?
    /// Verified logical resource identity, including both Live Photo resources.
    public var contentIdentity: String?
    public var alreadyImported: Bool?
    /// Saved bytes may still need adding to the associated ordinary Photos album.
    public var albumMembershipPending: Bool?
    public var previewPath: String?

    public var resourceBytes: UInt64 {
        let sum = byteCount.addingReportingOverflow(pairedVideo?.byteCount ?? 0)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    public init(id: String, relativePath: String, kind: MediaKind, byteCount: UInt64,
                modifiedAt: Date? = nil, archiveIndex: Int? = nil, checksum: UInt32? = nil,
                state: ItemState = .pending) {
        self.id = id; self.relativePath = relativePath; self.kind = kind; self.byteCount = byteCount
        self.modifiedAt = modifiedAt; self.archiveIndex = archiveIndex; self.checksum = checksum
        self.state = state
    }

    public func hasSameContent(as other: ImportItem) -> Bool {
        id == other.id && relativePath == other.relativePath && kind == other.kind
            && byteCount == other.byteCount && modifiedAt == other.modifiedAt
            && archiveIndex == other.archiveIndex && checksum == other.checksum
            && pairedVideo == other.pairedVideo && creationDate == other.creationDate
            && expectedSHA256 == other.expectedSHA256
    }
}

public struct ImportJob: Codable, Identifiable, Sendable {
    public var version: Int = 1
    public var id: UUID
    public var createdAt: Date
    public var source: SourceDescriptor
    public var items: [ImportItem]
    public var phase: JobPhase
    public var delaySeconds: Double
    public var lastMessage: String?
    public var album: ShareAlbumMetadata?
    public var systemAlbumIdentifier: String?
    public var albumLinkUnavailable: Bool?
    /// This snapshot follows a lower revision of this same album that had
    /// local saves. Unlike alreadyImported, it is not a per-session dedup flag.
    /// Older checkpoints have no evidence for an update and decode as nil.
    public var isAlbumUpdate: Bool?
    /// Explicit for new jobs; nil permits migration of earlier checkpoints.
    public var purpose: ImportPurpose?

    public var isSharedAlbum: Bool {
        if let purpose { return purpose == .sharedAlbum }
        // Earlier scanners assigned dropack: IDs only after manifest validation.
        // A .dropack suffix or synthesized album metadata alone is not evidence.
        return source.kind == .zip && (source.name as NSString).pathExtension.lowercased() == "dropack"
            && !items.isEmpty && items.allSatisfy { $0.id.hasPrefix("dropack:") }
    }
    public var isOneTimeImport: Bool { !isSharedAlbum }
    public var albumID: UUID { isSharedAlbum ? (album?.id ?? id) : id }
    public var displayTitle: String {
        if isSharedAlbum, let title = album?.title { return title }
        return source.kind == .folder ? source.name : (source.name as NSString).deletingPathExtension
    }
    public var membershipPendingCount: Int {
        isSharedAlbum ? items.filter { $0.state == .saved && $0.albumMembershipPending == true }.count : 0
    }

    public mutating func migrateImportPurpose() {
        purpose = isSharedAlbum ? .sharedAlbum : .oneTimeImport
        if isOneTimeImport {
            album = nil; systemAlbumIdentifier = nil; albumLinkUnavailable = nil
            isAlbumUpdate = false
            for index in items.indices { items[index].albumMembershipPending = false }
        }
    }

    public init(source: SourceDescriptor, items: [ImportItem], delaySeconds: Double = 0.5) {
        self.id = UUID(); self.createdAt = Date(); self.source = source; self.items = items
        self.phase = .ready; self.delaySeconds = delaySeconds
        self.isAlbumUpdate = false
    }

    public var savedCount: Int { items.filter { $0.state == .saved }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    public var uncertainCount: Int { items.filter { $0.state == .uncertain }.count }
    public var skippedCount: Int { items.filter { $0.state == .skipped }.count }
    public var pendingCount: Int { items.filter { $0.state == .pending }.count }
    public var processedCount: Int { savedCount + failedCount + skippedCount }
    public var progress: Double { items.isEmpty ? 0 : Double(processedCount) / Double(items.count) }
    public var savedBytes: UInt64 { Self.sumBytes(items.filter { $0.state == .saved }) }
    public var totalBytes: UInt64 { Self.sumBytes(items) }
    public var largestItemBytes: UInt64 { items.map(\.resourceBytes).max() ?? 0 }
    public var hasUnresolvedItems: Bool { pendingCount > 0 || uncertainCount > 0 || failedCount > 0 || (membershipPendingCount > 0 && albumLinkUnavailable != true) }

    public mutating func recoverAfterInterruption() {
        for index in items.indices where items[index].state == .inFlight {
            items[index].state = .uncertain
            items[index].errorMessage = "上次保存时应用中断，请先在相册核对此文件。"
        }
        if phase == .running { phase = .paused }
    }

    public mutating func retryFailures() {
        for index in items.indices where items[index].state == .failed {
            items[index].state = .pending; items[index].errorMessage = nil
        }
        if pendingCount > 0 { phase = .paused }
    }

    public mutating func resolveUncertain(id: String, asSaved: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.state == .uncertain }) else { return }
        items[index].state = asSaved ? .saved : .pending
        items[index].errorMessage = nil
        phase = .paused
    }

    /// Replacement sources must contain exactly the original media list, including duplicate ZIP names.
    public func matchesReplacement(_ candidates: [ImportItem]) -> Bool {
        guard items.count == candidates.count else { return false }
        let originals = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard Set(candidates.map(\.id)).count == candidates.count else { return false }
        return candidates.allSatisfy { candidate in
            originals[candidate.id]?.hasSameContent(as: candidate) == true
        }
    }

    private static func sumBytes(_ items: [ImportItem]) -> UInt64 {
        items.reduce(0) { total, item in
            let result = total.addingReportingOverflow(item.resourceBytes)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }
}
