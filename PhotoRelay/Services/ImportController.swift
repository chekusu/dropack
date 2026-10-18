import Combine
import Foundation
import UIKit
import CryptoKit

@MainActor
final class ImportController: ObservableObject {
    @Published private(set) var job: ImportJob?
    @Published private(set) var isPreparing = false
    @Published private(set) var isBusy = false
    let activity = ImportActivity()
    @Published private(set) var library: [ImportJob] = []
    private var oneTimeImports: [ImportJob] = []
    private(set) var currentFile: String { get { activity.currentFile } set { activity.currentFile = newValue } }
    private(set) var currentFraction: Double { get { activity.currentFraction } set { activity.currentFraction = newValue } }
    private(set) var currentStage: String { get { activity.currentStage } set { activity.currentStage = newValue } }
    private(set) var currentReadBytes: UInt64 { get { activity.currentReadBytes } set { activity.currentReadBytes = newValue } }
    private(set) var currentTotalBytes: UInt64 { get { activity.currentTotalBytes } set { activity.currentTotalBytes = newValue } }
    private(set) var isSavingToPhotos: Bool { get { activity.isSavingToPhotos } set { activity.isSavingToPhotos = newValue } }
    private(set) var activePreview: ImportPreview? { get { activity.activePreview } set { activity.activePreview = newValue } }
    private(set) var recentSavedPreviews: [ImportPreview] { get { activity.recentSavedPreviews } set { activity.recentSavedPreviews = newValue } }
    private(set) var savedPreviewSequence: UInt64 { get { activity.savedPreviewSequence } set { activity.savedPreviewSequence = newValue } }
    var lastSavedPreview: ImportPreview? { activity.lastSavedPreview }
    @Published var message: String?
    @Published private(set) var needsRelink = false
    @Published private(set) var requiresReset = false
    @Published private(set) var scannedCount = 0
    @Published var delaySeconds: Double = 0.5 {
        didSet { updateDelay() }
    }

    private let sourceService: MediaSourceService
    private let photoWriter: any PhotoLibraryWriting
    private let checkpoint: CheckpointStore
    private let receivedStore: ReceivedAlbumStore
    private let receivedThumbnails: ReceivedThumbnailService
    private let history: ImportHistoryWorker
    private let contentHasher = ImportContentHasher()
    private let thumbnailLoader = MediaThumbnailLoader()
    private var thumbnailWorker: Task<CGImage?, Never>?
    private var previewGeneration = UUID()
    private var worker: Task<Void, Never>?
    private var delayPersistenceTask: Task<Void, Never>?
    private var isCleaningUp = false
    private var isRestoring = false
    private var stopRequested = false
    private var applyingStoredDelay = false
    private var journalFailureDuringRun = false
    private var isAuthorizing = false
    private var progressToken: UUID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var sharingSource: URL?

    init(checkpoint: CheckpointStore? = nil,
         sourceService: MediaSourceService = MediaSourceService(),
         photoWriter: any PhotoLibraryWriting = PhotoLibraryWriter(),
         history: ImportHistoryStore? = nil) {
        self.sourceService = sourceService
        self.photoWriter = photoWriter
        let checkpoint = checkpoint ?? Self.defaultCheckpoint()
        self.checkpoint = checkpoint
        self.receivedStore = ReceivedAlbumStore(directory: checkpoint.url.deletingLastPathComponent().appendingPathComponent("received-albums"))
        self.receivedThumbnails = ReceivedThumbnailService(directory: checkpoint.url.deletingLastPathComponent().appendingPathComponent("received-previews"))
        self.history = ImportHistoryWorker(store: history ?? ImportHistoryStore(url: checkpoint.url.deletingLastPathComponent()
            .appendingPathComponent("import-history.sqlite")))
        do {
            library = try receivedStore.load()
            oneTimeImports = try receivedStore.loadOneTimeImports()
        }
        catch { message = "分享相册记录无法读取：\(error.localizedDescription)"; requiresReset = true }
        restoreJob()
    }

    var previouslySavedCount: Int {
        job?.items.filter { $0.state == .saved && $0.alreadyImported == true }.count ?? 0
    }

    var canShareArchive: Bool { job?.isSharedAlbum == true && job?.source.kind == .zip && !isPreparing && !isBusy }

    func shareURL() async -> URL? {
        guard canShareArchive, let job else { return nil }
        finishSharing()
        do {
            let source = try resolveBookmark(job.source)
            if source.startAccessingSecurityScopedResource() { sharingSource = source }
            guard FileManager.default.fileExists(atPath: source.path) else { finishSharing(); throw RelayError.staleBookmark }
            return source
        } catch { message = error.localizedDescription; return nil }
    }

    func finishSharing() {
        sharingSource?.stopAccessingSecurityScopedResource()
        sharingSource = nil
    }

    func loadThumbnail(jobID: UUID, itemID: String) async -> URL? {
        guard let selected = (job?.id == jobID ? job : library.first { $0.id == jobID }),
              let item = selected.items.first(where: { $0.id == itemID }) else { return nil }
        return await receivedThumbnails.load(item: item, source: selected.source)
    }

