import CryptoKit
import Foundation
import OSLog
import ZIPFoundation
import ImageIO
import AVFoundation

struct SourceScan: Sendable {
    var items: [ImportItem]
    var fingerprint: SourceFingerprint?
    var ignoredCount: Int
    var album: ShareAlbumMetadata? = nil
    var hasValidatedPackageManifest = false
    var isSharedAlbum = false
}

struct PreparedMedia: Sendable {
    var fileURL: URL
    var pairedVideoURL: URL?
    var isResumable: Bool
}

enum MediaSourceError: LocalizedError, Sendable {
    case sourceUnavailable(String)
    case sourceChanged
    case itemChanged(String)
    case invalidArchive(String)
    case encryptedArchive
    case multipartArchive
    case insufficientSpace(required: UInt64, available: UInt64)
    case corruptItem(String)
    case ioFailure(String)

    /// A missing or changed source pauses the job, rather than failing every remaining item.
    var requiresSourceRelink: Bool {
        switch self {
        case .sourceUnavailable, .sourceChanged, .itemChanged, .invalidArchive,
             .encryptedArchive, .multipartArchive: return true
        case .insufficientSpace, .corruptItem, .ioFailure: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let message):
            return "无法读取来源文件。请确认 U 盘仍已连接，或文件已下载到本机；必要时重新选择原文件。已保存的项目会保留。\(message)"
        case .sourceChanged:
            return "来源文件在扫描后发生了变化，请重新选择并核对来源。"
        case .itemChanged(let path):
            return "来源中的“\(path)”已被移动或修改，请重新选择来源。"
        case .invalidArchive(let message):
            return "无法读取这个 ZIP。它可能不完整、已损坏，或使用了不支持的压缩方式。\(message)"
        case .encryptedArchive:
            return "暂不支持加密 ZIP。请先在“文件”中解压，或让朋友重新制作不带密码的单个 ZIP。"
        case .multipartArchive:
            return "暂不支持分卷 ZIP。请先合并为单个 ZIP，或选择已经解压的文件夹。"
        case .insufficientSpace(let required, let available):
            let format = ByteCountFormatter()
            format.countStyle = .file
            let need = format.string(fromByteCount: Int64(clamping: required))
            let free = format.string(fromByteCount: Int64(clamping: available))
            return "剩余空间不足。当前文件的临时副本、相册副本和安全余量约需 \(need)，当前可用 \(free)。"
        case .corruptItem(let path):
            return "“\(path)”解压后的大小或校验值不正确，文件可能已损坏。"
        case .ioFailure(let message):
            return "无法准备临时文件：\(message)"
        }
    }
}

