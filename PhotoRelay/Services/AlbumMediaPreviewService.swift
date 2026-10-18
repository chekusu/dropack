import CryptoKit
import Foundation
import Photos
import ZIPFoundation

struct AlbumMediaPreviewRequest: Identifiable {
    enum Source { case sent(PackageJob, PackageAsset), received(ImportJob, ImportItem) }
    let id = UUID()
    let title: String
    let source: Source
}

enum AlbumMediaPreviewError: LocalizedError {
    case unavailable, changed, unsupported, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取原件，请重新连接来源或在系统相册中确认照片仍可访问。"
        case .changed: return "原文件已变化，无法预览。请重新打开来源。"
        case .unsupported: return "系统暂不支持预览这个格式。原文件未被修改。"
        case .busy: return "这个照片包仍在打包，请完成或暂停后再预览。"
        }
    }
}

/// Owns only a preview's scope and optional UUID staging directory. It never
/// owns a user source, import cache, package or Photos asset.
final class AlbumMediaPreviewLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var scope: URL?
    private var directory: URL?
    init(url: URL, scope: URL? = nil, directory: URL? = nil) {
        self.url = url; self.scope = scope; self.directory = directory
    }
    func close() {
        lock.lock()
        let releasedScope = scope, removedDirectory = directory
        scope = nil; directory = nil
        lock.unlock()
        releasedScope?.stopAccessingSecurityScopedResource()
        if let removedDirectory { try? FileManager.default.removeItem(at: removedDirectory) }
    }
    deinit { close() }
}

