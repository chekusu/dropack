import Foundation

/// A Dropack document contains standard ZIP bytes, but has its own system routing type.
public enum PackageFileFormat: String, Sendable {
    case dropack, zip

    public static let typeIdentifier = "app.dropack.photo-package"
    public var fileExtension: String { rawValue }
    public var contentTypeIdentifier: String {
        self == .dropack ? Self.typeIdentifier : "public.zip-archive"
    }
    public static func isArchive(_ url: URL) -> Bool {
        Self(rawValue: url.pathExtension.lowercased()) != nil
    }

    /// Finalized archives are immutable. A hard link exposes the alternate suffix
    /// without duplicating a potentially enormous archive or changing its checkpoint.
    public func shareURL(for archive: URL, title: String? = nil) throws -> URL {
        guard Self.isArchive(archive), try PackageRecovery.fileSize(archive) >= 22 else {
            throw PackageModelError.invalidCheckpoint
        }
        let target = title.map { archive.deletingLastPathComponent().appendingPathComponent(
            ShareAlbumNaming.safeFilename(title: $0, extension: fileExtension))
        } ?? archive.deletingPathExtension().appendingPathExtension(fileExtension)
        guard target != archive else { return archive }
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            let original = try manager.attributesOfItem(atPath: archive.path)
            let existing = try manager.attributesOfItem(atPath: target.path)
            guard existing[.type] as? FileAttributeType == .typeRegular,
                  let inode = original[.systemFileNumber] as? NSNumber,
                  let device = original[.systemNumber] as? NSNumber,
                  existing[.systemFileNumber] as? NSNumber == inode,
                  existing[.systemNumber] as? NSNumber == device else {
                throw PackageModelError.invalidCheckpoint
            }
        } else {
            try manager.linkItem(at: archive, to: target)
        }
        return target
    }
}

/// Shared writer/reader format bounds. Count limits cover the manifest ZIP entry too.
public enum PackageFormatLimits {
    public static let maxSelectedAssets = 124_999
    public static let maxZIPEntries = 250_000
    public static let maxManifestBytes: UInt64 = 32 * 1024 * 1024

    public static func validateSelectionCount(_ count: Int) throws {
        guard count >= 1, count <= maxSelectedAssets else { throw PackageLimitError.selectionTooLarge }
    }

    public static func validateFinalization(resourceCount: Int, manifestByteCount: UInt64) throws {
        guard resourceCount >= 1, resourceCount < maxZIPEntries,
              manifestByteCount <= maxManifestBytes else { throw PackageLimitError.archiveTooLarge }
    }
}

public enum PackageLimitError: Error, LocalizedError, Sendable {
    case selectionTooLarge, archiveTooLarge
    public var errorDescription: String? {
        switch self {
        case .selectionTooLarge:
            return "一次最多选择 124,999 项照片或视频。请分成几个照片包发送。"
        case .archiveTooLarge:
            return "这个照片包的文件数量或清单超过首版上限，暂不能生成可发送的包。请清除本次任务，分成几个较小的照片包；原相册不会受影响。"
        }
    }
}

/// Public, portable metadata. PhotoKit identifiers never leave the sending phone.
public struct PhotoPackageManifest: Codable, Equatable, Sendable {
    public static let filename = "dropack-manifest.json"
    public var version: Int
    public var items: [PhotoPackageManifestItem]
    /// Stable album identity and immutable export revision, absent in legacy v1 documents.
    public var album: ShareAlbumMetadata?

    public init(version: Int = 1, items: [PhotoPackageManifestItem], album: ShareAlbumMetadata? = nil) {
        self.version = version; self.items = items; self.album = album
    }

    public func validate() throws {
        guard version == 1, !items.isEmpty else { throw PackageModelError.invalidManifest }
        try album?.validate()
        var ids = Set<String>()
        var paths = Set<String>()
        for item in items {
            guard UUID(uuidString: item.id) != nil, ids.insert(item.id).inserted,
                  item.photoPath != nil || item.videoPath != nil,
                  item.isLivePhoto == (item.photoPath != nil && item.videoPath != nil) else {
                throw PackageModelError.invalidManifest
            }
            if let preview = item.previewPath {
                guard preview == "__dropack_previews/\(item.id).preview", paths.insert(preview).inserted else {
                    throw PackageModelError.invalidManifest
                }
            }
            for (path, kind, hash) in [(item.photoPath, MediaKind.photo, item.photoSHA256),
                                        (item.videoPath, MediaKind.video, item.videoSHA256)] {
                if let path {
                    guard MediaPolicy.isSafeRelativePath(path), !MediaPolicy.shouldIgnore(path),
                          MediaPolicy.kind(for: path) == kind, paths.insert(path).inserted else {
                        throw PackageModelError.invalidManifest
                    }
                    if let hash {
                        guard hash.count == 64,
                              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                            throw PackageModelError.invalidManifest
                        }
                    }
                } else if hash != nil { throw PackageModelError.invalidManifest }
            }
        }
    }
}

