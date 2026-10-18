import CryptoKit
import Darwin
import Foundation
import ImageIO
import UIKit
import Photos
import UniformTypeIdentifiers
import ZIPFoundation

struct PackageUpdate: Sendable {
    var job: PackageJob?
    var stage: String
    var fraction: Double
    var name: String
    /// Bytes read for the current resource; total size is unknown. Nil means
    /// this update uses its existing phase/fraction reporting instead.
    var readBytes: UInt64? = nil
    /// Journal identity, never a filename. Live Photo resources share one ID.
    var assetID: String? = nil
    /// Original acquisition is independent of bytes committed to the ZIP.
    var originalProgress: PackageOriginalProgress? = nil
    var packingFraction: Double? = nil
}

struct PackageRestoration: Sendable {
    var job: PackageJob?
    var archiveURL: URL?
}

enum PhotoPackageError: Error, LocalizedError {
    case permission, missingAsset, unsupported(String), emptyResource(String)
    case insufficientSpace(UInt64, UInt64), disk(String), archiveMismatch, emptyAlbum, pickerReselection, pickerReselectionMismatch, pickerReselectionUnavailable
    var errorDescription: String? {
        switch self {
        case .pickerReselectionMismatch: return "请重新选择这个分享相册中尚未读取的原照片或视频。所选项目不匹配，已有资源没有改变。"
        case .pickerReselectionUnavailable: return "系统没有提供部分原照片的标识，无法安全恢复这次选择。请重新创建分享相册；旧相册中已读取的资源仍保留。"
        case .pickerReselection: return "部分所选资源尚未读取完成。请重新选择这些照片或视频；已经读取的资源仍保留在这个分享相册中。"
        case .emptyAlbum: return "这个系统相册已经没有照片或视频。请先添加内容，再更新分享相册。旧分享文件已保留。"
        case .permission: return "需要读取照片权限。请在系统设置中允许 Dropack 访问所选照片；有限访问时只能打包已授权的照片。"
        case .missingAsset: return "有照片已删除、移出授权范围或无法读取。请恢复照片访问权限后继续，或重新选择照片。"
        case .unsupported(let name): return "无法导出“\(name)”的原始照片或视频格式。请在照片中确认原文件可用后重试。"
        case .emptyResource(let name): return "“\(name)”的原文件为空，打包已停止，请检查原片后重试。"
        case .insufficientSpace(let required, let available):
            let formatter = ByteCountFormatter()
            return "设备空间不足。当前步骤需要约 \(formatter.string(fromByteCount: Int64(clamping: required)))，可用 \(formatter.string(fromByteCount: Int64(clamping: available)))。请释放空间后继续。"
        case .disk(let detail): return "无法写入照片包，请检查设备剩余空间后继续。\(detail)"
        case .archiveMismatch: return "照片包与打包记录不一致，无法安全发送。请清除任务后重新打包；原相册不会受影响。"
        }
    }
}