    @discardableResult
    func activate(albumID: UUID) async -> Bool {
        if isRestoring, let worker { await worker.value }
        guard !isBusy, !isPreparing, !requiresReset,
              let selected = library.first(where: { $0.albumID == albumID }) else { return false }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await preserveCurrentHistory()
            var candidate = try await history.reconcile(selected, markPreviouslyImported: true)
            candidate = try await revalidateAssets(candidate)
            if !candidate.hasUnresolvedItems { candidate.phase = .completed }
            try persist(candidate)
            needsRelink = (try? resolveBookmark(candidate.source)) == nil
            invalidatePreview(clearSaved: true)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func deleteAlbum(albumID: UUID) async -> Bool {
        guard !isBusy, !isPreparing, let candidate = library.first(where: { $0.albumID == albumID }) else { return false }
        isPreparing = true
        defer { isPreparing = false }
        do {
            _ = try await history.preserve(candidate)
            if job?.isSharedAlbum == true, job?.albumID == albumID {
                try checkpoint.remove(); job = nil; invalidatePreview(clearSaved: true)
            }
            try receivedStore.remove(albumID: albumID)
            library.removeAll { $0.albumID == albumID }
            return true
        } catch { message = error.localizedDescription; return false }
    }

    private func upsertLibrary(_ candidate: ImportJob) {
        if candidate.isOneTimeImport {
            library.removeAll { $0.id == candidate.id }
            if let index = oneTimeImports.firstIndex(where: { $0.id == candidate.id }) { oneTimeImports[index] = candidate }
            else { oneTimeImports.insert(candidate, at: 0) }
            return
        }
        if let index = library.firstIndex(where: { $0.albumID == candidate.albumID }) { library[index] = candidate }
        else { library.insert(candidate, at: 0) }
    }

    var canStart: Bool {
        guard let job else { return false }
        return !isBusy && !isPreparing && !requiresReset && !needsRelink
            && (job.pendingCount > 0 || (job.membershipPendingCount > 0 && job.albumLinkUnavailable != true)) && job.uncertainCount == 0
    }

    @discardableResult
    func selectSource(_ url: URL) async -> Bool {
        if isCleaningUp || isRestoring, let cleanup = worker { await cleanup.value }
        guard !isBusy, !isPreparing else { return false }
        guard !requiresReset else {
            message = "进度记录无法读取。请先核对相册，再清除损坏记录。"
            return false
        }
        return await prepareSource(url, relinking: false)
    }

    @discardableResult
    func relinkSource(_ url: URL) async -> Bool {
        if isRestoring, let restoration = worker { await restoration.value }
        guard !isBusy, !isPreparing, job != nil, !requiresReset else { return false }
        return await prepareSource(url, relinking: true)
    }

    func start() {
        guard canStart else { return }
        invalidatePreview(clearSaved: false)
        currentReadBytes = 0
        currentTotalBytes = 0
        isBusy = true
        stopRequested = false
        journalFailureDuringRun = false
        message = nil
        let token = UUID()
        progressToken = token
        beginBackgroundTask()
        UIApplication.shared.isIdleTimerDisabled = true
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(token: token)
        }
    }

    func pause() {
        guard isBusy || isPreparing else { return }
        invalidatePreview(clearSaved: false)
        stopRequested = true
        worker?.cancel()
        if isBusy {
            message = currentStage == "保存到相册"
                ? "正在暂停：等当前文件写入相册后停止。"
                : job?.source.kind == .zip
                    ? "正在暂停。已保存的项目会保留；当前条目下次重新解压。"
                    : "正在暂停。已读取的部分会保留，继续时先核对原文件，再读取剩余部分。"
        }
    }

    func retryFailures() {
        guard !isBusy, !isPreparing, var candidate = job else { return }
        candidate.retryFailures()
        candidate.lastMessage = nil
        do {
            try persist(candidate)
            message = candidate.uncertainCount > 0
                ? "失败项已加入待导入列表；请先核对保存结果不确定的文件。"
                : "失败项已加入待导入列表，点击继续即可重试。"
        } catch {
            message = journalErrorMessage(error)
        }
    }