public struct PhotoPackageManifestItem: Codable, Equatable, Sendable {
    public var id: String
    public var photoPath: String?
    public var videoPath: String?
    public var creationDate: Date?
    public var isLivePhoto: Bool
    public var photoSHA256: String?
    public var videoSHA256: String?
    public var previewPath: String?

    public init(id: String, photoPath: String? = nil, videoPath: String? = nil,
                creationDate: Date? = nil, isLivePhoto: Bool = false,
                photoSHA256: String? = nil, videoSHA256: String? = nil, previewPath: String? = nil) {
        self.id = id; self.photoPath = photoPath; self.videoPath = videoPath
        self.creationDate = creationDate; self.isLivePhoto = isLivePhoto
        self.photoSHA256 = photoSHA256; self.videoSHA256 = videoSHA256; self.previewPath = previewPath
    }
}

public enum PackagePhase: String, Codable, Sendable {
    case draft = "未开始打包", preparing = "准备打包", packing = "正在打包", paused = "已暂停"
    case ready = "可以发送", failed = "需要处理"
}

public struct PackageArchiveRecord: Codable, Equatable, Sendable {
    public var path: String
    public var byteCount: UInt64
    public var checksum: UInt32
    public init(path: String, byteCount: UInt64, checksum: UInt32) {
        self.path = path; self.byteCount = byteCount; self.checksum = checksum
    }
}

/// Security-scoped source is local-only. Never put bookmarks or device paths in a manifest.
public struct PackageFileSource: Codable, Equatable, Sendable {
    public var bookmark: Data
    public var relativePath: String
    public var isFolder: Bool
    public var byteCount: UInt64
    public var modifiedAt: Date?
    public init(bookmark: Data, relativePath: String, isFolder: Bool,
                byteCount: UInt64, modifiedAt: Date?) {
        self.bookmark = bookmark; self.relativePath = relativePath; self.isFolder = isFolder
        self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
}

public struct PackageAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var assetIdentifier: String
    public var manifestItem: PhotoPackageManifestItem?
    public var archiveRecords: [PackageArchiveRecord]
    /// Local display metadata only; never included in the portable manifest.
    public var title: String?
    public var kind: MediaKind?
    public var captureDate: Date?
    public var sourceModifiedAt: Date?
    public var fileSource: PackageFileSource?
    public var pairedFileSource: PackageFileSource?
    /// Private picker grants are ephemeral. Captured resources survive relaunch.
    public var pickerResourcePending: Bool?
    /// Local-only identities used to rebind a private picker grant after relaunch.
    public var pickerAssetIdentifier: String?
    public var pickerSelectionItemID: UUID?
    /// Local immutable checkpoint containing this unchanged asset; never exported.
    public var reuseSourcePackageID: UUID?
    public init(assetIdentifier: String) {
        id = UUID().uuidString; self.assetIdentifier = assetIdentifier
        manifestItem = nil; archiveRecords = []
    }
    public var isCompleted: Bool { manifestItem != nil }
}

/// A lightweight library row backed by this package's durable journal. Thumbnail
/// pixels stay on disk and are loaded only for visible items in the detail grid.
public struct PackageLibraryEntry: Identifiable, Sendable {
    public let job: PackageJob
    public let issue: String?
    public init(job: PackageJob) { self.job = job; issue = nil }
    /// Display-only metadata for a damaged journal. Zero known assets is
    /// intentional; this value is never saved or accepted by the archive service.
    public init(unavailableID: UUID, createdAt: Date, issue: String) {
        var placeholder = PackageJob(assetIdentifiers: [])
        placeholder.id = unavailableID; placeholder.createdAt = createdAt
        placeholder.phase = .failed; placeholder.lastMessage = issue
        job = placeholder; self.issue = issue
    }
    public var id: UUID { job.id }
    public var createdAt: Date { job.createdAt }
    public var displayTitle: String { job.displayTitle }
    public var stableAlbumID: UUID { job.stableAlbumID }
    public var revision: Int { job.album?.revision ?? 1 }
    public var completedCount: Int { job.completedCount }
    public var totalCount: Int { job.totalCount }
    public var bytes: UInt64 { job.finalizedSize ?? job.completedBytes }
    public var phase: PackagePhase { job.phase }
    public var assets: [PackageAsset] { job.assets }
    public var photoCount: Int { assets.filter { $0.kind == .photo || $0.manifestItem?.photoPath != nil }.count }
    public var videoCount: Int { assets.filter { $0.kind == .video || ($0.manifestItem?.photoPath == nil && $0.manifestItem?.videoPath != nil) }.count }
}