/// Heavy PhotoKit export and ZIP I/O are isolated from the main actor.
actor PhotoPackageService {
    private let root: URL
    private nonisolated let libraryStore: PackageLibraryStore
    private let thumbnailLoader: any MediaThumbnailGenerating
    private let thumbnailClock: @Sendable () -> TimeInterval
    private var runningID: UUID?
    private var mutationInProgress = false
    private var thumbnailRequests = 0
    private struct ThumbnailKey: Hashable { let packageID: UUID; let itemID: String }
    /// Packing completion does not change the original used by a preview.
    private struct ThumbnailSource: Equatable {
        let identifier: String
        let kind: MediaKind?
        let modifiedAt: Date?
        let file: PackageFileSource?
        let pickerPending: Bool?
        init(_ item: PackageAsset) {
            identifier = item.assetIdentifier; kind = item.kind
            modifiedAt = item.sourceModifiedAt; file = item.fileSource
            pickerPending = item.pickerResourcePending
        }
    }
    private struct ThumbnailRequest {
        let id: UUID
        let source: ThumbnailSource
        let task: Task<URL?, Never>
        var waiters: Set<UUID>
    }
    private struct ThumbnailFailure { let source: ThumbnailSource; let retryAt: TimeInterval }
    private var thumbnailTasks: [ThumbnailKey: ThumbnailRequest] = [:]
    private var thumbnailFailures: [ThumbnailKey: ThumbnailFailure] = [:]
    private let chunkSize = 1024 * 1024
    private let safetyMargin: UInt64 = 256 * 1024 * 1024

    init(root: URL? = nil, thumbnailLoader: any MediaThumbnailGenerating = MediaThumbnailLoader(),
         thumbnailClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = root ?? support.appendingPathComponent("Dropack/Packaging", isDirectory: true)
        libraryStore = PackageLibraryStore(root: self.root)
        self.thumbnailLoader = thumbnailLoader
        self.thumbnailClock = thumbnailClock
    }

    func restore() throws -> PackageRestoration {
        try prepareRoot()
        guard let id = try libraryStore.selectedID() else {
            return PackageRestoration(job: nil, archiveURL: nil)
        }
        guard try libraryStore.load(id: id) != nil else {
            try libraryStore.select(nil)
            return PackageRestoration(job: nil, archiveURL: nil)
        }
        return try activate(packageID: id)
    }

    func library() throws -> [PackageLibraryEntry] {
        try prepareRoot()
        return try libraryStore.entries()
    }

    func activate(packageID: UUID) throws -> PackageRestoration {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        try prepareRoot()
        guard var job = try libraryStore.load(id: packageID) else { throw PackageModelError.invalidCheckpoint }
        try rollbackIfNeeded(&job)
        try cleanupStaging(job)
        let archive = archiveURL(job)
        if !FileManager.default.fileExists(atPath: archive.path), job.completedCount == 0, job.phase != .ready {
            try createEmptyArchive(job)
        }
        try validateArchive(job)
        try libraryStore.save(job)
        try libraryStore.select(packageID)
        return PackageRestoration(job: job, archiveURL: job.phase == .ready ? archive : nil)
    }

    func currentJob() throws -> PackageJob? {
        guard let id = try libraryStore.selectedID() else { return nil }
        return try libraryStore.load(id: id)
    }
    func currentPackageID() throws -> UUID? { try libraryStore.selectedID() }
    func job(packageID: UUID) throws -> PackageJob? { try libraryStore.load(id: packageID) }

    func shareURL(packageID: UUID, format: PackageFileFormat) async throws -> URL {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true
        defer { mutationInProgress = false }
        _ = try await refreshAlbumUnreserved(packageID: packageID)
        guard let requested = try libraryStore.load(id: packageID),
              let job = try libraryStore.latest(albumID: requested.stableAlbumID), job.phase == .ready else {
            throw PackageModelError.invalidCheckpoint
        }
        try validateArchive(job)
        return try format.shareURL(for: archiveURL(job), title: job.displayTitle)
    }

    func shareURL(format: PackageFileFormat) async throws -> URL {
        guard let id = try libraryStore.selectedID() else { throw PackageModelError.invalidCheckpoint }
        return try await shareURL(packageID: id, format: format)
    }

    func create(assetIdentifiers: [String]) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try prepareRoot()
        let identifiers = Array(NSOrderedSet(array: assetIdentifiers)) as? [String] ?? []
        guard !identifiers.isEmpty else { throw PhotoPackageError.missingAsset }
        try PackageFormatLimits.validateSelectionCount(identifiers.count)
        var job = await newJob(assetIdentifiers: identifiers)
        job.assets = photoAssets(identifiers: identifiers)
        let title = ShareAlbumNaming.title(dates: job.assets.compactMap(\.captureDate), fallback: job.createdAt)
        job.album?.title = title
        job.archiveFilename = ShareAlbumNaming.safeFilename(title: title, extension: "dropack")
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
           job.assets.allSatisfy({ $0.kind != nil }) {
            job.linkedPhotosAlbumIdentifier = try await SystemAlbumService.shared.ensureAlbum(
                albumID: job.stableAlbumID, title: title, assetIdentifiers: identifiers, requestAuthorization: false)
        }
        try createEmptyArchive(job)
        do { try libraryStore.save(job) }
        catch { try? FileManager.default.removeItem(at: directory(job)); throw error }
        // A selection-write failure preserves the newly journaled package in the
        // library. It must never delete an older package as a side effect.
        try libraryStore.select(job.id)
        return job
    }

    /// The picker grants access to its resources independently of PhotoKit's
    /// limited-library identifier set. Only use the PhotoKit path when all IDs
    /// were actually fetched successfully; otherwise retain a private local copy.
    func create(selection: PhotoPickerSelection) async throws -> PackageJob {
        if let identifiers = selection.readablePhotoIdentifiers {
            return try await create(assetIdentifiers: identifiers)
        }
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try prepareRoot()
        try PackageFormatLimits.validateSelectionCount(selection.count)
        var job = await newJob(assetIdentifiers: selection.items.map { _ in "picker:" + UUID().uuidString })
        for index in job.assets.indices {
            job.assets[index].kind = selection.items[index].kind
            job.assets[index].title = selection.items[index].provider.suggestedName
            job.assets[index].pickerResourcePending = true
            job.assets[index].pickerAssetIdentifier = selection.items[index].assetIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            job.assets[index].pickerSelectionItemID = selection.items[index].id
        }
        try persistNew(job)
        return job
    }

    /// Rebinds only the unfinished resources of the existing draft. Validation
    /// happens before any source access or checkpoint change, so a wrong picker
    /// selection cannot replace content or manufacture a new partial album.
    func reselect(packageID: UUID, selection: PhotoPickerSelection) throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, let job = try libraryStore.load(id: packageID) else {
            throw PackageModelError.invalidCheckpoint
        }
        _ = try selection.resources(for: job)
        try libraryStore.select(job.id)
        return job
    }

    /// Each provider URL is captured and checkpointed before moving to the next
    /// item. Pauses retain completed source copies; retries never copy them again.
    func preparePickerSources(packageID: UUID, selection: PhotoPickerSelection,
                              progress: @escaping @Sendable (PackageUpdate) -> Void) async throws {
        guard runningID == nil, !mutationInProgress, var job = try libraryStore.load(id: packageID) else {
            throw PackageModelError.invalidCheckpoint
        }
        let resources = try selection.resources(for: job)
        mutationInProgress = true
        defer { mutationInProgress = false }
        guard job.assets.contains(where: { $0.pickerResourcePending == true }) else { return }
        do {
            for index in job.assets.indices where job.assets[index].pickerResourcePending == true {
                try Task.checkCancellation()
                guard let selected = resources[job.assets[index].id] else { throw PhotoPackageError.pickerReselectionMismatch }
                let itemID = job.assets[index].id
                let sourceFolder = directory(job).appendingPathComponent("Sources", isDirectory: true)
                    .appendingPathComponent(job.assets[index].id, isDirectory: true)
                progress(PackageUpdate(job: job, stage: "读取所选资源", fraction: 0,
                    name: selected.provider.suggestedName ?? "", assetID: itemID,
                    originalProgress: .init(state: .preparing)))
                let output = try await PickerResourceExporter.capture(selected, directory: sourceFolder,
                    originalProgress: { original, bytes in
                        progress(PackageUpdate(job: nil,
                            stage: original.state == .downloading ? "从 iCloud 下载" : "读取所选资源",
                            fraction: original.state == .ready ? 1 : (original.fraction ?? 0), name: selected.provider.suggestedName ?? "",
                            readBytes: bytes, assetID: itemID, originalProgress: original))
                    }, progress: { _ in })
                var captured = job.assets[index]
                captured.fileSource = try pickerFileSource(output.file)
                if let paired = output.pairedVideo { captured.pairedFileSource = try pickerFileSource(paired) }
                captured.captureDate = await MediaCaptureDate.read(output.file, kind: selected.kind)
                captured.title = selected.provider.suggestedName ?? output.file.lastPathComponent
                captured.pickerResourcePending = false
                var updated = job
                updated.assets[index] = captured
                try libraryStore.save(updated)
                job = updated
                if let image = await thumbnailLoader.thumbnail(fileURL: output.file, kind: selected.kind) {
                    _ = writeThumbnail(image, packageID: job.id, itemID: captured.id)
                }
                progress(PackageUpdate(job: job, stage: "读取所选资源", fraction: 1,
                    name: captured.title ?? "", assetID: captured.id, originalProgress: output.originalProgress))
            }
            try finalizePickerMetadata(&job)
            if job.packagingRequested == false { job.phase = .draft; job.lastMessage = nil }
            try libraryStore.save(job)
        } catch {
            job.phase = error is CancellationError ? .paused : .failed
            job.lastMessage = error is CancellationError ? "读取已暂停，已读取资源已保留。" : error.localizedDescription
            try libraryStore.save(job)
            throw error
        }
    }

    private func finalizePickerMetadata(_ job: inout PackageJob) throws {
        guard job.completedCount == 0, job.titleWasEdited != true,
              job.assets.allSatisfy({ $0.assetIdentifier.hasPrefix("picker:") && $0.pickerResourcePending == false }) else { return }
        let title = ShareAlbumNaming.title(dates: job.assets.compactMap(\.captureDate), fallback: job.createdAt)
        // A checked hard-link alias keeps the old empty archive valid if a crash
        // occurs before the journal commits its metadata-derived filename.
        let alias = try PackageFileFormat.dropack.shareURL(for: archiveURL(job), title: title)
        job.archiveFilename = alias.lastPathComponent
        job.album?.title = title
    }

    private func pickerFileSource(_ url: URL) throws -> PackageFileSource {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = values.fileSize, bytes > 0 else { throw PhotoPackageError.emptyResource(url.lastPathComponent) }
        return PackageFileSource(bookmark: try url.bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil), relativePath: url.lastPathComponent,
            isFolder: false, byteCount: UInt64(bytes), modifiedAt: values.contentModificationDate)
    }

    func create(fileURLs: [URL]) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try prepareRoot()
        let assets = try await PackageFileAccess.scan(fileURLs)
        var job = await newJob(assetIdentifiers: assets.map(\.assetIdentifier))
        job.assets = assets
        let title = ShareAlbumNaming.title(dates: assets.compactMap(\.captureDate), fallback: job.createdAt)
        job.album?.title = title
        job.archiveFilename = ShareAlbumNaming.safeFilename(title: title, extension: "dropack")
        try persistNew(job)
        return job
    }

    private func newJob(assetIdentifiers: [String]) async -> PackageJob {
        // iOS may provide the generic model name unless a special entitlement
        // is granted. That is still a useful device label; no entitlement or
        // contact access is needed, and this must not imply verified identity.
        let senderName = await MainActor.run {
            ShareAlbumNaming.senderName(deviceName: AppPreferences.shared.sharingName)
                ?? ShareAlbumNaming.senderName(deviceName: UIDevice.current.name)
        }
        var job = PackageJob(assetIdentifiers: assetIdentifiers, senderName: senderName)
        job.phase = .draft; job.packagingRequested = false
        return job
    }

    /// Called on entry and immediately before sharing. A revision is a complete,
    /// immutable export; membership removals never delete a Photos original.
    func refreshAlbum(packageID: UUID) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true
        defer { mutationInProgress = false }
        return try await refreshAlbumUnreserved(packageID: packageID)
    }

    private func refreshAlbumUnreserved(packageID: UUID) async throws -> PackageJob {
        guard let requested = try libraryStore.load(id: packageID),
              let current = try libraryStore.latest(albumID: requested.stableAlbumID) else {
            throw PackageModelError.invalidCheckpoint
        }
        var refreshed = current.assets
        if current.linkedPhotosAlbumIdentifier != nil {
            guard let identifiers = try await SystemAlbumService.shared.members(albumID: current.stableAlbumID) else {
                throw PhotoPackageError.permission
            }
            let photos = photoAssets(identifiers: identifiers)
            guard photos.allSatisfy({ $0.kind != nil }) else { throw PhotoPackageError.missingAsset }
            // Files and privately captured picker sources are independent members.
            refreshed = photos + current.assets.filter { $0.fileSource != nil || $0.pickerResourcePending == true }
        } else {
            let photoIDs = current.assets.filter { $0.fileSource == nil && $0.pickerResourcePending != true }.map(\.assetIdentifier)
            if !photoIDs.isEmpty {
                let photos = photoAssets(identifiers: photoIDs)
                // Cached immutable media remains shareable when a Photos grant
                // is no longer visible. Refresh only metadata we can actually read.
                let byID = Dictionary(uniqueKeysWithValues: photos.filter { $0.kind != nil }.map { ($0.assetIdentifier, $0) })
                refreshed = refreshed.map { byID[$0.assetIdentifier] ?? $0 }
            }
        }
        refreshed = try refreshed.map(refreshFileMetadata)
        let previous = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.assetIdentifier, $0) })
        let changed = Set(refreshed.map(\.assetIdentifier)) != Set(current.selectedAssetIdentifiers) || refreshed.contains {
            guard let old = previous[$0.assetIdentifier] else { return true }
            return !unchanged(old, $0)
        }
        guard changed else { return current }
        return try newSnapshot(from: current, assets: refreshed)
    }

    /// File-provider stat only; unavailable originals do not invalidate a durable
    /// cached export. An available changed source is never silently reused.
    private func refreshFileMetadata(_ asset: PackageAsset) throws -> PackageAsset {
        var result = asset
        for paired in [false, true] {
            guard var source = paired ? result.pairedFileSource : result.fileSource,
                  let resolved = try? PackageFileAccess.resolve(source) else { continue }
            let scoped = resolved.root.startAccessingSecurityScopedResource()
            defer { if scoped { resolved.root.stopAccessingSecurityScopedResource() } }
            guard let values = try? resolved.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else {
                throw PhotoPackageError.emptyResource(source.relativePath)
            }
            source.byteCount = UInt64(size); source.modifiedAt = values.contentModificationDate
            if paired { result.pairedFileSource = source }
            else { result.fileSource = source; result.sourceModifiedAt = source.modifiedAt }
        }
        return result
    }

    private func unchanged(_ a: PackageAsset, _ b: PackageAsset) -> Bool {
        func same(_ a: PackageFileSource?, _ b: PackageFileSource?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return a.byteCount == b.byteCount && a.modifiedAt == b.modifiedAt && a.relativePath == b.relativePath
        }
        return a.assetIdentifier == b.assetIdentifier && a.kind == b.kind && a.captureDate == b.captureDate &&
            (a.fileSource != nil || a.sourceModifiedAt == b.sourceModifiedAt) && same(a.fileSource, b.fileSource) && same(a.pairedFileSource, b.pairedFileSource) &&
            a.pickerResourcePending == b.pickerResourcePending
    }

    func requestPackaging(packageID: UUID) throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, var job = try libraryStore.load(id: packageID) else { throw PackageModelError.invalidCheckpoint }
        guard !job.assets.isEmpty else { throw PhotoPackageError.emptyAlbum }
        job.packagingRequested = true
        if job.phase == .draft { job.phase = .preparing }
        try libraryStore.save(job)
        return job
    }

    func previewArchiveURL(packageID: UUID) throws -> URL {
        guard runningID != packageID, let job = try libraryStore.load(id: packageID), job.phase == .ready else {
            throw PackageModelError.invalidCheckpoint
        }
        try validateArchive(job)
        return archiveURL(job)
    }

    /// A draft may point at an immutable ready revision even while its original
    /// removable drive is absent. Resolve the exact retained item, never the
    /// latest album revision, without activating or creating anything.
    func resolvePreviewArchive(packageID: UUID, assetID: String) throws -> (asset: PackageAsset, url: URL) {
        guard runningID != packageID, let current = try libraryStore.load(id: packageID),
              let selected = current.assets.first(where: { $0.id == assetID }) else { throw PackageModelError.invalidCheckpoint }
        if current.phase == .ready, selected.isCompleted {
            try validateArchive(current)
            return (selected, archiveURL(current))
        }
        guard let reused = try reusableAsset(selected, for: current), reused.job.phase == .ready,
              runningID != reused.job.id else { throw PackageModelError.invalidCheckpoint }
        try validateArchive(reused.job)
        return (reused.asset, archiveURL(reused.job))
    }

    /// Shares exactly the completed revision. A later Photos change belongs to
    /// the next draft and must not invalidate this already prepared snapshot.
    func sharePreparedURL(packageID: UUID, format: PackageFileFormat) throws -> URL {
        guard runningID == nil, !mutationInProgress, let job = try libraryStore.load(id: packageID), job.phase == .ready else {
            throw PackageModelError.invalidCheckpoint
        }
        try validateArchive(job)
        return try format.shareURL(for: archiveURL(job), title: job.displayTitle)
    }

    func add(selection: PhotoPickerSelection, to packageID: UUID) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, let requested = try libraryStore.load(id: packageID),
              let current = try libraryStore.latest(albumID: requested.stableAlbumID) else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true; defer { mutationInProgress = false }
        var additions: [PackageAsset]
        if let identifiers = selection.readablePhotoIdentifiers {
            additions = photoAssets(identifiers: identifiers)
            guard additions.allSatisfy({ $0.kind != nil }) else { throw PhotoPackageError.missingAsset }
            if current.linkedPhotosAlbumIdentifier != nil {
                guard try await SystemAlbumService.shared.add(assetIdentifiers: identifiers, to: current.stableAlbumID, title: current.displayTitle) != nil,
                      let members = try await SystemAlbumService.shared.members(albumID: current.stableAlbumID),
                      Set(identifiers).isSubset(of: Set(members)) else { throw PhotoPackageError.permission }
                additions = photoAssets(identifiers: members)
            }
        } else {
            additions = selection.items.map { selected in
                var item = PackageAsset(assetIdentifier: "picker:" + UUID().uuidString)
                item.kind = selected.kind; item.title = selected.provider.suggestedName
                item.pickerResourcePending = true; item.pickerAssetIdentifier = selected.assetIdentifier
                item.pickerSelectionItemID = selected.id
                return item
            }
        }
        var assets = current.assets
        var known = Set(assets.map(\.assetIdentifier))
        let pickerIDs = Set(assets.compactMap(\.pickerAssetIdentifier))
        for item in additions {
            if let local = item.pickerAssetIdentifier, pickerIDs.contains(local) || known.contains(local) { continue }
            if known.insert(item.assetIdentifier).inserted { assets.append(item) }
        }
        guard assets.count != current.assets.count else { return current }
        return try newSnapshot(from: current, assets: assets)
    }

    func add(fileURLs: [URL], to packageID: UUID) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, let requested = try libraryStore.load(id: packageID),
              let current = try libraryStore.latest(albumID: requested.stableAlbumID) else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true; defer { mutationInProgress = false }
        let additions = try await PackageFileAccess.scan(fileURLs)
        var assets = current.assets
        var paths = Set(assets.compactMap { $0.fileSource.flatMap { try? PackageFileAccess.resolve($0).file.standardizedFileURL.path } })
        for asset in additions {
            guard let source = asset.fileSource else { continue }
            let path = try PackageFileAccess.resolve(source).file.standardizedFileURL.path
            if paths.insert(path).inserted { assets.append(asset) }
        }
        guard assets.count != current.assets.count else { return current }
        return try newSnapshot(from: current, assets: assets)
    }

    func remove(assetIDs: [String], from packageID: UUID) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, let requested = try libraryStore.load(id: packageID),
              let current = try libraryStore.latest(albumID: requested.stableAlbumID) else { throw PackageModelError.invalidCheckpoint }
        mutationInProgress = true; defer { mutationInProgress = false }
        let ids = Set(assetIDs)
        let removed = current.assets.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return current }
        let photoIDs = removed.filter { $0.fileSource == nil && $0.pickerResourcePending != true }.map(\.assetIdentifier)
        if current.linkedPhotosAlbumIdentifier != nil, !photoIDs.isEmpty {
            guard try await SystemAlbumService.shared.remove(assetIdentifiers: photoIDs, from: current.stableAlbumID),
                  let members = try await SystemAlbumService.shared.members(albumID: current.stableAlbumID),
                  Set(photoIDs).isDisjoint(with: Set(members)) else { throw PhotoPackageError.permission }
        }
        return try newSnapshot(from: current, assets: current.assets.filter { !ids.contains($0.id) })
    }

    func rename(packageID: UUID, title: String) async throws -> PackageJob {
        guard runningID == nil, !mutationInProgress, let requested = try libraryStore.load(id: packageID),
              let current = try libraryStore.latest(albumID: requested.stableAlbumID) else {
            throw PackageModelError.invalidCheckpoint
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PackageModelError.invalidManifest }
        if trimmed == current.displayTitle { return current }
        if current.linkedPhotosAlbumIdentifier != nil {
            guard try await SystemAlbumService.shared.members(albumID: current.stableAlbumID) != nil else { throw PhotoPackageError.permission }
            try await SystemAlbumService.shared.rename(albumID: current.stableAlbumID, title: trimmed)
        }
        var revised = try newSnapshot(from: current, assets: current.assets, title: trimmed)
        revised.titleWasEdited = true
        try libraryStore.save(revised)
        return revised
    }

    private func photoAssets(identifiers: [String]) -> [PackageAsset] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return identifiers.map(PackageAsset.init) }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        return identifiers.map { identifier in
            var item = PackageAsset(assetIdentifier: identifier)
            if let asset = assets[identifier] {
                item.captureDate = asset.creationDate; item.sourceModifiedAt = asset.modificationDate
                item.kind = asset.mediaType == .video ? .video : .photo
                item.title = PHAssetResource.assetResources(for: asset).first?.originalFilename
            }
            return item
        }.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
    }

    private func newSnapshot(from previousJob: PackageJob, assets: [PackageAsset], title: String? = nil) throws -> PackageJob {
        // Historical journals can be opened directly without first activating
        // them. Complete their interrupted append rollback before retaining any
        // immutable checkpoint records in a new revision.
        var old = previousJob
        try rollbackIfNeeded(&old)
        try cleanupStaging(old)
        if !assets.isEmpty { try PackageFormatLimits.validateSelectionCount(assets.count) }
        let base = old.album ?? ShareAlbumMetadata(id: old.id, snapshotID: old.id,
            title: old.displayTitle, createdAt: old.createdAt)
        let metadata = try base.revised(title: title)
        var next = PackageJob(assetIdentifiers: assets.map(\.assetIdentifier))
        next.album = metadata; next.id = metadata.snapshotID
        next.phase = .draft; next.packagingRequested = false
        next.linkedPhotosAlbumIdentifier = old.linkedPhotosAlbumIdentifier
        next.titleWasEdited = old.titleWasEdited
        let oldIDs = Set(old.selectedAssetIdentifiers)
        let newIDs = Set(assets.map(\.assetIdentifier))
        next.addedAssetCount = newIDs.subtracting(oldIDs).count
        next.removedAssetCount = oldIDs.subtracting(newIDs).count
        let previous = Dictionary(uniqueKeysWithValues: old.assets.map { ($0.assetIdentifier, $0) })
        next.assets = assets.map { selected in
            var item = selected
            item.reuseSourcePackageID = nil
            if let prior = previous[item.assetIdentifier] {
                item.id = prior.id
                if unchanged(prior, item) {
                    item.reuseSourcePackageID = prior.isCompleted ? old.id : prior.reuseSourcePackageID
                }
            }
            item.manifestItem = nil; item.archiveRecords = []
            return item
        }
        next.archiveFilename = ShareAlbumNaming.safeFilename(title: metadata.title, extension: "dropack")
        try persistNew(next)
        for item in next.assets {
            guard let prior = previous[item.assetIdentifier], unchanged(prior, item),
                  let source = thumbnailURL(packageID: old.id, itemID: item.id),
                  let target = try? libraryStore.thumbnailURL(packageID: next.id, itemID: item.id) else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: target)
        }
        return next
    }

    private func persistNew(_ job: PackageJob) throws {
        try createEmptyArchive(job)
        do { try libraryStore.save(job) }
        catch { try? FileManager.default.removeItem(at: directory(job)); throw error }
        try libraryStore.select(job.id)
    }

    func deletePackage(id: UUID) throws {
        guard runningID == nil, !mutationInProgress else { throw PackageModelError.invalidCheckpoint }
        try prepareRoot()
        if let requested = try? libraryStore.load(id: id) {
            let snapshots = try libraryStore.allEntries().filter { $0.stableAlbumID == requested.stableAlbumID }
            for snapshot in snapshots { try libraryStore.delete(id: snapshot.id) }
        } else { try libraryStore.delete(id: id) }
    }

    func clear() throws {
        guard let id = try libraryStore.selectedID() else { return }
        try deletePackage(id: id)
    }

    func run(packageID: UUID, progress: @escaping @Sendable (PackageUpdate) -> Void) async throws -> PackageRestoration {
        guard runningID == nil, !mutationInProgress, var job = try libraryStore.load(id: packageID) else { throw PackageModelError.invalidCheckpoint }
        guard !job.assets.isEmpty else { throw PhotoPackageError.emptyAlbum }
        runningID = packageID
        defer { runningID = nil }
        try rollbackIfNeeded(&job)
        try cleanupStaging(job)
        try finalizePickerMetadata(&job)
        try libraryStore.save(job)
        try validateArchive(job)
        if job.phase == .ready { return PackageRestoration(job: job, archiveURL: archiveURL(job)) }
        do {
            try Task.checkCancellation()
            guard !job.assets.contains(where: { $0.pickerResourcePending == true }) else { throw PhotoPackageError.pickerReselection }
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard job.isFileAlbum || job.assets.allSatisfy({ $0.isCompleted || $0.reuseSourcePackageID != nil }) || status == .authorized || status == .limited else { throw PhotoPackageError.permission }
            job.phase = .packing; job.packagingRequested = true; job.lastMessage = nil
            try libraryStore.save(job)
            progress(PackageUpdate(job: job, stage: "读取原片", fraction: 0, name: ""))
            try cloneReusablePrefix(&job, progress: progress)
            var reuseJobs: [UUID: PackageJob] = [:]
            var reuseDirectories: [UUID: PackageZIPReuse.Source] = [:]
            var reuseAssets: [UUID: [String: PackageAsset]] = [:]
            for id in Set(job.assets.filter { !$0.isCompleted }.compactMap(\.reuseSourcePackageID)) {
                guard let source = try libraryStore.load(id: id) else { throw PhotoPackageError.archiveMismatch }
                try validateArchive(source)
                reuseJobs[id] = source
                reuseAssets[id] = Dictionary(uniqueKeysWithValues: source.assets.map { ($0.id, $0) })
                reuseDirectories[id] = try PackageZIPReuse.prepare(archiveURL(source), records: source.assets.flatMap(\.archiveRecords))
            }
            for index in job.assets.indices where !job.assets[index].isCompleted {
                try Task.checkCancellation()
                let selected = job.assets[index]
                if let reused = try reusableAsset(selected, for: job, source: selected.reuseSourcePackageID.flatMap { reuseJobs[$0] },
                    asset: selected.reuseSourcePackageID.flatMap { reuseAssets[$0]?[selected.id] }) {
                    try checkSpace(required: reused.asset.archiveRecords.reduce(safetyMargin) { $0.addingClamped($1.byteCount) }, at: directory(job))
                    try beginTransaction(&job)
                    var lastUpdate = -Double.infinity
                    guard let sourceDirectory = reuseDirectories[reused.job.id] else { throw PhotoPackageError.archiveMismatch }
                    try PackageZIPReuse.append(from: sourceDirectory, to: archiveURL(job),
                        records: reused.asset.archiveRecords, directoryBackup: backupURL(job)) { bytes, total in
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastUpdate >= 0.1 || bytes == total {
                            lastUpdate = now
                            let fraction = Double(bytes) / Double(max(1, total))
                            progress(PackageUpdate(job: nil, stage: "正在打包", fraction: fraction,
                                name: selected.title ?? "", assetID: selected.id, originalProgress: .ready, packingFraction: fraction))
                        }
                    }
                    var committed = job
                    committed.assets[index].manifestItem = reused.asset.manifestItem
                    committed.assets[index].archiveRecords = reused.asset.archiveRecords
                    committed.transaction = nil; committed.reuseStrategy = "raw-record-copy"
                    try libraryStore.save(committed); job = committed
                    try? FileManager.default.removeItem(at: backupURL(job))
                    progress(PackageUpdate(job: job, stage: "正在打包", fraction: 1, name: "", assetID: selected.id,
                        originalProgress: .ready, packingFraction: 1))
                    continue
                }
                var exported: ExportedAsset
                if selected.fileSource != nil {
                    exported = try await export(file: selected, progress: progress)
                } else {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [selected.assetIdentifier], options: nil)
                    guard let asset = assets.firstObject else { throw PhotoPackageError.missingAsset }
                    exported = try await export(asset: asset, itemID: selected.id, job: job, progress: progress)
                }
                defer {
                    for resource in exported.resources where resource.isTemporary { try? FileManager.default.removeItem(at: resource.url) }
                    if let access = exported.securityScope { access.stopAccessingSecurityScopedResource() }
                }
                try Task.checkCancellation()
                // A small preview travels with the package, so receiving a 30 GB
                // video can show its thumbnail without reading/decompressing it.
                await saveThumbnail(exported: exported, job: job)
                if let previewURL = thumbnailURL(packageID: job.id, itemID: selected.id),
                   let previewBytes = try? PackageRecovery.fileSize(previewURL), previewBytes <= 1024 * 1024 {
                    let path = "__dropack_previews/\(selected.id).preview"
                    exported.item.previewPath = path
                    exported.resources.append(ExportedResource(url: previewURL, path: path, byteCount: previewBytes,
                        hash: "", displayName: "缩略图", isTemporary: false))
                }
                try checkSpace(required: exported.totalBytes.addingClamped(safetyMargin), at: directory(job))
                try beginTransaction(&job)
                let records = try appendResources(exported.resources, job: job, assetID: selected.id,
                    originalProgress: exported.originalProgress, progress: progress)
                var committed = job
                committed.assets[index].manifestItem = exported.item
                committed.assets[index].archiveRecords = records
                committed.assets[index].title = exported.resources.first?.displayName
                committed.assets[index].kind = exported.item.photoPath == nil ? .video : .photo
                committed.transaction = nil
                try libraryStore.save(committed)
                job = committed
                try? FileManager.default.removeItem(at: backupURL(job))
                progress(PackageUpdate(job: job, stage: "正在打包", fraction: 1, name: "", assetID: selected.id,
                    originalProgress: exported.originalProgress, packingFraction: 1))
            }
            try Task.checkCancellation()
            progress(PackageUpdate(job: job, stage: "生成照片包清单", fraction: 0, name: ""))
            let manifest = PhotoPackageManifest(items: job.assets.compactMap(\.manifestItem), album: job.album)
            try manifest.validate()
            let manifestURL = directory(job).appendingPathComponent(PhotoPackageManifest.filename)
            defer { try? FileManager.default.removeItem(at: manifestURL) }
            let manifestData = try JSONEncoder().encode(manifest)
            try PackageFormatLimits.validateFinalization(
                resourceCount: job.assets.reduce(0) { $0 + $1.archiveRecords.count },
                manifestByteCount: UInt64(manifestData.count))
            try manifestData.write(to: manifestURL, options: .atomic)
            let bytes = try PackageRecovery.fileSize(manifestURL)
            try checkSpace(required: bytes.addingClamped(safetyMargin), at: directory(job))
            try beginTransaction(&job)
            let manifestResource = ExportedResource(url: manifestURL, path: PhotoPackageManifest.filename,
                                                    byteCount: bytes, hash: "", displayName: "照片包清单")
            let manifestRecord = try appendResources([manifestResource], job: job, progress: progress).first!
            var ready = job
            ready.phase = .ready; ready.transaction = nil; ready.manifestRecord = manifestRecord
            ready.finalizedSize = try PackageRecovery.fileSize(archiveURL(job)); ready.lastMessage = nil
            progress(PackageUpdate(job: job, stage: "核对照片包", fraction: 0, name: ""))
            try validateArchive(ready)
            try Task.checkCancellation()
            try libraryStore.save(ready)
            job = ready
            try? FileManager.default.removeItem(at: backupURL(job))
            return PackageRestoration(job: ready, archiveURL: archiveURL(ready))
        } catch {
            let initialError = error
            // Close ZIPFoundation before restoring the saved tail; appendResources has returned by here.
            do {
                try rollbackIfNeeded(&job)
                try cleanupStaging(job)
                job.phase = (initialError is CancellationError) ? .paused : .failed
                job.lastMessage = (initialError is CancellationError)
                    ? "打包已暂停，已完成的照片已保留。继续时会重新读取当前未完成的一项。"
                    : initialError.localizedDescription
                try libraryStore.save(job)
                progress(PackageUpdate(job: job, stage: "", fraction: 0, name: ""))
            } catch {
                // Never clear a transaction marker if rollback or checkpoint persistence failed.
                throw PackageModelError.missingRollback
            }
            throw initialError
        }
    }

    private func reusableAsset(_ selected: PackageAsset, for job: PackageJob, source cachedSource: PackageJob? = nil, asset cachedAsset: PackageAsset? = nil) throws -> (job: PackageJob, asset: PackageAsset)? {
        guard let id = selected.reuseSourcePackageID else { return nil }
        guard id != job.id, let source = try cachedSource ?? libraryStore.load(id: id), source.stableAlbumID == job.stableAlbumID,
              let asset = cachedAsset ?? source.assets.first(where: { $0.id == selected.id }), asset.isCompleted,
              unchanged(asset, selected) else { throw PhotoPackageError.archiveMismatch }
        // Detect an available source changing after draft creation. Never pass a
        // newly changed file off as the cached old bytes.
        guard unchanged(selected, try refreshFileMetadata(selected)) else { throw MediaSourceError.itemChanged(selected.title ?? "") }
        return (source, asset)
    }

    private func cloneReusablePrefix(_ job: inout PackageJob, progress: @escaping @Sendable (PackageUpdate) -> Void) throws {
        guard job.completedCount == 0 else { return }
        let ids = Set(job.assets.compactMap(\.reuseSourcePackageID))
        guard ids.count == 1, let id = ids.first, let source = try libraryStore.load(id: id), source.phase == .ready,
              let manifest = source.manifestRecord, !source.assets.isEmpty else { return }
        let candidates = job.assets.filter { $0.reuseSourcePackageID == id }
        guard candidates.count == source.assets.count, Set(candidates.map(\.id)) == Set(source.assets.map(\.id)) else { return }
        let originalAssets = Dictionary(uniqueKeysWithValues: source.assets.map { ($0.id, $0) })
        for item in candidates { _ = try reusableAsset(item, for: job, source: source, asset: originalAssets[item.id]) }
        try validateArchive(source)
        let temporary = directory(job).appendingPathComponent("reuse-clone.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try? FileManager.default.removeItem(at: temporary)
        guard try PackageZIPReuse.cloneRemovingLastManifest(from: archiveURL(source), to: temporary,
            retained: source.assets.flatMap(\.archiveRecords), manifest: manifest) else { return }
        try beginTransaction(&job)
        // Atomic rename of an independent clone. A crash before the following
        // journal save rolls the clone back to the original empty ZIP tail.
        guard Darwin.rename(temporary.path, archiveURL(job).path) == 0 else { throw PhotoPackageError.disk("无法提交更新包。") }
        var committed = job
        let sourceAssets = Dictionary(uniqueKeysWithValues: source.assets.map { ($0.id, $0) })
        for index in committed.assets.indices {
            if let old = sourceAssets[committed.assets[index].id] {
                committed.assets[index].manifestItem = old.manifestItem
                committed.assets[index].archiveRecords = old.archiveRecords
            }
        }
        committed.transaction = nil; committed.reuseStrategy = "apfs-clone"
        try libraryStore.save(committed); job = committed
        try? FileManager.default.removeItem(at: backupURL(job))
        progress(PackageUpdate(job: job, stage: "正在打包", fraction: 0, name: ""))
    }

    nonisolated func thumbnailURL(packageID: UUID, itemID: String) -> URL? {
        guard let url = try? libraryStore.thumbnailURL(packageID: packageID, itemID: itemID),
              ((try? PackageRecovery.fileSize(url)) ?? 0) > 0 else { return nil }
        return url
    }

    /// The grid and task cover can request the same item together. Share one
    /// decoder, and briefly remember unsupported/temporarily unavailable media
    /// so share-sheet state changes cannot repeatedly restart video decoding.
    func loadThumbnail(packageID: UUID, itemID: String) async -> URL? {
        if let url = thumbnailURL(packageID: packageID, itemID: itemID) { return url }
        guard !Task.isCancelled, let job = try? libraryStore.load(id: packageID),
              let item = job.assets.first(where: { $0.id == itemID }) else { return nil }
        let key = ThumbnailKey(packageID: packageID, itemID: itemID)
        let source = ThumbnailSource(item)
        let now = thumbnailClock()
        thumbnailFailures = thumbnailFailures.filter { $0.value.retryAt > now }
        if let failed = thumbnailFailures[key], failed.source == source { return nil }
        // A privately captured picker source can become available in the same
        // draft. Its older request must settle before decoding the new original.
        if let older = thumbnailTasks[key], older.source != source || older.task.isCancelled {
            _ = await older.task.value
            guard !Task.isCancelled else { return nil }
            return await loadThumbnail(packageID: packageID, itemID: itemID)
        }
        let waiter = UUID()
        let request: ThumbnailRequest
        if var existing = thumbnailTasks[key] {
            existing.waiters.insert(waiter)
            thumbnailTasks[key] = existing
            request = existing
        } else {
            let requestID = UUID()
            let task = Task { [self] in
                let result = await generateThumbnail(key: key, item: item, source: source)
                finishThumbnail(key: key, requestID: requestID, source: source,
                                failed: result == nil && !Task.isCancelled)
                return result
            }
            request = ThumbnailRequest(id: requestID, source: source, task: task, waiters: [waiter])
            thumbnailTasks[key] = request
        }
        return await withTaskCancellationHandler {
            let result = await request.task.value
            releaseThumbnailWaiter(key: key, requestID: request.id, waiter: waiter)
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { await self.releaseThumbnailWaiter(key: key, requestID: request.id, waiter: waiter) }
        }
    }

    private func releaseThumbnailWaiter(key: ThumbnailKey, requestID: UUID, waiter: UUID) {
        guard var request = thumbnailTasks[key], request.id == requestID else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty { request.task.cancel() }
        thumbnailTasks[key] = request
    }

    private func finishThumbnail(key: ThumbnailKey, requestID: UUID, source: ThumbnailSource, failed: Bool) {
        guard thumbnailTasks[key]?.id == requestID else { return }
        thumbnailTasks.removeValue(forKey: key)
        guard failed else { thumbnailFailures.removeValue(forKey: key); return }
        if thumbnailFailures.count >= 128,
           let oldest = thumbnailFailures.min(by: { $0.value.retryAt < $1.value.retryAt })?.key {
            thumbnailFailures.removeValue(forKey: oldest)
        }
        thumbnailFailures[key] = ThumbnailFailure(source: source, retryAt: thumbnailClock() + 60)
    }

    private func generateThumbnail(key: ThumbnailKey, item: PackageAsset, source identity: ThumbnailSource) async -> URL? {
        // Lazy-grid tasks wait for a slot instead of permanently becoming a
        // placeholder just because four adjacent cells started first.
        while thumbnailRequests >= 4 {
            do { try await Task.sleep(nanoseconds: 40_000_000) }
            catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let url = thumbnailURL(packageID: key.packageID, itemID: key.itemID) { return url }
        thumbnailRequests += 1
        defer { thumbnailRequests -= 1 }
        if let source = item.fileSource, let kind = item.kind,
           let location = try? PackageFileAccess.resolve(source) {
            let scoped = location.root.startAccessingSecurityScopedResource()
            defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
            guard let image = await thumbnailLoader.thumbnail(fileURL: location.file, kind: kind),
                  !Task.isCancelled, thumbnailSourceMatches(key, identity) else { return nil }
            return thumbnailURL(packageID: key.packageID, itemID: key.itemID)
                ?? writeThumbnail(image, packageID: key.packageID, itemID: key.itemID)
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let request = PackagePhotoThumbnailRequest()
        guard let image = await request.image(asset: asset), !Task.isCancelled,
              thumbnailSourceMatches(key, identity) else { return nil }
        return thumbnailURL(packageID: key.packageID, itemID: key.itemID)
            ?? writeThumbnail(image, packageID: key.packageID, itemID: key.itemID)
    }

    private func thumbnailSourceMatches(_ key: ThumbnailKey, _ expected: ThumbnailSource) -> Bool {
        guard let current = try? libraryStore.load(id: key.packageID),
              let item = current.assets.first(where: { $0.id == key.itemID }) else { return false }
        return ThumbnailSource(item) == expected
    }

    private func saveThumbnail(exported: ExportedAsset, job: PackageJob) async {
        guard !Task.isCancelled,
              let resource = exported.resources.first(where: { $0.path == exported.item.photoPath }) ?? exported.resources.first,
              let kind = MediaPolicy.kind(for: resource.path),
              let image = await thumbnailLoader.thumbnail(fileURL: resource.url, kind: kind),
              !Task.isCancelled else { return }
        _ = writeThumbnail(image, packageID: job.id, itemID: exported.item.id)
    }

    private func writeThumbnail(_ image: CGImage, packageID: UUID, itemID: String) -> URL? {
        // All input bitmaps are already <= 360px. Never read an original resource
        // into Data, and a failed preview must not affect the archive transaction.
        guard image.width <= MediaThumbnailLoader.maximumPixelSize,
              image.height <= MediaThumbnailLoader.maximumPixelSize,
              let destination = try? libraryStore.thumbnailURL(packageID: packageID, itemID: itemID) else { return nil }
        let temporary = destination.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let encoder = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { return nil }
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch { return nil }
    }

    private struct ExportedResource {
        var url: URL
        var path: String
        var byteCount: UInt64
        var hash: String
        var displayName: String
        var isTemporary = true
        var source: PackageFileSource?
    }
    private struct ExportedAsset {
        var item: PhotoPackageManifestItem
        var resources: [ExportedResource]
        var securityScope: URL?
        var originalProgress: PackageOriginalProgress = .ready
        var totalBytes: UInt64 { resources.reduce(0) { $0.addingClamped($1.byteCount) } }
    }

    private func export(asset: PHAsset, itemID: String, job: PackageJob,
                        progress: @escaping @Sendable (PackageUpdate) -> Void) async throws -> ExportedAsset {
        let available = PHAssetResource.assetResources(for: asset)
        let isLive = asset.mediaSubtypes.contains(.photoLive)
        var chosen: [(PHAssetResource, MediaKind, String)] = []
        if asset.mediaType == .image {
            guard let photo = available.first(where: { $0.type == .photo }) else {
                throw PhotoPackageError.unsupported("照片")
            }
            chosen.append((photo, .photo, "original"))
            if isLive {
                guard let paired = available.first(where: { $0.type == .pairedVideo }) else {
                    throw PhotoPackageError.unsupported("实况照片")
                }
                chosen.append((paired, .video, "paired"))
            }
        } else if asset.mediaType == .video {
            guard let video = available.first(where: { $0.type == .video }) else {
                throw PhotoPackageError.unsupported("视频")
            }
            chosen.append((video, .video, "original"))
        } else { throw PhotoPackageError.unsupported("所选项目") }
        let staging = stagingURL(job)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var item = PhotoPackageManifestItem(id: itemID, creationDate: asset.creationDate, isLivePhoto: isLive)
        var output: [ExportedResource] = []
        let originals = PackageOriginalProgressTracker(resourceCount: chosen.count)
        do {
            for (resourceIndex, chosenResource) in chosen.enumerated() {
                let (resource, kind, stem) = chosenResource
                try Task.checkCancellation()
                try checkSpace(required: safetyMargin, at: directory(job))
                var ext = (resource.originalFilename as NSString).pathExtension.lowercased()
                if MediaPolicy.kind(for: "file.\(ext)") != kind {
                    ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? ""
                }
                guard MediaPolicy.kind(for: "file.\(ext)") == kind else {
                    throw PhotoPackageError.unsupported(resource.originalFilename)
                }
                let path = "media/\(itemID)/\(stem).\(ext)"
                let destination = staging.appendingPathComponent("\(itemID)-\(stem).\(ext)")
                let name = resource.originalFilename
                originals.report(resource: resourceIndex) { original in
                    progress(PackageUpdate(job: nil, stage: original.state == .downloading ? "从 iCloud 下载" : "读取原片",
                        fraction: original.state == .ready ? 1 : (original.fraction ?? 0), name: name, readBytes: 0,
                        assetID: itemID, originalProgress: original))
                }
                let result = try await PhotoResourceLocalFirst.export(destination: destination, safetyMargin: safetyMargin,
                    onNetworkRequired: {
                        originals.report(resource: resourceIndex, cloudConfirmed: true) { original in
                            progress(PackageUpdate(job: nil, stage: "从 iCloud 下载", fraction: original.state == .ready ? 1 : (original.fraction ?? 0),
                                name: name, assetID: itemID, originalProgress: original))
                        }
                    }) { stream, networkAllowed in
                    try await stream.export(resource: resource, isNetworkAccessAllowed: networkAllowed,
                        readProgress: { bytes in
                            originals.report(resource: resourceIndex) { original in
                                progress(PackageUpdate(job: nil,
                                    stage: original.state == .downloading ? "从 iCloud 下载" : "读取原片",
                                    fraction: original.state == .ready ? 1 : (original.fraction ?? 0), name: name, readBytes: bytes,
                                    assetID: itemID, originalProgress: original))
                            }
                        }) { fraction in
                            originals.report(resource: resourceIndex, fraction: fraction,
                                cloudConfirmed: networkAllowed) { original in
                                progress(PackageUpdate(job: nil,
                                    stage: original.state == .downloading ? "从 iCloud 下载" : "读取原片",
                                    fraction: original.state == .ready ? 1 : (original.fraction ?? 0), name: name,
                                    assetID: itemID, originalProgress: original))
                            }
                        }
                }
                guard result.byteCount > 0 else { throw PhotoPackageError.emptyResource(name) }
                output.append(ExportedResource(url: destination, path: path, byteCount: result.byteCount,
                                               hash: result.hash, displayName: name))
                if kind == .photo { item.photoPath = path; item.photoSHA256 = result.hash }
                else { item.videoPath = path; item.videoSHA256 = result.hash }
                originals.report(resource: resourceIndex, completed: true) { original in
                    progress(PackageUpdate(job: nil,
                        stage: original.state == .ready ? "原片已就绪" : (original.state == .downloading ? "从 iCloud 下载" : "读取原片"),
                        fraction: original.state == .ready ? 1 : (original.fraction ?? 0), name: name,
                        assetID: itemID, originalProgress: original))
                }
            }
            return ExportedAsset(item: item, resources: output, originalProgress: originals.snapshot)
        } catch {
            try? cleanupStaging(job)
            throw error
        }
    }

    private func export(file selected: PackageAsset,
                        progress: @escaping @Sendable (PackageUpdate) -> Void) async throws -> ExportedAsset {
        guard let source = selected.fileSource, let kind = selected.kind else { throw PackageModelError.invalidCheckpoint }
        let location = try PackageFileAccess.resolve(source)
        let scoped = location.root.startAccessingSecurityScopedResource()
        let originals = PackageOriginalProgressTracker(resourceCount: selected.pairedFileSource == nil ? 1 : 2)
        do {
            // File hashing may take minutes for camera videos. Let the actor
            // serve bounded thumbnail requests while this stream runs off-actor.
            let hashing = Task.detached(priority: .utility) {
                try PackageFileAccess.coordinate(location.file) { file in
                    try PackageFileAccess.validate(file, source: source)
                    originals.report(resource: 0) { original in
                        progress(PackageUpdate(job: nil, stage: "核对文件", fraction: 0,
                            name: selected.title ?? "", assetID: selected.id, originalProgress: original))
                    }
                    return try PackageFileAccess.hash(file, byteCount: source.byteCount) { fraction in
                        originals.report(resource: 0, fraction: fraction) { original in
                            progress(PackageUpdate(job: nil, stage: "核对文件", fraction: original.state == .ready ? 1 : (original.fraction ?? 0),
                                name: selected.title ?? "", assetID: selected.id, originalProgress: original))
                        }
                    }
                }
            }
            let hash = try await withTaskCancellationHandler {
                try await hashing.value
            } onCancel: { hashing.cancel() }
            originals.report(resource: 0, completed: true) { original in
                progress(PackageUpdate(job: nil, stage: "核对文件", fraction: original.state == .ready ? 1 : (original.fraction ?? 0),
                    name: selected.title ?? "", assetID: selected.id, originalProgress: original))
            }
            let path = "media/\(selected.id)/original.\(location.file.pathExtension.lowercased())"
            var item = PhotoPackageManifestItem(id: selected.id, creationDate: selected.captureDate)
            if kind == .photo { item.photoPath = path; item.photoSHA256 = hash }
            else { item.videoPath = path; item.videoSHA256 = hash }
            let resource = ExportedResource(url: location.file, path: path, byteCount: source.byteCount,
                hash: hash, displayName: selected.title ?? location.file.lastPathComponent,
                isTemporary: false, source: source)
            var resources = [resource]
            if let pairedSource = selected.pairedFileSource {
                let pairedLocation = try PackageFileAccess.resolve(pairedSource)
                let pairedHashing = Task.detached(priority: .utility) {
                    try PackageFileAccess.coordinate(pairedLocation.file) { file in
                        try PackageFileAccess.validate(file, source: pairedSource)
                        return try PackageFileAccess.hash(file, byteCount: pairedSource.byteCount) { fraction in
                            originals.report(resource: 1, fraction: fraction) { original in
                                progress(PackageUpdate(job: nil, stage: "核对实况视频", fraction: original.state == .ready ? 1 : (original.fraction ?? 0),
                                    name: selected.title ?? "", assetID: selected.id, originalProgress: original))
                            }
                        }
                    }
                }
                let pairedHash = try await withTaskCancellationHandler { try await pairedHashing.value }
                    onCancel: { pairedHashing.cancel() }
                originals.report(resource: 1, completed: true) { original in
                    progress(PackageUpdate(job: nil, stage: "核对实况视频", fraction: original.state == .ready ? 1 : (original.fraction ?? 0),
                        name: selected.title ?? "", assetID: selected.id, originalProgress: original))
                }
                let pairedPath = "media/\(selected.id)/paired.\(pairedLocation.file.pathExtension.lowercased())"
                item.videoPath = pairedPath; item.videoSHA256 = pairedHash; item.isLivePhoto = true
                resources.append(ExportedResource(url: pairedLocation.file, path: pairedPath, byteCount: pairedSource.byteCount,
                    hash: pairedHash, displayName: selected.title ?? "实况视频", isTemporary: false, source: pairedSource))
            }
            return ExportedAsset(item: item, resources: resources, securityScope: scoped ? location.root : nil,
                                 originalProgress: originals.snapshot)
        } catch {
            if scoped { location.root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func appendResources(_ resources: [ExportedResource], job: PackageJob, assetID: String? = nil,
                                 originalProgress: PackageOriginalProgress? = nil,
                                 progress: @escaping @Sendable (PackageUpdate) -> Void) throws -> [PackageArchiveRecord] {
        let archive = try Archive(url: archiveURL(job), accessMode: .update)
        var records: [PackageArchiveRecord] = []
        let totalBytes = resources.reduce(UInt64(0)) { $0.addingClamped($1.byteCount) }
        var completedBytes: UInt64 = 0
        for resource in resources {
            try Task.checkCancellation()
            guard resource.byteCount <= UInt64(Int64.max) else { throw PhotoPackageError.archiveMismatch }
            try PackageFileAccess.coordinate(resource.url) { coordinatedURL in
            if let source = resource.source { try PackageFileAccess.validate(coordinatedURL, source: source) }
            let input = try FileHandle(forReadingFrom: coordinatedURL)
            defer { try? input.close() }
            var lastProgress = -Double.infinity
            var archivedHasher = SHA256()
            let name = resource.displayName
            let initialFraction = Double(completedBytes) / Double(max(1, totalBytes))
            progress(PackageUpdate(job: nil, stage: "正在打包", fraction: initialFraction, name: name,
                assetID: assetID, originalProgress: originalProgress,
                packingFraction: assetID == nil ? nil : initialFraction))
            try archive.addEntry(with: resource.path, type: .file, uncompressedSize: Int64(resource.byteCount),
                                 compressionMethod: .none, bufferSize: chunkSize) { position, count in
                // The returned Swift Data owns this one chunk after the pool
                // drains; Cocoa temporaries never accumulate over the ZIP write.
                try autoreleasepool {
                    try Task.checkCancellation()
                    try input.seek(toOffset: UInt64(position))
                    guard let data = try input.read(upToCount: count), data.count == count else {
                        throw PhotoPackageError.archiveMismatch
                    }
                    archivedHasher.update(data: data)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.1 {
                        lastProgress = now
                        let aggregate = min(1, Double(completedBytes.addingClamped(UInt64(position + Int64(data.count)))) / Double(max(1, totalBytes)))
                        progress(PackageUpdate(job: nil, stage: "正在打包", fraction: aggregate, name: name,
                            assetID: assetID, originalProgress: originalProgress,
                            packingFraction: assetID == nil ? nil : aggregate))
                    }
                    return data
                }
            }
            try Task.checkCancellation()
            let archivedHash = archivedHasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard resource.hash.isEmpty || resource.hash == archivedHash else { throw PhotoPackageError.archiveMismatch }
            guard let entry = archive[resource.path], entry.uncompressedSize == resource.byteCount else {
                throw PhotoPackageError.archiveMismatch
            }
            records.append(PackageArchiveRecord(path: resource.path, byteCount: resource.byteCount, checksum: entry.checksum))
            completedBytes = completedBytes.addingClamped(resource.byteCount)
            }
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forWritingTo: archiveURL(job))
        defer { try? handle.close() }
        try handle.synchronize()
        try Task.checkCancellation()
        return records
    }

    private func beginTransaction(_ job: inout PackageJob) throws {
        guard job.transaction == nil else { throw PackageModelError.invalidCheckpoint }
        let transaction = try PackageRecovery.snapshot(archive: archiveURL(job), backup: backupURL(job))
        var changed = job
        changed.transaction = transaction
        try libraryStore.save(changed)
        job = changed
    }

    private func rollbackIfNeeded(_ job: inout PackageJob) throws {
        guard let transaction = job.transaction else { return }
        try PackageRecovery.rollback(transaction, archive: archiveURL(job), backup: backupURL(job))
        var restored = job
        restored.transaction = nil
        restored.phase = .paused
        try libraryStore.save(restored)
        job = restored
        try? FileManager.default.removeItem(at: backupURL(job))
    }

    private func validateArchive(_ job: PackageJob) throws {
        try job.validate()
        guard job.transaction == nil else { throw PackageModelError.missingRollback }
        let url = archiveURL(job)
        let size = try PackageRecovery.fileSize(url)
        if job.phase == .ready, size != job.finalizedSize { throw PhotoPackageError.archiveMismatch }
        let directory = try ZipDirectoryValidator.validate(url: url, byteCount: size)
        let records = job.assets.flatMap(\.archiveRecords) + [job.manifestRecord].compactMap { $0 }
        guard directory.entryCount == UInt64(records.count) else { throw PhotoPackageError.archiveMismatch }
        let expected = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        let archive = try Archive(url: url, accessMode: .read)
        var seen = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file, seen.insert(entry.path).inserted,
                  let record = expected[entry.path], record.byteCount == entry.uncompressedSize,
                  record.checksum == entry.checksum else { throw PhotoPackageError.archiveMismatch }
        }
        guard seen.count == records.count else { throw PhotoPackageError.archiveMismatch }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try libraryStore.prepare()
    }
    private func createEmptyArchive(_ job: PackageJob) throws {
        try FileManager.default.createDirectory(at: directory(job), withIntermediateDirectories: true)
        try checkSpace(required: safetyMargin, at: directory(job))
        _ = try Archive(url: archiveURL(job), accessMode: .create)
    }
    private func cleanupStaging(_ job: PackageJob) throws {
        let staging = stagingURL(job)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
    }
    private func directory(_ job: PackageJob) -> URL { root.appendingPathComponent(job.id.uuidString, isDirectory: true) }
    private func archiveURL(_ job: PackageJob) -> URL { directory(job).appendingPathComponent(job.archiveFilename) }
    private func stagingURL(_ job: PackageJob) -> URL { directory(job).appendingPathComponent("Staging", isDirectory: true) }
    private func backupURL(_ job: PackageJob) -> URL { directory(job).appendingPathComponent("directory-backup.bin") }
    private func checkSpace(required: UInt64, at directory: URL) throws {
        try PhotoResourceStream.checkSpace(required: required, at: directory)
    }
}

/// Bounded, cancellable PhotoKit previews for legacy packages only. Network
/// downloads are disabled: missing originals/permissions use the UI placeholder.
private final class PackagePhotoThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let manager = PHImageManager()
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false

    func image(asset: PHAsset) async -> CGImage? {
        await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { await self.request(asset: asset) }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func request(asset: PHAsset) async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished { lock.unlock(); continuation.resume(returning: nil); return }
                self.continuation = continuation
                lock.unlock()
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.isNetworkAccessAllowed = false
                let maximum = MediaThumbnailLoader.maximumPixelSize
                let id = manager.requestImage(for: asset, targetSize: CGSize(width: maximum, height: maximum),
                                              contentMode: .aspectFit, options: options) { [weak self] image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    self?.finish(image: image?.cgImage)
                }
                lock.lock()
                let shouldCancel = finished
                if !finished { requestID = id }
                lock.unlock()
                if shouldCancel { manager.cancelImageRequest(id) }
            }
        } onCancel: { self.finish(image: nil) }
    }

    private func finish(image: CGImage?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        continuation?.resume(returning: image)
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let sum = addingReportingOverflow(other)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}

/// An actual local export is the availability probe. Only PhotoKit's precise
/// network-required error admits a second request; all other failures propagate.
enum PhotoResourceLocalFirst {
    static func export(
        destination: URL, safetyMargin: UInt64,
        onNetworkRequired: @escaping @Sendable () -> Void,
        request: (PhotoResourceStream, Bool) async throws -> PhotoResourceStream.Result
    ) async throws -> PhotoResourceStream.Result {
        try Task.checkCancellation()
        do {
            let local = try PhotoResourceStream(destination: destination, safetyMargin: safetyMargin)
            return try await request(local, false)
        } catch {
            try Task.checkCancellation()
            let photoError = error as NSError
            guard photoError.domain == PHPhotosErrorDomain,
                  photoError.code == PHPhotosError.Code.networkAccessRequired.rawValue else { throw error }
            // Awaiting the failed stream guarantees every accepted callback and
            // local write has ended. A new stream truncates any partial bytes.
            onNetworkRequired()
            try Task.checkCancellation()
            let remote = try PhotoResourceStream(destination: destination, safetyMargin: safetyMargin)
            return try await request(remote, true)
        }
    }
}

/// One asset can require a still and paired video. Progress is serialized and
/// ordered across resources. Fractions describe the current resource only; a
/// local still must never count as 50% of an iCloud video's download. One 100%
/// callback never declares the asset ready. Only completed exports can do that.
final class PackageOriginalProgressTracker: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let resourceCount: Int
    private var completed = Set<Int>()
    private var currentResource = -1
    private var cloudConfirmed = false
    private var state: PackageOriginalProgress.State = .preparing
    private var fraction: Double?

    init(resourceCount: Int) { self.resourceCount = max(1, resourceCount) }

    var snapshot: PackageOriginalProgress {
        lock.lock(); defer { lock.unlock() }
        return currentSnapshot()
    }

    func report(resource: Int, fraction resourceFraction: Double? = nil,
                cloudConfirmed detectedCloud: Bool = false, completed isComplete: Bool = false,
                _ emit: (PackageOriginalProgress) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard (0..<resourceCount).contains(resource), completed.count < resourceCount,
              resource >= currentResource, !completed.contains(resource) else { return }
        if resource != currentResource {
            currentResource = resource
            state = .preparing
            fraction = nil
        }
        cloudConfirmed = cloudConfirmed || detectedCloud
        if detectedCloud && state != .downloading {
            state = .downloading
            // The failed local read did not download anything. Wait for the
            // network request's own fraction instead of carrying local progress.
            fraction = nil
        }
        if let resourceFraction, resourceFraction.isFinite {
            fraction = max(fraction ?? 0, min(1, max(0, resourceFraction)))
        }
        if isComplete {
            completed.insert(resource)
            state = completed.count == resourceCount ? .ready : .preparing
            fraction = nil
        }
        // Invoke synchronously in report order. The callback only delivers a
        // lightweight progress value and never performs source I/O or awaits.
        emit(currentSnapshot())
    }

    private func currentSnapshot() -> PackageOriginalProgress {
        return .init(state: state, fraction: fraction,
                     cloudConfirmed: cloudConfirmed)
    }
}

/// PhotoKit streams each resource into a file. A lock protects callback/cancellation races;
/// no whole-photo/video Data is accumulated, and a transfer owns at most one PhotoKit request.
final class PhotoResourceStream: @unchecked Sendable {
    struct Result: Sendable { var byteCount: UInt64; var hash: String }
    private let lock = NSLock()
    private let destination: URL
    private let safetyMargin: UInt64
    private let handle: FileHandle
    private lazy var completion = CancellableCallbackOperation<Void> { [weak self] result in
        self?.close(result) ?? result
    }
    private var received: UInt64 = 0
    private var checkedAt: UInt64 = 0
    private var hasher = SHA256()
    private var readProgressThrottle = ReadByteProgressThrottle()

    init(destination: URL, safetyMargin: UInt64) throws {
        self.destination = destination; self.safetyMargin = safetyMargin
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw PhotoPackageError.disk("")
        }
        handle = try FileHandle(forWritingTo: destination)
        do { try handle.truncate(atOffset: 0) }
        catch { try? handle.close(); throw error }
    }

    func export(resource: PHAssetResource, isNetworkAccessAllowed: Bool = false,
                readProgress: @escaping @Sendable (UInt64) -> Void = { _ in },
                progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        _ = self.completion
        return try await export(readProgress: readProgress) { receive, finish in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = isNetworkAccessAllowed
            options.progressHandler = { fraction in
                // Accepted progress work must finish before this resource can
                // settle and start its successor (especially Live Photo pairs).
                self.reportProgress(fraction, progress: progress)
            }
            let manager = PHAssetResourceManager.default()
            let id = manager.requestData(for: resource, options: options,
                dataReceivedHandler: receive, completionHandler: finish)
            return { manager.cancelDataRequest(id) }
        }
    }

    func reportProgress(_ fraction: Double, progress: @Sendable (Double) -> Void) {
        completion.process { progress(min(1, max(0, fraction))) }
    }

    /// The adapter also lets regression tests model PhotoKit's missing or late
    /// completions without touching a user's photo library.
    func export(readProgress: @escaping @Sendable (UInt64) -> Void = { _ in },
                start: (@escaping (Data) -> Void, @escaping (Error?) -> Void) -> (() -> Void)) async throws -> Result {
        // Initialize before entering the cancellation handler: lazy setup must
        // not race a framework callback.
        let completion = self.completion
        try await completion.wait {
            let terminate = start({ [self] data in receive(data, readProgress: readProgress) }, { error in
                if let error { completion.finish(.failure(error)) }
                else { completion.finish(.success(())) }
            })
            completion.registerTermination(terminate)
        }
        // No writes remain after the coordinator returns. Flush the exact final
        // count even if the last chunk fell inside the reporting interval.
        if let bytes = readProgressThrottle.update(readBytes: received,
            now: ProcessInfo.processInfo.systemUptime, force: true) { readProgress(bytes) }
        return Result(byteCount: received, hash: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func receive(_ data: Data, readProgress: @Sendable (UInt64) -> Void) {
        completion.process {
            let report: UInt64?
            do {
                lock.lock(); defer { lock.unlock() }
                // A callback queued behind another chunk may have been cancelled
                // meanwhile. It must not append data to a retired staging file.
                guard !completion.isCancelled else { throw CancellationError() }
                try autoreleasepool {
                    if received - checkedAt >= 64 * 1024 * 1024 || received == 0 {
                        try Self.checkSpace(required: safetyMargin.addingClamped(UInt64(data.count)), at: destination.deletingLastPathComponent())
                        checkedAt = received
                    }
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    received = received.addingClamped(UInt64(data.count))
                }
                report = readProgressThrottle.update(readBytes: received, now: ProcessInfo.processInfo.systemUptime)
            }
            // A UI callback may cancel the task. Never invoke it with the file
            // lock held; the coordinator still owns this accepted callback.
            if let report, !completion.isCancelled { readProgress(report) }
        }
    }

    private func close(_ result: Swift.Result<Void, Error>) -> Swift.Result<Void, Error> {
        // The coordinator reaches this point only after every accepted write
        // returns. PhotoKit completion is not needed on cancellation or failure.
        var result = result
        if case .success = result {
            do { try handle.synchronize() } catch { result = .failure(error) }
        }
        do { try handle.close() } catch {
            if case .success = result { result = .failure(error) }
        }
        return result
    }

    static func checkSpace(required: UInt64, at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available: UInt64
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 { available = UInt64(capacity) }
        else if let capacity = values.volumeAvailableCapacity, capacity >= 0 { available = UInt64(capacity) }
        else { throw PhotoPackageError.disk("无法确认剩余空间。") }
        guard available >= required else { throw PhotoPackageError.insufficientSpace(required, available) }
    }
}