/// All synchronous file-provider and ZIP work runs on this actor's executor, never MainActor.
/// Only one media file is staged at a time; neither the ZIP nor a large image is loaded into RAM.
actor MediaSourceService {
    private let logger = Logger(subsystem: "app.dropack.ios", category: "SourcePreparation")
    private let chunkSize = 256 * 1024
    private var scannedZipFingerprints: [String: SourceFingerprint] = [:]
    private var indexedZipURL: URL?
    private var indexedZipFingerprint: SourceFingerprint?
    private var indexedZipEntries: [Entry] = []

    func prepareMedia(item: ImportItem, sourceURL: URL, kind: SourceKind,
                      verificationProgress: @escaping @Sendable (Double) -> Void = { _ in },
                      progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedMedia {
        let directory = try stagingDirectory()
        let retained = kind == .zip ? 0 : retainedBytes(for: item, in: directory)
        try checkAvailableSpace(for: item.resourceBytes, at: directory, alreadyStaged: retained)
        let weight = item.resourceBytes == 0 ? 1 : Double(item.byteCount) / Double(item.resourceBytes)
        let mainURL = try await prepare(item: item, sourceURL: sourceURL, kind: kind,
                                       verificationProgress: verificationProgress) {
            progress($0 * weight)
        }
        do {
            let pairedURL: URL?
            if let paired = item.pairedVideo {
                pairedURL = try await prepare(item: paired.asItem, sourceURL: sourceURL, kind: kind,
                                              verificationProgress: verificationProgress) {
                    progress(weight + $0 * (1 - weight))
                }
            } else { pairedURL = nil }
            return PreparedMedia(fileURL: mainURL, pairedVideoURL: pairedURL, isResumable: kind != .zip)
        } catch {
            if kind == .zip { await cleanup(mainURL) }
            throw error
        }
    }

    func cleanup(_ prepared: PreparedMedia, preservingResumable: Bool = false) async {
        if preservingResumable && prepared.isResumable { return }
        await cleanup(prepared.fileURL)
        if let paired = prepared.pairedVideoURL { await cleanup(paired) }
    }

    func scan(url: URL, kind: SourceKind,
              progress: @escaping @Sendable (Int) -> Void) async throws -> SourceScan {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        logger.info("Source scan started: \(kind.rawValue, privacy: .public)")
        defer {
            logger.info("Source scan finished in \(ProcessInfo.processInfo.systemUptime - started, privacy: .public) seconds")
        }
        var result: SourceScan
        switch kind {
        case .zip:
            result = try withCoordinatedRead(url: url) { coordinatedURL in
                try self.scanZip(url: coordinatedURL, progress: progress)
            }
        case .folder:
            let contents = try withCoordinatedRead(url: url) { coordinatedURL in
                try self.scanFolderEntries(url: coordinatedURL, progress: progress)
            }
            // Release the directory accessor before separately coordinating its child.
            // File providers must not wait on a second coordinator nested under the first.
            var scan = contents.scan
            if let manifestURL = contents.manifestURL {
                let manifest = try readFolderManifest(url: manifestURL)
                do {
                    scan.items = try PackageImportResolver.resolve(manifest, scanned: scan.items)
                    scan.album = manifest.album; scan.hasValidatedPackageManifest = true
                }
                catch { throw MediaSourceError.invalidArchive(error.localizedDescription) }
            }
            if contents.manifestURL == nil { scan.items.removeAll { $0.relativePath.hasPrefix("__dropack_previews/") } }
            progress(scan.items.count)
            result = scan
        case .mediaFile:
            result = try withCoordinatedRead(url: url) { coordinatedURL in
                let fingerprint = try self.fileFingerprint(url: coordinatedURL)
                let path = coordinatedURL.lastPathComponent
                guard MediaPolicy.isSafeRelativePath(path), !MediaPolicy.shouldIgnore(path),
                      let mediaKind = MediaPolicy.kind(for: path) else {
                    throw MediaSourceError.sourceUnavailable("请选择支持的照片或视频。")
                }
                let item = ImportItem(id: self.stableID(["mediaFile", path,
                    String(fingerprint.byteCount), self.dateKey(fingerprint.modifiedAt)]),
                    relativePath: path, kind: mediaKind, byteCount: fingerprint.byteCount,
                    modifiedAt: fingerprint.modifiedAt)
                progress(1)
                return SourceScan(items: [item], fingerprint: fingerprint, ignoredCount: 0)
            }
        }
        // Preserve Live Photo grouping in exported ZIPs/folders, but only the
        // actual Dropack document type becomes a received shared album.
        result.isSharedAlbum = kind == .zip && url.pathExtension.lowercased() == "dropack"
            && result.hasValidatedPackageManifest
        if kind != .zip {
            for index in result.items.indices where result.items[index].creationDate == nil {
                let file = kind == .folder ? url.appendingPathComponent(result.items[index].relativePath) : url
                result.items[index].creationDate = await MediaCaptureDate.read(file, kind: result.items[index].kind)
            }
        }
        result.items.sort {
            let a = $0.creationDate ?? $0.modifiedAt ?? .distantPast
            let b = $1.creationDate ?? $1.modifiedAt ?? .distantPast
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        if kind == .zip, let fingerprint = result.fingerprint {
            scannedZipFingerprints[url.absoluteString] = fingerprint
        }
        return result
    }

    /// File-provider bookmark creation may block while the provider responds.
    /// Keep that synchronous work on this actor, away from MainActor and the UI.
    func makeBookmark(for url: URL) async throws -> Data {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        logger.info("Source bookmark creation started")
        defer {
            logger.info("Source bookmark creation finished in \(ProcessInfo.processInfo.systemUptime - started, privacy: .public) seconds")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .minimalBookmark,
                                       includingResourceValuesForKeys: nil, relativeTo: nil)
        try Task.checkCancellation()
        return data
    }

    /// Verify the actual resource bytes before displaying a duplicate count.
    /// Manifest SHA values are only expected values, never trusted receipts.
    func verifiedItems(_ items: [ImportItem], sourceURL: URL, kind: SourceKind,
                       progress: @escaping @Sendable (Int) -> Void) async throws -> [ImportItem] {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        if kind == .zip {
            return try withCoordinatedRead(url: sourceURL) { local in
                let archive = try self.openArchive(url: local)
                var result = items
                for index in result.indices {
                    try Task.checkCancellation()
                    let item = result[index]
                    let primary = try self.resourceDigest(item, archive: archive)
                    let paired = try item.pairedVideo.map { try self.resourceDigest($0.asItem, archive: archive) }
                    try self.checkExpected(item, primary: primary, paired: paired)
                    result[index].contentIdentity = try ImportContentIdentity.media(kind: item.kind, primarySHA256: primary, pairedSHA256: paired)
                    progress(index + 1)
                }
                return result
            }
        }
        let hasher = ImportContentHasher()
        var result = items
        for index in result.indices {
            try Task.checkCancellation()
            let item = result[index]
            let url = kind == .folder ? try folderItemURL(item: item, root: sourceURL) : sourceURL
            let primary = try await hasher.hashFile(url, expectedBytes: item.byteCount, expectedModifiedAt: item.modifiedAt)
            let paired: String?
            if let video = item.pairedVideo {
                let videoURL = try folderItemURL(item: video.asItem, root: sourceURL)
                paired = try await hasher.hashFile(videoURL, expectedBytes: video.byteCount, expectedModifiedAt: video.modifiedAt)
            } else { paired = nil }
            try checkExpected(item, primary: primary, paired: paired)
            result[index].contentIdentity = try ImportContentIdentity.media(kind: item.kind, primarySHA256: primary, pairedSHA256: paired)
            progress(index + 1)
        }
        return result
    }

    private func checkExpected(_ item: ImportItem, primary: String, paired: String?) throws {
        if let expected = item.expectedSHA256, expected.lowercased() != primary { throw MediaSourceError.corruptItem(item.relativePath) }
        if let expected = item.pairedVideo?.sha256, expected.lowercased() != paired { throw MediaSourceError.corruptItem(item.relativePath) }
    }

    private func resourceDigest(_ item: ImportItem, archive: Archive) throws -> String {
        guard let index = item.archiveIndex, indexedZipEntries.indices.contains(index) else { throw MediaSourceError.itemChanged(item.relativePath) }
        let entry = indexedZipEntries[index]
        guard entry.path == item.relativePath, entry.uncompressedSize == item.byteCount,
              entry.checksum == item.checksum else { throw MediaSourceError.itemChanged(item.relativePath) }
        var digest = SHA256()
        var count: UInt64 = 0
        let crc = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false) { bytes in
            try autoreleasepool {
                try Task.checkCancellation()
                count += UInt64(bytes.count)
                guard count <= item.byteCount else { throw MediaSourceError.corruptItem(item.relativePath) }
                digest.update(data: bytes)
            }
        }
        guard count == item.byteCount, crc == item.checksum else { throw MediaSourceError.corruptItem(item.relativePath) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Preview extraction is isolated from resumable import staging. Large ZIP
    /// videos are not copied merely to draw a tile; their preview is cached after
    /// the real import. Raw files can be seeked directly by AVFoundation.
    func previewFile(item: ImportItem, source: URL, kind: SourceKind, directory: URL) throws -> URL? {
        if let previewPath = item.previewPath {
            guard MediaPolicy.isSafeRelativePath(previewPath), previewPath.hasPrefix("__dropack_previews/") else { return nil }
            if kind == .folder {
                let preview = ImportItem(id: previewPath, relativePath: previewPath, kind: .photo, byteCount: 0)
                let child = try folderItemURL(item: preview, root: source)
                let values = try child.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1024 * 1024 else { return nil }
                return child
            }
            if kind == .zip {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                do {
                    try withCoordinatedRead(url: source) { local in
                        let archive = try self.openArchive(url: local)
                        guard let entry = archive[previewPath], entry.type == .file, entry.uncompressedSize <= 1024 * 1024 else {
                            throw MediaSourceError.itemChanged(previewPath)
                        }
                        let output = try self.createOutput(at: target)
                        defer { try? output.close() }
                        var count: UInt64 = 0
                        let crc = try archive.extract(entry, bufferSize: self.chunkSize, skipCRC32: false) { bytes in
                            try Task.checkCancellation()
                            count += UInt64(bytes.count)
                            guard count <= 1024 * 1024 else { throw MediaSourceError.corruptItem(previewPath) }
                            try output.write(contentsOf: bytes)
                        }
                        guard crc == entry.checksum, count == entry.uncompressedSize else { throw MediaSourceError.corruptItem(previewPath) }
                    }
                    return target
                } catch { try? FileManager.default.removeItem(at: target); throw error }
            }
        }
        if kind == .mediaFile { return source }
        if kind == .folder { return try folderItemURL(item: item, root: source) }
        guard item.byteCount <= 64 * 1024 * 1024 else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension((item.relativePath as NSString).pathExtension)
        do {
            try withCoordinatedRead(url: source) { local in
                try self.prepareZip(item: item, url: local, destination: target,
                                    expectedFingerprint: nil, progress: { _ in })
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func prepare(item: ImportItem, sourceURL: URL, kind: SourceKind,
                 verificationProgress: @escaping @Sendable (Double) -> Void = { _ in },
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard MediaPolicy.isSafeRelativePath(item.relativePath),
              !MediaPolicy.shouldIgnore(item.relativePath),
              MediaPolicy.kind(for: item.relativePath) == item.kind else {
            throw MediaSourceError.itemChanged(item.relativePath)
        }
        let directory = try stagingDirectory()
        let fileExtension = (item.relativePath as NSString).pathExtension.lowercased()
        let destination = kind == .zip
            ? directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            : resumableDestination(for: item, in: directory)
        let expectedFingerprint = scannedZipFingerprints[sourceURL.absoluteString]
        do {
            switch kind {
            case .zip:
                try withCoordinatedRead(url: sourceURL) { coordinatedURL in
                    try self.prepareZip(item: item, url: coordinatedURL, destination: destination,
                                   expectedFingerprint: expectedFingerprint, progress: progress)
                }
            case .folder:
                // A coordinated read of a directory does not coordinate its descendants.
                // Keep the root bookmark's access alive while separately coordinating the media file,
                // so iCloud and other providers can materialize that specific file before we open it.
                let scoped = sourceURL.startAccessingSecurityScopedResource()
                defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
                let child = try withCoordinatedRead(url: sourceURL) { root in
                    try self.folderItemURL(item: item, root: root)
                }
                try withCoordinatedRead(url: child) { coordinatedURL in
                    try self.prepareFolderFile(item: item, url: coordinatedURL,
                                               destination: destination,
                                               verificationProgress: verificationProgress, progress: progress)
                }
            case .mediaFile:
                guard sourceURL.lastPathComponent == item.relativePath else {
                    throw MediaSourceError.itemChanged(item.relativePath)
                }
                try withCoordinatedRead(url: sourceURL) { coordinatedURL in
                    try self.prepareFolderFile(item: item, url: coordinatedURL,
                                               destination: destination,
                                               verificationProgress: verificationProgress, progress: progress)
                }
            }
            try Task.checkCancellation()
            return destination
        } catch {
            // Compressed entries cannot resume a deflate stream. Uncompressed
            // source files keep their durable prefix across pause/unplug/relaunch.
            if kind == .zip { try? FileManager.default.removeItem(at: destination) }
            else if case MediaSourceError.corruptItem = error {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    func cleanup(_ url: URL) async {
        guard let directory = try? stagingDirectory(),
              url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Called after Photos has finished or at launch before resuming an interrupted job.
    func cleanupAll() async {
        guard let directory = try? stagingDirectory(),
              let children = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: nil, options: []) else { return }
        for child in children { try? FileManager.default.removeItem(at: child) }
    }

    /// Remove abandoned ZIP work and completed resources, retaining only the raw
    /// files which this job is still allowed to prepare. An uncertain Photos write
    /// must first be resolved by the user and is never resumed automatically.
    func cleanupForResume(job: ImportJob) async {

        guard let directory = try? stagingDirectory(),
              let children = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil) else { return }
        let keep = Set(job.items.filter { $0.state == .pending || $0.state == .failed }
            .flatMap { item -> [URL] in
                var urls = [resumableDestination(for: item, in: directory)]
                if let paired = item.pairedVideo { urls.append(resumableDestination(for: paired.asItem, in: directory)) }
                return urls.map(\.standardizedFileURL)
            })
        for child in children where !keep.contains(child.standardizedFileURL) && !child.lastPathComponent.hasPrefix("resume-") {
            try? FileManager.default.removeItem(at: child)
        }
    }

    func cleanupResumableFiles(for job: ImportJob) throws {
        guard job.source.kind != .zip else { return }
        let directory = try stagingDirectory()
        for item in job.items {
            try? FileManager.default.removeItem(at: resumableDestination(for: item, in: directory))
            if let paired = item.pairedVideo {
                try? FileManager.default.removeItem(at: resumableDestination(for: paired.asItem, in: directory))
            }
        }
    }

    private func withCoordinatedRead<Value>(url: URL,
                                           body: @escaping (URL) throws -> Value) throws -> Value {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let started = ProcessInfo.processInfo.systemUptime
        logger.info("File coordination requested")
        defer {
            logger.info("File coordination finished in \(ProcessInfo.processInfo.systemUptime - started, privacy: .public) seconds")
        }
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { localURL in
            self.logger.info("File coordination acquired after \(ProcessInfo.processInfo.systemUptime - started, privacy: .public) seconds")
            // The accessor must finish reading before it returns. Never start an async Task here.
            result = Result { try body(localURL) }
        }
        if let coordinationError {
            throw MediaSourceError.sourceUnavailable("（\(coordinationError.localizedDescription)）")
        }
        guard let result else { throw MediaSourceError.sourceUnavailable("") }
        return try result.get()
    }

    private func scanZip(url: URL, progress: @Sendable (Int) -> Void) throws -> SourceScan {
        let fingerprint = try fileFingerprint(url: url)
        let centralDirectory = try validateZipDirectory(url: url, byteCount: fingerprint.byteCount)
        let archive = try openArchive(url: url)
        var items: [ImportItem] = []
        var ignored = 0
        var visited = 0
        var entries: [Entry] = []
        var manifestEntry: Entry?
        var album: ShareAlbumMetadata?
        var lastProgress = -Double.infinity
        progress(0)
        for entry in archive {
            try Task.checkCancellation()
            guard entries.count < PackageFormatLimits.maxZIPEntries else {
                throw MediaSourceError.invalidArchive("文件数量过多，请分成几个照片包导入。")
            }
            entries.append(entry)
            if entry.path == PhotoPackageManifest.filename {
                guard entry.type == .file, manifestEntry == nil else {
                    throw MediaSourceError.invalidArchive("照片包清单重复或类型不正确。")
                }
                manifestEntry = entry
            }
            let index = visited
            visited += 1
            if entry.type == .file {
                let path = entry.path
                if MediaPolicy.isSafeRelativePath(path), !MediaPolicy.shouldIgnore(path),
                   let kind = MediaPolicy.kind(for: path) ?? (path.hasPrefix("__dropack_previews/") && path.hasSuffix(".preview") ? .photo : nil) {
                    let modifiedAt = entry.fileAttributes[.modificationDate] as? Date
                    items.append(ImportItem(
                        id: stableID(["zip", String(index), path, String(entry.uncompressedSize),
                                      String(entry.checksum)]),
                        relativePath: path, kind: kind, byteCount: entry.uncompressedSize,
                        modifiedAt: modifiedAt, archiveIndex: index, checksum: entry.checksum))
                } else { ignored += 1 }
            } else if entry.type == .symlink { ignored += 1 }
            reportScan(count: items.count, lastTime: &lastProgress, progress: progress)
        }
        guard UInt64(visited) == centralDirectory.entryCount else {
            throw MediaSourceError.invalidArchive("目录记录不完整。")
        }
        guard try fileFingerprint(url: url) == fingerprint else { throw MediaSourceError.sourceChanged }
        if let manifestEntry {
            let manifest = try readManifest(archive: archive, entry: manifestEntry)
            do { items = try PackageImportResolver.resolve(manifest, scanned: items); album = manifest.album }
            catch { throw MediaSourceError.invalidArchive(error.localizedDescription) }
        }
        if manifestEntry == nil { items.removeAll { $0.relativePath.hasPrefix("__dropack_previews/") } }
        indexedZipURL = url
        indexedZipFingerprint = fingerprint
        indexedZipEntries = entries
        progress(items.count)
        return SourceScan(items: items, fingerprint: fingerprint, ignoredCount: ignored, album: album,
                          hasValidatedPackageManifest: manifestEntry != nil)
    }

    private func readManifest(archive: Archive, entry: Entry) throws -> PhotoPackageManifest {
        let limit = Int(PackageFormatLimits.maxManifestBytes)
        guard entry.uncompressedSize <= UInt64(limit) else {
            throw MediaSourceError.invalidArchive("照片包清单过大。")
        }
        var data = Data()
        let crc = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= limit - data.count else {
                throw MediaSourceError.invalidArchive("照片包清单超过限制。")
            }
            data.append(chunk)
        }
        guard crc == entry.checksum, UInt64(data.count) == entry.uncompressedSize else {
            throw MediaSourceError.invalidArchive("照片包清单损坏。")
        }
        do { return try JSONDecoder().decode(PhotoPackageManifest.self, from: data) }
        catch { throw MediaSourceError.invalidArchive("照片包清单格式不正确。") }
    }

    private func scanFolderEntries(url: URL, progress: @Sendable (Int) -> Void) throws
        -> (scan: SourceScan, manifestURL: URL?) {
        try validateFolderRoot(url)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                       .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw MediaSourceError.sourceUnavailable("") }
        let rootPrefix = url.standardizedFileURL.path.hasSuffix("/")
            ? url.standardizedFileURL.path : url.standardizedFileURL.path + "/"
        var items: [ImportItem] = []
        var ignored = 0
        var manifestURL: URL?
        var visited = 0
        var lastProgress = -Double.infinity
        progress(0)
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            // Extracted packages also contain one directory per logical asset.
            guard visited <= PackageFormatLimits.maxZIPEntries * 2 else {
                throw MediaSourceError.invalidArchive("文件数量过多，请分成几个照片包导入。")
            }
            let path = child.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = String(path.dropFirst(rootPrefix.count))
            let values: URLResourceValues
            do { values = try child.resourceValues(forKeys: keys) }
            catch { throw MediaSourceError.sourceUnavailable("（\(error.localizedDescription)）") }
            if values.isSymbolicLink == true || values.isHidden == true
                || MediaPolicy.shouldIgnore(relativePath) || !MediaPolicy.isSafeRelativePath(relativePath) {
                enumerator.skipDescendants()
                if values.isDirectory != true { ignored += 1 }
                continue
            }
            if values.isDirectory == true { continue }
            if relativePath == PhotoPackageManifest.filename, values.isRegularFile == true {
                manifestURL = child
                continue
            }
            guard values.isRegularFile == true, let kind = MediaPolicy.kind(for: relativePath) ?? (relativePath.hasPrefix("__dropack_previews/") && relativePath.hasSuffix(".preview") ? .photo : nil),
                  let size = values.fileSize, size >= 0 else {
                ignored += 1
                continue
            }
            let modifiedAt = values.contentModificationDate
            items.append(ImportItem(
                id: stableID(["folder", relativePath, String(size), dateKey(modifiedAt)]),
                relativePath: relativePath, kind: kind, byteCount: UInt64(size), modifiedAt: modifiedAt))
            reportScan(count: items.count, lastTime: &lastProgress, progress: progress)
        }
        if let enumerationError {
            throw MediaSourceError.sourceUnavailable("（\(enumerationError.localizedDescription)）")
        }
        items.sort { $0.relativePath < $1.relativePath }
        return (SourceScan(items: items, fingerprint: nil, ignoredCount: ignored), manifestURL)
    }

    private func readFolderManifest(url: URL) throws -> PhotoPackageManifest {
        try withCoordinatedRead(url: url) { localURL in
                let input = try FileHandle(forReadingFrom: localURL)
                defer { try? input.close() }
                let limit = Int(PackageFormatLimits.maxManifestBytes)
                var data = Data()
                while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: self.chunkSize) }), !chunk.isEmpty {
                    try Task.checkCancellation()
                    guard chunk.count <= limit - data.count else {
                        throw MediaSourceError.invalidArchive("照片包清单过大。")
                    }
                    data.append(chunk)
                }
                do { return try JSONDecoder().decode(PhotoPackageManifest.self, from: data) }
                catch { throw MediaSourceError.invalidArchive("照片包清单格式不正确。") }
        }
    }

    private func prepareZip(item: ImportItem, url: URL, destination: URL,
                            expectedFingerprint: SourceFingerprint?,
                            progress: @Sendable (Double) -> Void) throws {
        let fingerprint = try fileFingerprint(url: url)
        if let expectedFingerprint, fingerprint != expectedFingerprint {
            throw MediaSourceError.sourceChanged
        }
        if expectedFingerprint == nil {
            _ = try validateZipDirectory(url: url, byteCount: fingerprint.byteCount)
        }
        guard let wantedIndex = item.archiveIndex, wantedIndex >= 0 else {
            throw MediaSourceError.itemChanged(item.relativePath)
        }
        let archive = try openArchive(url: url)
        var selected: Entry?
        if indexedZipURL == url, indexedZipFingerprint == fingerprint,
           indexedZipEntries.indices.contains(wantedIndex) {
            selected = indexedZipEntries[wantedIndex]
        } else {
            for (index, entry) in archive.enumerated() {
                try Task.checkCancellation()
                if index == wantedIndex { selected = entry; break }
            }
        }
        guard let entry = selected, entry.type == .file,
              entry.path == item.relativePath, entry.uncompressedSize == item.byteCount,
              entry.checksum == item.checksum,
              entry.fileAttributes[.modificationDate] as? Date == item.modifiedAt else {
            throw MediaSourceError.itemChanged(item.relativePath)
        }
        let output = try createOutput(at: destination)
        defer { try? output.close() }
        var written: UInt64 = 0
        var hasher = SHA256()
        var lastProgress = -Double.infinity
        progress(0)
        do {
            let crc = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false) { data in
                try autoreleasepool {
                    try Task.checkCancellation()
                    let newSize = written.addingReportingOverflow(UInt64(data.count))
                    guard !newSize.overflow, newSize.partialValue <= item.byteCount else {
                        throw MediaSourceError.corruptItem(item.relativePath)
                    }
                    do { try output.write(contentsOf: data) }
                    catch { throw MediaSourceError.ioFailure(error.localizedDescription) }
                    written = newSize.partialValue
                    if item.expectedSHA256 != nil { hasher.update(data: data) }
                    reportBytes(written, total: item.byteCount, lastTime: &lastProgress, progress: progress)
                }
            }
            // On unplug, report a lost source before classifying a short extraction
            // as a corrupt entry; the controller then preserves pending items.
            guard try fileFingerprint(url: url) == fingerprint else { throw MediaSourceError.sourceChanged }
            guard crc == entry.checksum, written == item.byteCount else {
                throw MediaSourceError.corruptItem(item.relativePath)
            }
            if let expected = item.expectedSHA256,
               hasher.finalize().map({ String(format: "%02x", $0) }).joined() != expected.lowercased() {
                throw MediaSourceError.corruptItem(item.relativePath)
            }
            guard try fileFingerprint(url: url) == fingerprint else { throw MediaSourceError.sourceChanged }
            try Task.checkCancellation()
            try output.synchronize()
            progress(1)
        } catch is CancellationError { throw CancellationError() }
        catch let error as MediaSourceError { throw error }
        catch let error as Archive.ArchiveError {
            switch error {
            case .cancelledOperation: throw CancellationError()
            case .invalidCRC32: throw MediaSourceError.corruptItem(item.relativePath)
            case .invalidCompressionMethod:
                throw MediaSourceError.ioFailure("“\(item.relativePath)”使用了不支持的 ZIP 压缩方式，支持存储和 Deflate。")
            default: throw MediaSourceError.invalidArchive("（\(String(describing: error))）")
            }
        } catch { throw MediaSourceError.ioFailure(error.localizedDescription) }
    }

    private func folderItemURL(item: ImportItem, root: URL) throws -> URL {
        try validateFolderRoot(root)
        var child = root
        // Check every component to prevent a changed folder from redirecting us through a symlink.
        let parts = item.relativePath.split(separator: "/")
        for (index, component) in parts.enumerated() {
            child.appendPathComponent(String(component))
            let values: URLResourceValues
            do { values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) }
            catch { throw MediaSourceError.itemChanged(item.relativePath) }
            guard values.isSymbolicLink != true,
                  index == parts.count - 1 || values.isDirectory == true else {
                throw MediaSourceError.itemChanged(item.relativePath)
            }
        }
        return child
    }

    private func prepareFolderFile(item: ImportItem, url: URL, destination: URL,
                                   verificationProgress: @Sendable (Double) -> Void,
                                   progress: @Sendable (Double) -> Void) throws {
        let child = url
        try validateFolderItem(item, at: child)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let empty = try createOutput(at: destination)
            try empty.close()
        }
        var hasher = SHA256()
        var lastProgress = -Double.infinity
        var lastVerificationProgress = -Double.infinity
        progress(0)
        do {
            try ResumableFileCopy.copy(from: child, to: destination, expectedBytes: item.byteCount,
                chunkSize: chunkSize, verificationProgress: { verified, total in
                    self.reportBytes(verified, total: total, lastTime: &lastVerificationProgress,
                                     progress: verificationProgress)
                }, consume: { data in
                    if item.expectedSHA256 != nil { hasher.update(data: data) }
                }, progress: { written in
                    self.reportBytes(written, total: item.byteCount, lastTime: &lastProgress, progress: progress)
                })
        } catch ResumableCopyError.sourceChanged {
            throw MediaSourceError.itemChanged(item.relativePath)
        } catch ResumableCopyError.sourceReadFailed(let message) {
            throw MediaSourceError.sourceUnavailable("（\(message)）")
        } catch ResumableCopyError.destinationWriteFailed(let message) {
            throw MediaSourceError.ioFailure(message)
        }
        if let expected = item.expectedSHA256,
           hasher.finalize().map({ String(format: "%02x", $0) }).joined() != expected.lowercased() {
            throw MediaSourceError.corruptItem(item.relativePath)
        }
        try validateFolderItem(item, at: child)
        try Task.checkCancellation()
        progress(1)
    }

    private func resumableDestination(for item: ImportItem, in directory: URL) -> URL {
        let identity = stableID([item.id, item.relativePath, String(item.byteCount),
                                 dateKey(item.modifiedAt), item.expectedSHA256 ?? ""])
        return directory.appendingPathComponent("resume-" + identity)
            .appendingPathExtension((item.relativePath as NSString).pathExtension.lowercased())
    }

    private func retainedBytes(for item: ImportItem, in directory: URL) -> UInt64 {
        func bytes(_ resource: ImportItem) -> UInt64 {
            let url = resumableDestination(for: resource, in: directory)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
            return min(resource.byteCount, size?.uint64Value ?? 0)
        }
        let main = bytes(item)
        let other = item.pairedVideo.map { bytes($0.asItem) } ?? 0
        let total = main.addingReportingOverflow(other)
        return total.overflow ? UInt64.max : total.partialValue
    }

    private func validateFolderRoot(_ url: URL) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch { throw MediaSourceError.sourceUnavailable("（\(error.localizedDescription)）") }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MediaSourceError.sourceUnavailable("请选择真实文件夹。")
        }
    }

    private func validateFolderItem(_ item: ImportItem, at url: URL) throws {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                            .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, UInt64(size) == item.byteCount,
              values.contentModificationDate == item.modifiedAt else {
            throw MediaSourceError.itemChanged(item.relativePath)
        }
    }

    private func fileFingerprint(url: URL) throws -> SourceFingerprint {
        do {
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                        .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= 0 else {
                throw MediaSourceError.sourceUnavailable("请选择真实的照片包、照片或视频文件。")
            }
            return SourceFingerprint(byteCount: UInt64(size), modifiedAt: values.contentModificationDate)
        } catch let error as MediaSourceError { throw error }
        catch { throw MediaSourceError.sourceUnavailable("（\(error.localizedDescription)）") }
    }

    private func stagingDirectory() throws -> URL {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            var directory = support.appendingPathComponent("PhotoRelay/Staging", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            return directory
        } catch { throw MediaSourceError.ioFailure(error.localizedDescription) }
    }

    private func createOutput(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw MediaSourceError.ioFailure("无法创建临时文件，请检查设备可用空间。")
        }
        do { return try FileHandle(forWritingTo: url) }
        catch { throw MediaSourceError.ioFailure(error.localizedDescription) }
    }

    private func checkAvailableSpace(for bytes: UInt64, at directory: URL, alreadyStaged: UInt64 = 0) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                            .volumeAvailableCapacityKey])
        let available: UInt64
        if let important = values?.volumeAvailableCapacityForImportantUsage, important >= 0 {
            available = UInt64(important)
        } else if let capacity = values?.volumeAvailableCapacity, capacity >= 0 {
            available = UInt64(capacity)
        } else if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
                  let free = attributes[.systemFreeSize] as? NSNumber {
            available = free.uint64Value
        } else { throw MediaSourceError.ioFailure("无法确认设备剩余空间，请稍后重试。") }
        let remainingStaging = bytes - min(bytes, alreadyStaged)
        let doubled = bytes.addingReportingOverflow(remainingStaging)
        let safetyMargin = max(UInt64(256 * 1024 * 1024), bytes / 10)
        let total = doubled.partialValue.addingReportingOverflow(safetyMargin)
        let required = doubled.overflow || total.overflow ? UInt64.max : total.partialValue
        guard available >= required else {
            throw MediaSourceError.insufficientSpace(required: required, available: available)
        }
    }

    private func openArchive(url: URL) throws -> Archive {
        do { return try Archive(url: url, accessMode: .read) }
        catch { throw MediaSourceError.invalidArchive("（\(error.localizedDescription)）") }
    }

    private func stableID(_ fields: [String]) -> String {
        var hash = SHA256()
        for field in fields {
            let bytes = Data(field.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func dateKey(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil"
    }

    private func reportScan(count: Int, lastTime: inout Double, progress: @Sendable (Int) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTime >= 0.1 { lastTime = now; progress(count) }
    }

    private func reportBytes(_ written: UInt64, total: UInt64, lastTime: inout Double,
                             progress: @Sendable (Double) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTime >= 0.1 {
            lastTime = now
            progress(total == 0 ? 0 : min(1, Double(written) / Double(total)))
        }
    }

    private func validateZipDirectory(url: URL, byteCount: UInt64) throws -> ZipDirectory {
        do { return try ZipDirectoryValidator.validate(url: url, byteCount: byteCount) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ZipValidationError {
            switch error {
            case .invalid(let message): throw MediaSourceError.invalidArchive(message)
            case .encrypted: throw MediaSourceError.encryptedArchive
            case .multipart: throw MediaSourceError.multipartArchive
            }
        } catch { throw MediaSourceError.sourceUnavailable("（\(error.localizedDescription)）") }
    }
}