/// Saved before any append overwrites a ZIP's previous central directory.
public struct PackageArchiveTransaction: Codable, Equatable, Sendable {
    public var originalSize: UInt64
    public var directoryOffset: UInt64
    public var backupFilename: String
    public init(originalSize: UInt64, directoryOffset: UInt64, backupFilename: String) {
        self.originalSize = originalSize; self.directoryOffset = directoryOffset
        self.backupFilename = backupFilename
    }
    public func validate() throws {
        guard originalSize >= 22, originalSize <= UInt64(Int64.max),
              directoryOffset <= originalSize - 22,
              backupFilename == "directory-backup.bin" else { throw PackageModelError.invalidCheckpoint }
    }
}

public struct PackageJob: Codable, Identifiable, Sendable {
    public var version: Int = 1
    public var id: UUID
    public var createdAt: Date
    public var assets: [PackageAsset]
    public var phase: PackagePhase
    public var archiveFilename: String
    public var transaction: PackageArchiveTransaction?
    public var manifestRecord: PackageArchiveRecord?
    public var finalizedSize: UInt64?
    public var lastMessage: String?
    public var album: ShareAlbumMetadata?
    public var linkedPhotosAlbumIdentifier: String?
    public var titleWasEdited: Bool?
    public var addedAssetCount: Int?
    public var removedAssetCount: Int?
    /// nil is a legacy active task. false means metadata/capture only until Share.
    public var packagingRequested: Bool?
    public var reuseStrategy: String?

    public init(assetIdentifiers: [String], senderName: String? = nil) {
        id = UUID(); createdAt = Date()
        assets = assetIdentifiers.map { PackageAsset(assetIdentifier: $0) }
        phase = .preparing
        album = ShareAlbumMetadata(id: id, snapshotID: id, title: ShareAlbumNaming.title(dates: [], fallback: createdAt),
                                   createdAt: createdAt, senderName: senderName)
        archiveFilename = ShareAlbumNaming.safeFilename(title: album!.title, extension: "dropack")
    }
    public var stableAlbumID: UUID { album?.id ?? id }
    public var displayTitle: String {
        album?.title ?? ShareAlbumNaming.title(dates: assets.compactMap { $0.captureDate ?? $0.manifestItem?.creationDate }, fallback: createdAt)
    }
    public var isDraft: Bool { phase == .draft }
    public var isFileAlbum: Bool { assets.contains { $0.fileSource != nil || $0.pickerResourcePending == true } }
    public var totalCount: Int { assets.count }
    public var completedCount: Int { assets.filter(\.isCompleted).count }
    public var completedBytes: UInt64 {
        assets.flatMap(\.archiveRecords).reduce(0) { result, record in
            let sum = result.addingReportingOverflow(record.byteCount)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }
    public var totalBytes: UInt64? { completedCount == totalCount ? completedBytes : nil }
    public var progress: Double { assets.isEmpty ? 0 : Double(completedCount) / Double(totalCount) }
    public var selectedAssetIdentifiers: [String] { assets.map(\.assetIdentifier) }

    public mutating func recoverAfterInterruption() {
        if phase == .preparing || phase == .packing { phase = .paused }
        // Preserve the transaction marker. Only a successful on-disk rollback may clear it.
    }

    public func validate() throws {
        guard version == 1, (!assets.isEmpty || phase == .draft),
              MediaPolicy.isSafeRelativePath(archiveFilename), !archiveFilename.contains("/"),
              !archiveFilename.contains("\\"), PackageFileFormat.isArchive(URL(fileURLWithPath: archiveFilename)),
              Set(assets.map(\.id)).count == assets.count,
              Set(assets.map(\.assetIdentifier)).count == assets.count,
              assets.allSatisfy({ !$0.assetIdentifier.isEmpty && UUID(uuidString: $0.id) != nil }) else {
            throw PackageModelError.invalidCheckpoint
        }
        try transaction?.validate()
        try album?.validate()
        for asset in assets {
            for source in [asset.fileSource, asset.pairedFileSource].compactMap({ $0 }) {
                guard !source.bookmark.isEmpty, source.byteCount > 0,
                      MediaPolicy.isSafeRelativePath(source.relativePath),
                      MediaPolicy.kind(for: source.relativePath) != nil else {
                    throw PackageModelError.invalidCheckpoint
                }
            }
        }
        let complete = assets.compactMap(\.manifestItem)
        if !complete.isEmpty { try PhotoPackageManifest(items: complete).validate() }
        var seen = Set<String>()
        for asset in assets {
            if let item = asset.manifestItem {
                let expected = Set([item.photoPath, item.videoPath, item.previewPath].compactMap { $0 })
                guard item.id == asset.id, asset.archiveRecords.count == expected.count,
                      Set(asset.archiveRecords.map(\.path)) == expected else {
                    throw PackageModelError.invalidCheckpoint
                }
                for record in asset.archiveRecords {
                    guard seen.insert(record.path).inserted else { throw PackageModelError.invalidCheckpoint }
                }
            } else if !asset.archiveRecords.isEmpty { throw PackageModelError.invalidCheckpoint }
        }
        if let manifestRecord {
            guard manifestRecord.path == PhotoPackageManifest.filename,
                  completedCount == totalCount, phase == .ready,
                  transaction == nil, finalizedSize != nil else { throw PackageModelError.invalidCheckpoint }
        }
        if phase == .ready {
            guard completedCount == totalCount, manifestRecord != nil,
                  transaction == nil, let finalizedSize, finalizedSize >= 22 else {
                throw PackageModelError.invalidCheckpoint
            }
        }
    }
}

public enum PackageModelError: Error, LocalizedError, Sendable {
    case invalidManifest, invalidCheckpoint, missingRollback
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "照片包的清单格式不完整或不受支持。"
        case .invalidCheckpoint: return "打包进度记录损坏或版本不受支持，请清除任务后重新选择照片。"
        case .missingRollback: return "无法安全恢复上次打包，请清除任务并重新打包；原相册不会受影响。"
        }
    }
}