/// Full media is opened only after a user taps a tile. ZIP and PhotoKit exports
/// use bounded streaming and a separate temporary directory, never image Data or
/// the importer's resumable staging. No API here writes to Photos.
actor AlbumMediaPreviewService {
    private let temporaryRoot: URL
    private let availableCapacity: @Sendable (URL) throws -> Int64?
    private let spaceCheckInterval: UInt64
    init(temporaryRoot: URL? = nil,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64? = {
             try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
         }, spaceCheckInterval: UInt64 = 64 * 1024 * 1024) {
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("DropackMediaPreview", isDirectory: true)
        self.availableCapacity = availableCapacity
        self.spaceCheckInterval = max(1, spaceCheckInterval)
    }

    func file(_ source: PackageFileSource) async throws -> AlbumMediaPreviewLease {
        try Task.checkCancellation()
        let location = try PackageFileAccess.resolve(source)
        let scoped = location.root.startAccessingSecurityScopedResource()
        do {
            try await AlbumPreviewFileCoordinator().read(location.file) { local in
                try PackageFileAccess.validate(local, source: source)
                try Task.checkCancellation()
            }
            return AlbumMediaPreviewLease(url: location.file, scope: scoped ? location.root : nil)
        } catch {
            if scoped { location.root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func sentArchive(_ archive: URL, asset: PackageAsset,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> AlbumMediaPreviewLease {
        guard let item = asset.manifestItem,
              let path = AlbumMediaPreviewPolicy.primaryPath(photo: item.photoPath, video: item.videoPath),
              let record = asset.archiveRecords.first(where: { $0.path == path }) else {
            throw AlbumMediaPreviewError.unavailable
        }
        return try await extract(archive: archive, path: path, expectedBytes: record.byteCount,
            expectedCRC: record.checksum, expectedSHA: item.photoPath == path ? item.photoSHA256 : item.videoSHA256,
            expectedIndex: nil, fingerprint: nil, progress: progress)
    }

    func received(_ job: ImportJob, item: ImportItem,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> AlbumMediaPreviewLease {
        try Task.checkCancellation()
        var stale = false
        let source = try URL(resolvingBookmarkData: job.source.bookmark, options: .withoutUI,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AlbumMediaPreviewError.unavailable }
        let scoped = source.startAccessingSecurityScopedResource()
        do {
            if job.source.kind == .zip {
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                return try await extract(archive: source, path: item.relativePath, expectedBytes: item.byteCount,
                    expectedCRC: item.checksum, expectedSHA: item.expectedSHA256,
                    expectedIndex: item.archiveIndex, fingerprint: job.source.fingerprint, progress: progress)
            }
            let file = try AlbumMediaPreviewPolicy.sourceFile(root: source, relativePath: item.relativePath,
                isFolder: job.source.kind == .folder)
            try await AlbumPreviewFileCoordinator().read(file) { local in
                let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      UInt64(max(0, values.fileSize ?? 0)) == item.byteCount,
                      item.modifiedAt == nil || values.contentModificationDate == item.modifiedAt else {
                    throw AlbumMediaPreviewError.changed
                }
                try Task.checkCancellation()
            }
            return AlbumMediaPreviewLease(url: file, scope: scoped ? source : nil)
        } catch {
            // The ZIP branch's defer already releases its scope.
            if scoped && job.source.kind != .zip { source.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func photo(identifier: String, kind: MediaKind?,
               progress: @escaping @Sendable (Double) -> Void) async throws -> AlbumMediaPreviewLease {
        try Task.checkCancellation()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw AlbumMediaPreviewError.unavailable
        }
        let type: PHAssetResourceType = kind == .video || asset.mediaType == .video ? .video : .photo
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == type }),
              MediaPolicy.kind(for: resource.originalFilename) != nil else { throw AlbumMediaPreviewError.unsupported }
        let directory = try makeDirectory()
        let output = directory.appendingPathComponent("original").appendingPathExtension((resource.originalFilename as NSString).pathExtension)
        do {
            let stream = try PhotoResourceStream(destination: output, safetyMargin: 64 * 1024 * 1024)
            _ = try await stream.export(resource: resource, isNetworkAccessAllowed: true, progress: progress)
            try Task.checkCancellation()
            return AlbumMediaPreviewLease(url: output, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func extract(archive source: URL, path: String, expectedBytes: UInt64,
                         expectedCRC: UInt32?, expectedSHA: String?, expectedIndex: Int?,
                         fingerprint: SourceFingerprint?,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> AlbumMediaPreviewLease {
        guard AlbumMediaPreviewPolicy.isOriginalPath(path), expectedBytes > 0 else { throw AlbumMediaPreviewError.unavailable }
        try Task.checkCancellation()
        let directory = try makeDirectory()
        let outputURL = directory.appendingPathComponent("original").appendingPathExtension((path as NSString).pathExtension)
        do {
            try checkSpace(remainingBytes: expectedBytes, at: directory)
            let coordinator = AlbumPreviewFileCoordinator()
            try await coordinator.read(source) { local in
                let before = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard before.isRegularFile == true, before.isSymbolicLink != true else { throw AlbumMediaPreviewError.unavailable }
                if let fingerprint {
                    guard UInt64(max(0, before.fileSize ?? 0)) == fingerprint.byteCount,
                          fingerprint.modifiedAt == nil || fingerprint.modifiedAt == before.contentModificationDate else { throw AlbumMediaPreviewError.changed }
                }
                let archive = try Archive(url: local, accessMode: .read)
                let entry: Entry?
                if let expectedIndex {
                    entry = archive.enumerated().first(where: { $0.offset == expectedIndex })?.element
                } else { entry = archive[path] }
                guard let entry, entry.type == .file, entry.path == path, entry.uncompressedSize == expectedBytes,
                      expectedCRC == nil || entry.checksum == expectedCRC else { throw AlbumMediaPreviewError.changed }
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw AlbumMediaPreviewError.unavailable }
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                var count: UInt64 = 0, checkedAt: UInt64 = 0
                var digest = SHA256()
                var lastReport = -Double.infinity
                let crc = try archive.extract(entry, bufferSize: 1024 * 1024, skipCRC32: false) { bytes in
                    try autoreleasepool {
                        try coordinator.checkCancellation()
                        if count - checkedAt >= spaceCheckInterval {
                            try checkSpace(remainingBytes: expectedBytes - count, at: directory)
                            checkedAt = count
                        }
                        let next = count.addingReportingOverflow(UInt64(bytes.count))
                        guard !next.overflow, next.partialValue <= expectedBytes else { throw AlbumMediaPreviewError.changed }
                        try output.write(contentsOf: bytes)
                        count = next.partialValue
                        if expectedSHA != nil { digest.update(data: bytes) }
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastReport >= 0.1 { lastReport = now; progress(Double(count) / Double(expectedBytes)) }
                    }
                }
                guard count == expectedBytes, crc == entry.checksum,
                      expectedSHA == nil || digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedSHA?.lowercased() else {
                    throw AlbumMediaPreviewError.changed
                }
                let after = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else {
                    throw AlbumMediaPreviewError.changed
                }
                try Task.checkCancellation()
                try output.synchronize()
                progress(1)
            }
            try Task.checkCancellation()
            return AlbumMediaPreviewLease(url: outputURL, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func checkSpace(remainingBytes: UInt64, at directory: URL) throws {
        let required = AlbumMediaPreviewPolicy.requiredSpace(for: remainingBytes)
        if let capacity = try availableCapacity(directory), capacity >= 0, UInt64(capacity) < required {
            throw MediaSourceError.insufficientSpace(required: required, available: UInt64(capacity))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Pure read policy used by the UI, direct-file resolver, and ZIP extractor.
enum AlbumMediaPreviewPolicy {
    static func requiredSpace(for byteCount: UInt64) -> UInt64 {
        let sum = byteCount.addingReportingOverflow(64 * 1024 * 1024)
        return sum.overflow ? .max : sum.partialValue
    }
    static func primaryPath(photo: String?, video: String?) -> String? {
        if let photo, isOriginalPath(photo) { return photo }
        if let video, isOriginalPath(video) { return video }
        return nil
    }
    static func isOriginalPath(_ path: String) -> Bool {
        MediaPolicy.isSafeRelativePath(path) && !MediaPolicy.shouldIgnore(path)
            && !path.hasPrefix("__dropack_previews/") && MediaPolicy.kind(for: path) != nil
    }
    static func sourceFile(root: URL, relativePath: String, isFolder: Bool) throws -> URL {
        guard isOriginalPath(relativePath) else { throw AlbumMediaPreviewError.unavailable }
        if !isFolder { return root }
        let file = root.appendingPathComponent(relativePath)
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(normalizedRoot + "/") else {
            throw AlbumMediaPreviewError.changed
        }
        return file
    }
}