    func resolveUncertain(id: String, asSaved: Bool) {
        guard !isBusy, !isPreparing else { return }
        isPreparing = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparing = false; self.worker = nil }
            await self.resolveUncertainItem(id: id, asSaved: asSaved)
        }
    }

    private func resolveUncertainItem(id: String, asSaved: Bool) async {
        guard var candidate = job,
              let index = candidate.items.firstIndex(where: { $0.id == id && $0.state == .uncertain }) else { return }
        do {
            if let identity = candidate.items[index].contentIdentity {
                if asSaved {
                    try await history.confirm(identity: identity, jobID: candidate.id, itemID: id,
                        assetIdentifier: candidate.items[index].assetIdentifier,
                        sourceIdentity: candidate.source.contentIdentity)
                } else if try await history.record(for: identity)?.state == .confirmed {
                    candidate.items[index].state = .saved
                    candidate.items[index].alreadyImported = true
                    candidate.items[index].errorMessage = nil
                    if !candidate.hasUnresolvedItems { candidate.phase = .completed }
                    try persist(candidate)
                    message = "这项内容已有确认的保存记录，已跳过重复写入。"
                    return
                } else {
                    try await history.releaseUnresolved(identity: identity)
                }
            }
            candidate.resolveUncertain(id: id, asSaved: asSaved)
            candidate.lastMessage = nil
            if !candidate.hasUnresolvedItems { candidate.phase = .completed }
            try persist(candidate)
            message = asSaved ? "已标记为保存完成。" : "已加入待导入列表；再次导入可能产生重复照片。"
        } catch {
            message = journalErrorMessage(error)
        }
    }

    func clearJob() {
        guard !isBusy, !isPreparing else {
            message = "请先暂停，并等待当前文件处理完成后再清除任务。"
            return
        }
        isPreparing = true
        isCleaningUp = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparing = false; self.isCleaningUp = false; self.worker = nil }
            await self.clearStoredJob()
        }
    }

    /// Closing a completed one-time import removes its resumable task, never its
    /// confirmed content receipts or any photo/source file. Paused, failed and
    /// uncertain tasks must be resumed or explicitly cleared instead.
    @discardableResult
    func finishOneTimeImport() async -> Bool {
        guard !isBusy, !isPreparing, !requiresReset, let selected = job,
              selected.isOneTimeImport, selected.phase == .completed,
              !selected.hasUnresolvedItems else { return false }
        return await discardCurrentImport()
    }

    /// Explicitly confirmed cancellation of an ordinary import. Shared albums
    /// use deleteAlbum instead, so this cannot remove another library entry.
    @discardableResult
    func discardCurrentImport() async -> Bool {
        guard !isBusy, !isPreparing, !requiresReset, job?.isOneTimeImport == true else { return false }
        isPreparing = true
        isCleaningUp = true
        defer { isPreparing = false; isCleaningUp = false }
        await clearStoredJob()
        return job == nil
    }

    @discardableResult
    func replaceSource(_ url: URL) async -> Bool {
        if isCleaningUp || isRestoring, let cleanup = worker { await cleanup.value }
        guard !isBusy, !isPreparing, !requiresReset else { return false }
        // Scan the newly selected URL before replacing the checkpoint. A failed
        // open must neither clear the old job nor acknowledge an incoming URL.
        return await prepareSource(url, relinking: false)
    }

    private func clearStoredJob() async {
        let clearing = job
        do {
            try await preserveCurrentHistory()
            try checkpoint.remove()
            if let job {
                if job.isSharedAlbum {
                    try receivedStore.remove(albumID: job.albumID)
                    library.removeAll { $0.albumID == job.albumID }
                } else {
                    try receivedStore.removeOneTimeImport(jobID: job.id)
                    oneTimeImports.removeAll { $0.id == job.id }
                }
            }
        } catch {
            message = "无法清除进度记录：\(error.localizedDescription)"
            return
        }
        job = nil
        invalidatePreview(clearSaved: true)
        currentReadBytes = 0
        currentTotalBytes = 0
        isSavingToPhotos = false
        delayPersistenceTask?.cancel()
        delayPersistenceTask = nil
        needsRelink = false
        requiresReset = false
        applyingStoredDelay = true
        delaySeconds = 0.5
        applyingStoredDelay = false
        currentFile = ""
        currentFraction = 0
        scannedCount = 0
        currentStage = "清理临时文件"
        message = nil
        if library.isEmpty && oneTimeImports.isEmpty { await sourceService.cleanupAll() }
        else if let clearing { try? await sourceService.cleanupResumableFiles(for: clearing) }
        currentStage = ""
    }

    func sceneDidBecomeInactive() {
        // The first Photos permission sheet also makes the scene inactive. No media
        // transaction has started then; a real background transition still stops it.
        if isAuthorizing && UIApplication.shared.applicationState != .background { return }
        UIApplication.shared.isIdleTimerDisabled = false
        pause()
    }

    private static func defaultCheckpoint() -> CheckpointStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return CheckpointStore(url: root.appendingPathComponent("PhotoRelay", isDirectory: true)
            .appendingPathComponent("progress.json"))
    }

    private func restoreJob() {
        do {
            guard var restored = try checkpoint.load() else { return }
            restored.migrateImportPurpose()
            // Publish the durable checkpoint immediately, but keep actions gated
            // until the I/O actor has reconciled its persistent success receipts.
            job = restored
            isPreparing = true
            isRestoring = true
            currentStage = "恢复导入历史"
            worker = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.isPreparing = false
                    self.isRestoring = false
                    self.currentStage = ""
                    self.worker = nil
                }
                do {
                    var reconciled = try await self.history.restore(restored)
                    if !reconciled.hasUnresolvedItems { reconciled.phase = .completed }
                    self.job = reconciled
                    self.applyingStoredDelay = true
                    self.delaySeconds = reconciled.delaySeconds
                    self.applyingStoredDelay = false
                    self.scannedCount = reconciled.items.count
                    do { _ = try self.resolveBookmark(reconciled.source) }
                    catch { self.needsRelink = true }
                    self.message = reconciled.uncertainCount > 0
                        ? "上次保存时应用中断。请先在相册核对“不确定”文件，避免重复导入。"
                        : reconciled.lastMessage
                    try self.persist(reconciled)
                } catch {
                    self.requiresReset = true
                    self.message = "进度或导入历史无法读取：\(error.localizedDescription) 请先核对相册，再清除记录。"
                }
            }
        } catch {
            requiresReset = true
            message = "进度记录无法读取：\(error.localizedDescription) 请先核对相册，再清除记录。"
        }
    }

    private func prepareSource(_ url: URL, relinking: Bool) async -> Bool {
        invalidatePreview(clearSaved: !relinking)
        currentReadBytes = 0
        currentTotalBytes = 0
        isPreparing = true
        stopRequested = false
        scannedCount = 0
        currentStage = "扫描文件"
        message = nil
        let token = UUID()
        progressToken = token
        var accepted = false
        let task = Task { [weak self] in
            guard let self else { return }
            accepted = await self.scanSelection(url, relinking: relinking, token: token)
        }
        worker = task
        await task.value
        return accepted
    }

    private func scanSelection(_ url: URL, relinking: Bool, token: UUID) async -> Bool {
        defer {
            isPreparing = false
            currentStage = ""
            progressToken = nil
            worker = nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await preserveCurrentHistory()
            try Task.checkCancellation()
            let kind = try kindOfSource(url)
            if relinking, kind != job?.source.kind { throw RelayError.sourceMismatch }
            let scan = try await sourceService.scan(url: url, kind: kind,
                                                    progress: scanProgress(token: token))
            try Task.checkCancellation()
            guard !scan.items.isEmpty else { throw RelayError.noMedia }
            // Drain the scan phase explicitly: late throttled progress callbacks must
            // not replace this final count while a file provider creates its bookmark.
            progressToken = nil
            scannedCount = scan.items.count
            currentStage = "保存来源记录"
            let bookmark = try await sourceService.makeBookmark(for: url)
            try Task.checkCancellation()
            currentStage = "核对导入历史"
            var descriptor = SourceDescriptor(kind: kind, name: url.lastPathComponent,
                                              bookmark: bookmark, fingerprint: scan.fingerprint)
            var scannedItems = scan.items
            if let fingerprint = scan.fingerprint, kind != .folder {
                let digest = try await contentHasher.hashFile(url, expectedBytes: fingerprint.byteCount,
                                                              expectedModifiedAt: fingerprint.modifiedAt)
                descriptor.contentIdentity = try ImportContentIdentity.source(kind: kind, sha256: digest)
                if kind == .mediaFile, scannedItems.count == 1 {
                    scannedItems[0].contentIdentity = try ImportContentIdentity.media(kind: scannedItems[0].kind, primarySHA256: digest)
                }
            }
            try Task.checkCancellation()
            if kind != .mediaFile {
                currentStage = "核对照片内容"
                scannedItems = try await sourceService.verifiedItems(scannedItems, sourceURL: url, kind: kind, progress: { _ in })
            }
            let previousID = job?.id
            var candidate: ImportJob
            if relinking {
                guard let existing = job,
                      sourceMatches(existing, scan: scan),
                      existing.source.contentIdentity == nil || existing.source.contentIdentity == descriptor.contentIdentity else {
                    throw RelayError.sourceMismatch
                }
                if kind == .folder {
                    try await contentHasher.verifyFolderHistory(existing.items, root: url)
                    try Task.checkCancellation()
                } else if existing.source.contentIdentity == nil,
                          existing.items.contains(where: { ($0.state == .saved || $0.state == .uncertain)
                              && $0.contentIdentity == nil && $0.expectedSHA256 == nil }) {
                    throw ImportIdentityError.unavailable("旧任务没有可验证的内容记录，无法安全关联这个来源。请先核对旧任务与相册。")
                }
                candidate = existing
                candidate.source = descriptor
                // Relinking preserves task identity, but cannot promote an
                // ordinary import into a shared album just by renaming a file.
                candidate.migrateImportPurpose()
                candidate.phase = candidate.hasUnresolvedItems ? .paused : .completed
            } else {
                candidate = ImportJob(source: descriptor, items: scannedItems, delaySeconds: delaySeconds)
                candidate.purpose = scan.isSharedAlbum ? .sharedAlbum : .oneTimeImport
                if candidate.isSharedAlbum { candidate.album = scan.album ?? fallbackAlbum(source: descriptor, items: scannedItems) }
                if candidate.isSharedAlbum, let existing = library.first(where: { $0.albumID == candidate.albumID }) {
                    if ReceivedAlbumStore.shouldKeepExisting(existing, incoming: candidate) {
                        if existing.source.contentIdentity == descriptor.contentIdentity {
                            candidate = existing
                            candidate.source = descriptor
                        } else {
                            // Never roll back membership because an old package arrived late.
                            candidate = existing
                        }
                    } else {
                        // Duplicate receipts can come from this same snapshot or
                        // a completely different album. Only a known lower
                        // revision of this album proves an album update.
                        candidate.isAlbumUpdate = (candidate.album?.revision ?? 1) > (existing.album?.revision ?? 1)
                            && (existing.isAlbumUpdate == true || existing.savedCount > 0)
                        candidate.id = existing.id
                        candidate.createdAt = existing.createdAt
                        candidate.systemAlbumIdentifier = existing.systemAlbumIdentifier
                    }
                } else if candidate.isOneTimeImport,
                          let existing = oneTimeImports.first(where: {
                              $0.source.kind == kind && $0.matchesReplacement(scannedItems)
                                  && (kind == .folder || (descriptor.contentIdentity != nil && $0.source.contentIdentity == descriptor.contentIdentity))
                                  && (kind != .folder || zip($0.items, scannedItems).allSatisfy { pair in
                                      pair.0.contentIdentity != nil && pair.0.contentIdentity == pair.1.contentIdentity
                                  })
                          }) {
                    candidate = existing
                    candidate.source = descriptor
                    candidate.migrateImportPurpose()
                }
            }
            candidate = try await history.reconcile(candidate, markPreviouslyImported: true)
            candidate = try await revalidateAssets(candidate)
            if !candidate.hasUnresolvedItems { candidate.phase = .completed }
            let skipped = candidate.items.filter { $0.state == .saved && $0.alreadyImported == true }.count
            candidate.lastMessage = skipped > 0 ? "已存过的 \(skipped) 项已跳过。"
                : scan.ignoredCount > 0 ? "找到 \(scan.items.count) 个照片或视频，忽略 \(scan.ignoredCount) 个其他项目。" : nil
            do {
                try persist(candidate)
                needsRelink = (try? resolveBookmark(candidate.source)) == nil
                message = candidate.uncertainCount > 0
                    ? "有保存结果不确定的项目，请先核对相册，避免重复导入。" : candidate.lastMessage
                _ = previousID // Other paused albums retain their resumable source prefixes.
                scannedCount = scan.items.count
                return true
            } catch {
                message = journalErrorMessage(error)
                return false
            }
        } catch is CancellationError {
            message = "扫描已停止。"
        } catch {
            if relinking { needsRelink = true }
            message = error.localizedDescription
        }
        return false
    }

    private func run(token: UUID) async {
        defer {
            isAuthorizing = false
            isBusy = false
            invalidatePreview(clearSaved: false)
            currentReadBytes = 0
            currentTotalBytes = 0
            isSavingToPhotos = false
            currentFile = ""
            currentFraction = 0
            currentStage = ""
            progressToken = nil
            worker = nil
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
        }
        do {
            try Task.checkCancellation()
            currentStage = "清理临时文件"
            // Retain raw-file prefixes across pause, disconnect and relaunch. ZIP
            // entries still restart extraction because deflate has no seek checkpoint.
            guard var initial = job else { return }
            initial = try await history.reconcile(initial, markPreviouslyImported: false)
            try persist(initial)
            await sourceService.cleanupForResume(job: initial)
            try Task.checkCancellation()
            currentStage = "请求添加照片权限"
            isAuthorizing = true
            // Sync may request permission, but creates no collection until a
            // confirmed existing/successfully saved asset can be added with it.
            if initial.isSharedAlbum { await photoWriter.authorizeAlbumLink() }
            try await photoWriter.authorize()
            initial.albumLinkUnavailable = nil
            initial = try await revalidateAssets(initial)
            try persist(initial)
            try await synchronizeMembership()
            isAuthorizing = false
            try Task.checkCancellation()
            if job?.pendingCount == 0 { finishRun(); return }
            let sourceURL = try resolveBookmark(initial.source)
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            currentStage = "核对源文件"
            scannedCount = 0
            let scan = try await sourceService.scan(url: sourceURL, kind: initial.source.kind,
                                                    progress: scanProgress(token: token))
            try Task.checkCancellation()
            guard sourceMatches(initial, scan: scan) else { throw RelayError.sourceMismatch }
            if let expected = initial.source.contentIdentity, let fingerprint = scan.fingerprint {
                let digest = try await contentHasher.hashFile(sourceURL, expectedBytes: fingerprint.byteCount,
                                                              expectedModifiedAt: fingerprint.modifiedAt)
                guard try ImportContentIdentity.source(kind: initial.source.kind, sha256: digest) == expected else {
                    throw RelayError.sourceMismatch
                }
            }
            scannedCount = scan.items.count
            needsRelink = false
            guard var candidate = job else { return }
            candidate.phase = .running
            candidate.lastMessage = nil
            do {
                try persist(candidate)
            } catch {
                stopForJournalError(error)
                return
            }

            while !stopRequested, !Task.isCancelled,
                  let index = job?.items.firstIndex(where: { $0.state == .pending }) {
                let proceed = await importOne(index: index, sourceURL: sourceURL,
                                              kind: initial.source.kind)
                if !proceed || stopRequested || Task.isCancelled { break }
                if delaySeconds > 0, (job?.pendingCount ?? 0) > 0 {
                    currentStage = "等待下一项"
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
            finishRun()
        } catch is CancellationError {
            finishRun()
        } catch {
            isAuthorizing = false
            if error is RelayError || (error as? MediaSourceError)?.requiresSourceRelink == true {
                needsRelink = true
            }
            stopWithMessage(error.localizedDescription)
        }
    }

    /// Returns false for source, storage, or journal errors that must stop the job.
    private func importOne(index: Int, sourceURL: URL, kind: SourceKind) async -> Bool {
        guard let item = job?.items[index] else { return false }
        let fileToken = UUID()
        progressToken = fileToken
        previewGeneration = fileToken
        // Leave room for the next decoder result before allocating it, not just
        // when publishing it. The importer owns no more than three thumbnails.
        recentSavedPreviews = Array(recentSavedPreviews.prefix(2))
        activePreview = ImportPreview(id: fileToken, itemID: item.id,
            title: (item.relativePath as NSString).lastPathComponent, kind: item.kind, image: nil)
        currentReadBytes = 0
        currentTotalBytes = item.resourceBytes
        isSavingToPhotos = false
        defer {
            if previewGeneration == fileToken { activePreview = nil }
            isSavingToPhotos = false
        }
        currentFile = item.relativePath
        currentFraction = 0
        currentStage = kind == .zip ? "解压当前文件" : "读取当前文件"
        let stagedURL: PreparedMedia
        do {
            stagedURL = try await sourceService.prepareMedia(item: item, sourceURL: sourceURL,
                kind: kind, verificationProgress: verificationProgress(token: fileToken),
                progress: fileProgress(token: fileToken))
        } catch is CancellationError {
            return false
        } catch {
            if let sourceError = error as? MediaSourceError {
                if sourceError.requiresSourceRelink {
                    needsRelink = true
                    stopWithMessage(error.localizedDescription)
                    return false
                }
                if case .insufficientSpace = sourceError {
                    stopWithMessage(error.localizedDescription)
                    return false
                }
                if case .ioFailure = sourceError {
                    stopWithMessage(error.localizedDescription)
                    return false
                }
            }
            return recordFailure(index: index, error: error)
        }

        if stopRequested || Task.isCancelled {
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        }
        currentStage = "核对导入历史"
        let identity: String
        do {
            identity = try await contentHasher.preparedIdentity(item: item, fileURL: stagedURL.fileURL,
                                                               pairedVideoURL: stagedURL.pairedVideoURL)
            if let expected = item.contentIdentity, expected != identity { throw ImportIdentityError.changedFile }
            guard var identified = job else { return false }
            identified.items[index].contentIdentity = identity
            try persist(identified)
            if let existing = try await validatedRecord(identity: identity) {
                try await history.associate(identity: identity, sourceIdentity: identified.source.contentIdentity, itemID: item.id)
                apply(existing, to: &identified.items[index], markPreviouslyImported: true)
                identified.items[index].albumMembershipPending = existing.state == .confirmed
                    && identified.isSharedAlbum && identified.items[index].assetIdentifier != nil
                try persist(identified)
                try await synchronizeMembership()
                await sourceService.cleanup(stagedURL)
                if existing.state == .unresolved {
                    stopWithMessage("这项内容的上次保存结果不确定，请先核对相册。")
                    return false
                }
                message = "已存过的 \(previouslySavedCount) 项已跳过。"
                return true
            }
        } catch is CancellationError {
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        } catch {
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            stopForJournalError(error)
            return false
        }
        if stopRequested || Task.isCancelled {
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        }
        currentReadBytes = item.resourceBytes
        currentFraction = 1
        currentStage = "准备保存"
        await preparePreview(item: item, stagedURL: stagedURL.fileURL, token: fileToken)
        if stopRequested || Task.isCancelled {
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        }
        guard var inFlight = job else {
            await sourceService.cleanup(stagedURL)
            return false
        }
        inFlight.items[index].state = .inFlight
        inFlight.items[index].errorMessage = nil
        do {
            // Both the checkpoint and independent unresolved reservation precede
            // PhotoKit. Clearing a task must not forget an ambiguous transaction.
            try persist(inFlight)
            if let existing = try await history.begin(identity: identity, jobID: inFlight.id,
                itemID: item.id, sourceIdentity: inFlight.source.contentIdentity) {
                apply(existing, to: &inFlight.items[index], markPreviouslyImported: true)
                inFlight.items[index].albumMembershipPending = existing.state == .confirmed
                    && inFlight.isSharedAlbum && inFlight.items[index].assetIdentifier != nil
                try persist(inFlight)
                try await synchronizeMembership()
                await sourceService.cleanup(stagedURL)
                if existing.state == .unresolved {
                    stopWithMessage("这项内容的上次保存结果不确定，请先核对相册。")
                    return false
                }
                return true
            }
        } catch {
            await sourceService.cleanup(stagedURL, preservingResumable: true) // PhotoKit has not seen this file yet.
            stopForJournalError(error)
            return false
        }
        if stopRequested || Task.isCancelled {
            guard await releaseReservation(identity: identity, index: index) else { return false }
            restorePending(index: index)
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        }
        // PhotoKit exposes no byte progress. The read has finished, but the UI
        // must show an indeterminate save until Photos and the journal succeed.
        currentFraction = 0
        currentStage = "保存到相册"
        isSavingToPhotos = true
        let assetIdentifier: String?
        do {
            assetIdentifier = try await photoWriter.save(item: item, fileURL: stagedURL.fileURL,
                                                        pairedVideoURL: stagedURL.pairedVideoURL)
        } catch is CancellationError {
            // Writer cancellation is checked only BEFORE launching PhotoKit.
            guard await releaseReservation(identity: identity, index: index) else { return false }
            restorePending(index: index)
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return false
        } catch PhotoLibraryWriterError.permissionDenied {
            guard await releaseReservation(identity: identity, index: index) else { return false }
            restorePending(index: index)
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            stopWithMessage(PhotoLibraryWriterError.permissionDenied.localizedDescription)
            return false
        } catch {
            guard await releaseReservation(identity: identity, index: index) else { return false }
            let persisted = recordFailure(index: index, error: error)
            // A confirmed PhotoKit failure can be explicitly retried. Keep raw
            // media's complete staging copy; ZIP entries remain transient.
            await sourceService.cleanup(stagedURL, preservingResumable: true)
            return persisted
        }

        guard var completed = job else { return false }
        completed.items[index].state = .saved
        completed.items[index].assetIdentifier = assetIdentifier
        completed.items[index].albumMembershipPending = completed.isSharedAlbum && assetIdentifier != nil
        completed.items[index].errorMessage = nil
        do {
            // A confirmed history receipt requires PhotoKit's success callback.
            // If this fails, the unresolved row and inFlight checkpoint survive.
            try await history.confirm(identity: identity, jobID: completed.id, itemID: item.id,
                assetIdentifier: assetIdentifier, sourceIdentity: completed.source.contentIdentity)
            try persist(completed)
        } catch {
            // This is a JOURNAL error after a successful Photos transaction, never a
            // Photos failure eligible for automatic retry. Leave its staged file intact.
            completed.items[index].state = .uncertain
            completed.items[index].errorMessage = "相册已返回保存成功，但进度记录失败。请在相册核对后处理，避免重复导入。"
            stopForJournalError(error, candidate: completed)
            // Best effort; disk's inFlight marker is safe if this also fails.
            if let uncertainJob = job { try? checkpoint.save(uncertainJob) }
            return false
        }
        do { try await synchronizeMembership() }
        catch {
            // The confirmed content receipt survives an album membership error.
            // Retry only adds the existing asset; never issue another save.
            await sourceService.cleanup(stagedURL)
            stopWithMessage("照片已保存，加入分享相册时失败。点击继续重试。\(error.localizedDescription)")
            return false
        }
        publishSavedPreview(item: item, token: fileToken)
        await sourceService.cleanup(stagedURL)
        return true
    }

    private func preparePreview(item: ImportItem, stagedURL: URL, token: UUID) async {
        guard previewGeneration == token, !stopRequested, !Task.isCancelled else { return }
        let task = Task { [thumbnailLoader] in
            await thumbnailLoader.thumbnail(fileURL: stagedURL, kind: item.kind)
        }
        thumbnailWorker = task
        let bitmap = await task.value
        guard previewGeneration == token, !stopRequested, !Task.isCancelled else { return }
        thumbnailWorker = nil
        guard let bitmap, var preview = activePreview, preview.id == token else { return }
        // At most three unique thumbnail bitmaps are retained across active and
        // saved previews. UIImage wraps only the already downsampled CGImage.
        _ = await receivedThumbnails.cache(bitmap, item: item)
        preview.image = UIImage(cgImage: bitmap)
        activePreview = preview
    }

    private func publishSavedPreview(item: ImportItem, token: UUID) {
        guard previewGeneration == token, !stopRequested, !Task.isCancelled,
              let preview = activePreview, preview.itemID == item.id,
              job?.items.contains(where: { $0.id == item.id && $0.state == .saved }) == true else { return }
        // Called only after both the PhotoKit success callback and persist(). A
        // canceled/backgrounded visual generation never emits a late animation.
        activePreview = nil
        recentSavedPreviews = [preview] + Array(recentSavedPreviews.prefix(2))
        savedPreviewSequence &+= 1
    }

    private func invalidatePreview(clearSaved: Bool) {
        previewGeneration = UUID()
        thumbnailWorker?.cancel()
        thumbnailWorker = nil
        activePreview = nil
        if clearSaved { recentSavedPreviews = [] }
    }

    private func recordFailure(index: Int, error: Error) -> Bool {
        guard var candidate = job else { return false }
        candidate.items[index].state = .failed
        candidate.items[index].errorMessage = error.localizedDescription
        do {
            try persist(candidate)
            return true
        } catch {
            stopForJournalError(error, candidate: candidate)
            return false
        }
    }

    private func restorePending(index: Int) {
        guard var candidate = job else { return }
        candidate.items[index].state = .pending
        candidate.items[index].errorMessage = nil
        do {
            try persist(candidate)
        } catch {
            stopForJournalError(error, candidate: candidate)
        }
    }

    private func finishRun() {
        guard !journalFailureDuringRun, var candidate = job else { return }
        let stopReason = stopRequested ? candidate.lastMessage : nil
        candidate.phase = candidate.hasUnresolvedItems ? .paused : .completed
        candidate.lastMessage = stopReason ?? (candidate.phase == .completed
            ? previouslySavedCount > 0 ? "已存过的 \(previouslySavedCount) 项已跳过，其余已存入相册。" : "已保存全部 \(candidate.savedCount) 个文件。"
            : candidate.uncertainCount > 0 ? "请先核对保存结果不确定的文件。"
            : candidate.failedCount > 0 ? "已暂停；\(candidate.failedCount) 个文件失败，可单独重试。" : "已暂停，可以继续。")
        do {
            try persist(candidate)
            message = candidate.lastMessage
        } catch {
            stopForJournalError(error, candidate: candidate)
        }
    }

    private func apply(_ record: ImportHistoryRecord, to item: inout ImportItem, markPreviouslyImported: Bool) {
        ImportHistoryStore.apply(record, to: &item, markPreviouslyImported: markPreviouslyImported)
    }

    private func validatedRecord(identity: String) async throws -> ImportHistoryRecord? {
        guard let record = try await history.record(for: identity) else { return nil }
        if record.state == .confirmed, let asset = record.assetIdentifier,
           await photoWriter.assetPresence(asset) == .missing {
            try await history.forgetMissingAsset(identity: identity, assetIdentifier: asset)
            return nil
        }
        return record
    }

    private func revalidateAssets(_ value: ImportJob) async throws -> ImportJob {
        var result = value
        result.migrateImportPurpose()
        var members: Set<String>?
        if result.isSharedAlbum {
            let albumPresence = try await photoWriter.albumPresence(id: result.albumID)
            if albumPresence == .missing {
                result.systemAlbumIdentifier = nil
                result.albumLinkUnavailable = nil
            } else if albumPresence == .available {
                result.albumLinkUnavailable = false
            }
            members = try await photoWriter.albumMembers(id: result.albumID).map(Set.init)
        }
        for index in result.items.indices where result.items[index].state == .saved {
            guard let asset = result.items[index].assetIdentifier else { continue }
            switch await photoWriter.assetPresence(asset) {
            case .missing:
                if let identity = result.items[index].contentIdentity {
                    try await history.forgetMissingAsset(identity: identity, assetIdentifier: asset)
                }
                result.items[index].state = .pending
                result.items[index].assetIdentifier = nil
                result.items[index].alreadyImported = false
                result.items[index].albumMembershipPending = false
            case .available:
                if result.isSharedAlbum {
                    if let members {
                        // A fresh full snapshot has no per-item membership flag.
                        // Actual Photos membership is stronger evidence than nil
                        // or a stale pending flag from a previous linking attempt.
                        // A failed first link may leave no checkpoint identifier;
                        // externally repaired membership is still authoritative.
                        result.items[index].albumMembershipPending = !members.contains(asset)
                    } else if result.items[index].albumMembershipPending == nil || result.systemAlbumIdentifier == nil {
                        // Unknown membership must not be treated as confirmed.
                        result.items[index].albumMembershipPending = true
                    }
                }
            case .unknown:
                // Receipt remains authoritative for write idempotency; lack of
                // read permission cannot establish that a photo was deleted.
                break
            }
        }
        return result
    }

    private func synchronizeMembership() async throws {
        guard var candidate = job, candidate.isSharedAlbum else { return }
        let indices = candidate.items.indices.filter {
            candidate.items[$0].state == .saved && candidate.items[$0].albumMembershipPending == true
        }
        guard !indices.isEmpty else { return }
        guard candidate.albumLinkUnavailable != true else { return }
        let assets = indices.compactMap { candidate.items[$0].assetIdentifier }
        guard !assets.isEmpty else { return }
        guard let linked = try await photoWriter.addToAlbum(assetIdentifiers: assets, id: candidate.albumID, title: candidate.displayTitle) else {
            candidate.albumLinkUnavailable = true
            candidate.systemAlbumIdentifier = nil
            // Keep the requested membership pending until permission is restored.
            try persist(candidate)
            return
        }
        candidate.systemAlbumIdentifier = linked
        candidate.albumLinkUnavailable = false
        for index in indices { candidate.items[index].albumMembershipPending = false }
        try persist(candidate)
    }

    private func fallbackAlbum(source: SourceDescriptor, items: [ImportItem]) -> ShareAlbumMetadata {
        let identity = source.contentIdentity ?? items.compactMap(\.contentIdentity).sorted().joined(separator: "|")
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let uuidText = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20).prefix(12))"
        let title: String
        let stem = (source.name as NSString).deletingPathExtension
        if source.kind == .zip, !stem.isEmpty, !stem.lowercased().hasPrefix("dropack-") { title = stem }
        else { title = ShareAlbumNaming.title(dates: items.compactMap { $0.creationDate ?? $0.modifiedAt }) }
        return ShareAlbumMetadata(id: UUID(uuidString: uuidText) ?? UUID(), title: title)
    }

    /// Upgrade only evidence the previous importer actually confirmed. Manifest
    /// hashes on .saved items were checked before the original Photos transaction.
    private func preserveCurrentHistory() async throws {
        guard let candidate = job else { return }
        let preserved = try await history.preserve(candidate)
        try receivedStore.save(preserved)
        upsertLibrary(preserved)
        job = preserved
    }

    private func releaseReservation(identity: String, index: Int) async -> Bool {
        do {
            try await history.releaseUnresolved(identity: identity)
            return true
        } catch {
            var candidate = job
            candidate?.items[index].state = .uncertain
            stopForJournalError(error, candidate: candidate)
            return false
        }
    }

    private func persist(_ candidate: ImportJob) throws {
        var candidate = candidate
        candidate.migrateImportPurpose()
        try checkpoint.save(candidate)
        try receivedStore.save(candidate)
        upsertLibrary(candidate)
        job = candidate
    }

    private func stopForJournalError(_ error: Error, candidate: ImportJob? = nil) {
        journalFailureDuringRun = true
        let text = journalErrorMessage(error)
        if var paused = candidate ?? job {
            paused.phase = .paused
            paused.lastMessage = text
            job = paused
        }
        message = text
        stopRequested = true
    }

    private func stopWithMessage(_ text: String) {
        guard var candidate = job else { message = text; return }
        candidate.phase = .paused
        candidate.lastMessage = text
        do {
            try persist(candidate)
            message = text
        } catch {
            stopForJournalError(error, candidate: candidate)
            message = "\(text)\n\(journalErrorMessage(error))"
        }
        stopRequested = true
    }

    private func updateDelay() {
        guard !applyingStoredDelay else { return }
        let normalized = delaySeconds.isFinite ? min(10, max(0, delaySeconds)) : 0.5
        if normalized != delaySeconds {
            applyingStoredDelay = true
            delaySeconds = normalized
            applyingStoredDelay = false
        }
        guard var candidate = job else { return }
        candidate.delaySeconds = normalized
        job = candidate
        delayPersistenceTask?.cancel()
        // While a transaction is outstanding, its normal checkpoint will include the
        // new delay. Slider changes must not interfere with that transaction's journal.
        if isBusy || isPreparing { return }
        delayPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch { return }
            guard let self, !self.isBusy, !self.isPreparing,
                  !self.requiresReset, let latest = self.job else { return }
            do {
                try self.persist(latest)
            } catch {
                self.message = self.journalErrorMessage(error)
            }
        }
    }

    private func kindOfSource(_ url: URL) throws -> SourceKind {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { return .folder }
        if ["zip", "dropack"].contains(url.pathExtension.lowercased()) { return .zip }
        if MediaPolicy.kind(for: url.lastPathComponent) != nil { return .mediaFile }
        throw RelayError.unsupportedSource
    }

    private func resolveBookmark(_ descriptor: SourceDescriptor) throws -> URL {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: descriptor.bookmark, options: .withoutUI,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw RelayError.staleBookmark
        }
        guard !stale else { throw RelayError.staleBookmark }
        return url
    }

    private func sourceMatches(_ existing: ImportJob, scan: SourceScan) -> Bool {
        guard existing.isSharedAlbum == scan.isSharedAlbum else { return false }
        if existing.source.kind != .folder,
           existing.source.fingerprint != scan.fingerprint { return false }
        return existing.matchesReplacement(scan.items)
    }

    private func scanProgress(token: UUID) -> @Sendable (Int) -> Void {
        { [weak self] count in
            Task { @MainActor in
                guard let self, self.progressToken == token else { return }
                self.scannedCount = count
            }
        }
    }

    private func fileProgress(token: UUID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.progressToken == token,
                      self.currentStage == "解压当前文件" || self.currentStage == "读取当前文件"
                        || self.currentStage == "核对已读取部分" else { return }
                if self.currentStage == "核对已读取部分" { self.currentStage = "读取当前文件" }
                let bounded = fraction.isFinite ? min(1, max(0, fraction)) : 0
                self.currentFraction = bounded
                self.currentReadBytes = bounded >= 1 ? self.currentTotalBytes
                    : UInt64((Double(self.currentTotalBytes) * bounded).rounded(.down))
            }
        }
    }

    private func verificationProgress(token: UUID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.progressToken == token,
                      self.currentStage == "读取当前文件" || self.currentStage == "核对已读取部分" else { return }
                self.currentStage = "核对已读取部分"
                self.currentFraction = min(1, max(0, fraction))
            }
        }
    }

    private func journalErrorMessage(_ error: Error) -> String {
        "进度记录写入失败，已停止导入：\(error.localizedDescription) 已确认保存的文件会保留；请不要重复导入不确定项。"
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishCurrentPhoto") { [weak self] in
            // UIKit invokes its expiration handler on the main thread. End the
            // background task before returning, without scheduling another Task.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopRequested = true
                self.worker?.cancel()
                self.invalidatePreview(clearSaved: false)
                let text = "后台时间已到，已停止后续文件。正在写入的文件会等待相册返回；若应用被系统终止，请在下次打开时核对不确定项。"
                if var candidate = self.job {
                    candidate.phase = .paused
                    candidate.lastMessage = text
                    self.job = candidate
                }
                self.message = text
                UIApplication.shared.isIdleTimerDisabled = false
                // The current inFlight marker is already durable before PhotoKit.
                // Avoid disk I/O in this deadline handler; completion records its result.
                // No temporary-file cleanup here: PhotoKit may still be reading it.
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private enum RelayError: LocalizedError {
    case unsupportedSource
    case noMedia
    case staleBookmark
    case sourceMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSource: return "请选择 .dropack 照片包、ZIP、照片、视频或文件夹。可在“文件”的位置列表中打开已连接的 U 盘。"
        case .noMedia: return "此文件中未找到支持的照片或视频。"
        case .staleBookmark: return "暂时无法访问原文件。请重新连接 U 盘，并重新选择原文件或文件夹。"
        case .sourceMismatch: return "源文件已变化，或与原任务不一致。请重新选择原照片包、视频或文件夹；已保存项目不会重复导入。"
        }
    }
}