/// Atomic JSON checkpoints plus bounded-memory rollback of one incomplete ZIP append.
public enum PackageRecovery {
    public static func save(_ job: PackageJob, to url: URL) throws {
        try job.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public static func load(from url: URL) throws -> PackageJob? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var job = try JSONDecoder().decode(PackageJob.self, from: Data(contentsOf: url))
        try job.validate()
        job.recoverAfterInterruption()
        return job
    }

    public static func snapshot(archive: URL, backup: URL) throws -> PackageArchiveTransaction {
        let size = try fileSize(archive)
        let directory = try ZipDirectoryValidator.validate(url: archive, byteCount: size)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let temporary = backup.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw PackageModelError.missingRollback
        }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try input.seek(toOffset: directory.offset)
            try copy(input: input, output: output, count: size - directory.offset)
            try output.synchronize(); try output.close()
        } catch { try? output.close(); throw error }
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: temporary, to: backup)
        return PackageArchiveTransaction(originalSize: size, directoryOffset: directory.offset,
                                         backupFilename: backup.lastPathComponent)
    }

    /// Idempotent: keep the backup until the cleared transaction is durably checkpointed.
    public static func rollback(_ transaction: PackageArchiveTransaction, archive: URL, backup: URL) throws {
        try transaction.validate()
        guard backup.lastPathComponent == transaction.backupFilename,
              try fileSize(backup) == transaction.originalSize - transaction.directoryOffset,
              try fileSize(archive) >= transaction.directoryOffset else { throw PackageModelError.missingRollback }
        let input = try FileHandle(forReadingFrom: backup)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        try output.seek(toOffset: transaction.directoryOffset)
        // Rollback must also run from a cancelled worker; it deliberately does not inspect Task cancellation.
        try copy(input: input, output: output, count: transaction.originalSize - transaction.directoryOffset)
        try output.truncate(atOffset: transaction.originalSize)
        try output.synchronize()
    }

    public static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { throw PackageModelError.missingRollback }
        return UInt64(size)
    }

    private static func copy(input: FileHandle, output: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            try autoreleasepool {
                guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else {
                    throw PackageModelError.missingRollback
                }
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
        }
    }
}
