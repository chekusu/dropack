import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class PackageController: ObservableObject {
    @Published private(set) var job: PackageJob?
    @Published private(set) var library: [PackageLibraryEntry] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isPauseRequested = false
    @Published private(set) var usesSystemBackgroundProgress = false
    @Published var message: String?
    @Published private(set) var archiveURL: URL?
    @Published private(set) var requiresReset = false
    @Published private(set) var recoveryFailureID: UUID?

    // High-frequency updates belong to the task panel, not this page-level object.
    let activity = PackageActivity()
    var stage: String { activity.snapshot.stage }
    var currentFraction: Double { activity.snapshot.fraction }
    var currentName: String { activity.snapshot.name }

    private let service: PhotoPackageService
    private var worker: Task<Void, Never>?
    private var pickerSelections: [UUID: PhotoPickerSelection] = [:]
    private var progressToken: UUID?
    private let backgroundExecution: PackageBackgroundManaging
    private var activitySubscription: AnyCancellable?
    private var isInBackground = false
    private var backgroundResumePackageID: UUID?
    private var attemptPackageID: UUID?

    init(service: PhotoPackageService = PhotoPackageService(),
         backgroundExecution: PackageBackgroundManaging? = nil) {
        self.service = service
        self.backgroundExecution = backgroundExecution ?? PackageBackgroundExecution.shared
        activitySubscription = activity.$snapshot.sink { [weak self] snapshot in
            guard let self, self.progressToken != nil, !self.isPauseRequested else { return }
            self.backgroundExecution.update(snapshot)
        }
        isBusy = true
        activity.reset(snapshot: activitySnapshot(stage: "恢复打包进度"))
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.finishOperation() }
            do {
                let result = try await service.restore()
                job = result.job; archiveURL = result.archiveURL
                message = result.job?.lastMessage
                if needsPhotoReselection { message = pickerRecoveryMessage }
                if job != nil, job?.isDraft != true, archiveURL == nil, message == nil {
                    message = "上次的打包任务已恢复，点击继续。未完成的一项会重新读取。"
                }
            } catch {
                recoveryFailureID = try? await service.currentPackageID()
                if let id = recoveryFailureID { job = try? await service.job(packageID: id) }
                requiresReset = true
                message = "无法恢复打包进度：\(error.localizedDescription) 清除任务只会移除本应用生成的文件，原相册不会受影响。"
            }
            await refreshLibrary()
        }
    }

    var needsPhotoReselection: Bool {
        guard let job else { return false }
        return job.assets.contains { $0.pickerResourcePending == true } && retainedSelection(for: job) == nil
    }
    var canReselectPhotos: Bool {
        guard needsPhotoReselection, let job else { return false }
        return job.assets.filter { $0.pickerResourcePending == true }.allSatisfy { $0.pickerAssetIdentifier != nil }
    }
    private var pickerRecoveryMessage: String {
        (canReselectPhotos ? PhotoPackageError.pickerReselection : PhotoPackageError.pickerReselectionUnavailable).localizedDescription
    }
    var canResume: Bool {
        !isBusy && !requiresReset && !needsPhotoReselection && job != nil
            && job?.isDraft != true && job?.assets.isEmpty == false && archiveURL == nil
    }
    var canPause: Bool { isBusy && progressToken != nil && worker != nil && !isPauseRequested }

    func shareURL(packageID: UUID, format: PackageFileFormat = .dropack, onCreated: ((UUID) -> Void)? = nil) async -> URL? {
        guard !isBusy else { return nil }
        isBusy = true
        // Check live membership every time. Never return the preceding snapshot
        // simply because a previously prepared URL still exists.
        do {
            let refreshed = try await service.refreshAlbum(packageID: packageID)
            isBusy = false
            if refreshed.phase != .ready {
                guard await createOperation(totalCount: refreshed.totalCount, onCreated: onCreated,
                    packageAfterPreparation: true, makeJob: { refreshed }) != nil, !isBusy, archiveURL != nil else { return nil }
            } else if job?.stableAlbumID == refreshed.stableAlbumID, job?.id != refreshed.id {
                _ = await activate(packageID: refreshed.id)
                onCreated?(refreshed.id)
            }
            isBusy = true
            defer { activity.reset(snapshot: activitySnapshot()); isBusy = false }
            return try await service.sharePreparedURL(packageID: refreshed.id, format: format)
        } catch {
            isBusy = false
            message = "无法准备分享：\(error.localizedDescription)"
            return nil
        }
    }

    func shareURL(format: PackageFileFormat = .dropack) async -> URL? {
        guard let id = job?.id else { return nil }
        return await shareURL(packageID: id, format: format)
    }

    func previewArchiveURL(packageID: UUID) async throws -> URL {
        guard !isBusy || job?.id != packageID else { throw PackageModelError.invalidCheckpoint }
        return try await service.previewArchiveURL(packageID: packageID)
    }

    func resolvePreviewArchive(packageID: UUID, assetID: String) async throws -> (asset: PackageAsset, url: URL) {
        guard !isBusy || job?.id != packageID else { throw PackageModelError.invalidCheckpoint }
        return try await service.resolvePreviewArchive(packageID: packageID, assetID: assetID)
    }

    func thumbnailURL(packageID: UUID, itemID: String) -> URL? {
        service.thumbnailURL(packageID: packageID, itemID: itemID)
    }

    func loadThumbnail(packageID: UUID, itemID: String) async -> URL? {
        await service.loadThumbnail(packageID: packageID, itemID: itemID)
    }

    func refreshLibrary() async {
        do { library = try await service.library() }
        catch { if message == nil { message = "无法读取照片包列表：\(error.localizedDescription)" } }
    }

    /// Loading a historical package never starts export or changes another package.
    @discardableResult
    func activate(packageID: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { activity.reset(snapshot: activitySnapshot()); isBusy = false }
        do {
            let result = try await service.activate(packageID: packageID)
            job = result.job; archiveURL = result.archiveURL
            requiresReset = false; recoveryFailureID = nil; message = result.job?.lastMessage
            if needsPhotoReselection { message = pickerRecoveryMessage }
            await refreshLibrary()
            return true
        } catch {
            message = "无法打开照片包：\(error.localizedDescription)"
            return false
        }
    }

    func resume(packageID: UUID) async {
        guard await activate(packageID: packageID) else { return }
        resume()
    }

    /// PHPicker supplies private resource access even with denied/limited library
    /// permission. Full Photos access is optional and only enables linked albums.
    func requestPhotoAccess() async -> Bool {
        guard !isBusy else { return false }
        message = nil
        return true
    }

    @discardableResult
    func create(selection: PhotoPickerSelection, onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !selection.isEmpty else { return nil }
        return await createOperation(totalCount: selection.count, onCreated: onCreated) {
            let created = try await self.service.create(selection: selection)
            if created.assets.contains(where: { $0.pickerResourcePending == true }) {
                self.pickerSelections[created.id] = selection
            }
            return created
        }
    }

    @discardableResult
    func reselect(packageID: UUID, selection: PhotoPickerSelection,
                  onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !selection.isEmpty else { return nil }
        return await createOperation(totalCount: job?.totalCount ?? selection.count, onCreated: onCreated) {
            let existing = try await self.service.reselect(packageID: packageID, selection: selection)
            if existing.assets.contains(where: { $0.pickerResourcePending == true }) {
                self.pickerSelections[existing.id] = selection
            }
            return existing
        }
    }

    @discardableResult
    func create(assetIdentifiers: [String], onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !assetIdentifiers.isEmpty else { message = "请选择要发送的照片或视频。"; return nil }
        return await createOperation(totalCount: Set(assetIdentifiers).count, onCreated: onCreated) {
            try await self.service.create(assetIdentifiers: assetIdentifiers)
        }
    }

    @discardableResult
    func create(fileURLs: [URL], onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !fileURLs.isEmpty else { return nil }
        return await createOperation(totalCount: fileURLs.count, onCreated: onCreated) {
            try await self.service.create(fileURLs: fileURLs)
        }
    }

    /// Refresh membership without fetching originals or starting a ZIP writer.
    @discardableResult
    func refreshAlbum(packageID: UUID, onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { activity.reset(snapshot: activitySnapshot()); isBusy = false }
        do {
            let refreshed = try await service.refreshAlbum(packageID: packageID)
            let result = try await service.activate(packageID: refreshed.id)
            job = result.job; archiveURL = result.archiveURL
            requiresReset = false; recoveryFailureID = nil; message = result.job?.lastMessage
            if needsPhotoReselection { message = pickerRecoveryMessage }
            await refreshLibrary()
            onCreated?(refreshed.id)
            return refreshed.id
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func add(selection: PhotoPickerSelection, to packageID: UUID,
             onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !selection.isEmpty else { return nil }
        return await createOperation(totalCount: selection.count, onCreated: onCreated) {
            let revised = try await self.service.add(selection: selection, to: packageID)
            // Keep the old grants until the new snapshot can map every pending
            // item by its stable picker token/Photos identity, never by position.
            let retained = self.pickerSelections[revised.id]?.items ?? []
            let tokens = Set(retained.map(\.id))
            self.pickerSelections[revised.id] = PhotoPickerSelection(
                items: retained + selection.items.filter { !tokens.contains($0.id) })
            return revised
        }
    }

    @discardableResult
    func add(fileURLs: [URL], to packageID: UUID,
             onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !fileURLs.isEmpty else { return nil }
        return await createOperation(totalCount: fileURLs.count, onCreated: onCreated) {
            try await self.service.add(fileURLs: fileURLs, to: packageID)
        }
    }

    @discardableResult
    func remove(assetIDs: [String], from packageID: UUID,
                onCreated: ((UUID) -> Void)? = nil) async -> UUID? {
        guard !assetIDs.isEmpty else { return nil }
        return await createOperation(totalCount: job?.totalCount ?? 0, onCreated: onCreated,
                                     captureOriginals: false) {
            try await self.service.remove(assetIDs: assetIDs, from: packageID)
        }
    }

    @discardableResult
    func rename(packageID: UUID, title: String, onCreated: ((UUID) -> Void)? = nil) async -> Bool {
        guard !isBusy else { return false }
        return await createOperation(totalCount: job?.totalCount ?? 0, onCreated: onCreated,
                                     captureOriginals: false) {
            try await self.service.rename(packageID: packageID, title: title)
        } != nil
    }

    private func createOperation(totalCount: Int, onCreated: ((UUID) -> Void)?,
                                 packageAfterPreparation: Bool = false,
                                 captureOriginals: Bool = true,
                                 makeJob: @escaping @MainActor () async throws -> PackageJob) async -> UUID? {
        guard !isBusy else { return nil }
        isBusy = true; message = nil; archiveURL = nil
        requiresReset = false; recoveryFailureID = nil
        var createdID: UUID?
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishOperation() }
            do {
                try Task.checkCancellation()
                var created = try await makeJob()
                if packageAfterPreparation {
                    created = try await service.requestPackaging(packageID: created.id)
                }
                job = created; createdID = created.id
                await refreshLibrary()
                // Metadata-only edits neither start a background task nor show
                // a phantom packaging progress bar. Private PHPicker resources
                // are captured now because their access grant cannot survive a
                // relaunch. Capturing them still does not create a share package.
                let selection = retainedSelection(for: created)
                let shouldCapture = captureOriginals && selection != nil
                    && created.assets.contains { $0.pickerResourcePending == true }
                let shouldWork = packageAfterPreparation || shouldCapture
                if shouldWork {
                    let token = UUID(); progressToken = token; attemptPackageID = created.id
                    UIApplication.shared.isIdleTimerDisabled = true
                    beginBackgroundExecution(token: token)
                    // beginBackgroundExecution clears a previous attempt first.
                    attemptPackageID = created.id
                    activity.begin(token: token, initial: activitySnapshot(
                        stage: packageAfterPreparation ? "准备打包" : "读取所选资源"))
                    onCreated?(created.id)
                    try Task.checkCancellation()
                    try await run(packageID: created.id, token: token,
                                  packageAfterPreparation: packageAfterPreparation)
                } else {
                    if created.phase == .ready {
                        archiveURL = try await service.sharePreparedURL(packageID: created.id, format: .dropack)
                    }
                    if needsPhotoReselection { message = pickerRecoveryMessage }
                    onCreated?(created.id)
                }
            } catch { await handle(error, packageID: createdID) }
            await refreshLibrary()
        }
        worker = task
        await task.value
        return createdID
    }

    /// Pending grants can span an earlier paused draft and a new addition. Only
    /// exact persisted tokens/Photos identifiers are accepted; an unrelated picker
    /// result can never replace a missing original simply by filename or index.
    private func retainedSelection(for job: PackageJob) -> PhotoPickerSelection? {
        let pending = job.assets.filter { $0.pickerResourcePending == true }
        guard !pending.isEmpty else { return nil }
        let candidates = (pickerSelections[job.id]?.items ?? [])
            + pickerSelections.filter { $0.key != job.id }.flatMap { $0.value.items }
        var items: [PhotoPickerSelection.Item] = []
        var used = Set<UUID>()
        for asset in pending {
            let exact = candidates.first { $0.id == asset.pickerSelectionItemID && !used.contains($0.id) }
            let byIdentifier = asset.pickerAssetIdentifier.flatMap { identifier in
                candidates.first { $0.assetIdentifier == identifier && !used.contains($0.id) }
            }
            guard let selected = exact ?? byIdentifier, selected.kind == asset.kind else { return nil }
            used.insert(selected.id); items.append(selected)
        }
        let selection = PhotoPickerSelection(items: items)
        guard (try? selection.resources(for: job)) != nil else { return nil }
        return selection
    }

    /// Kept for older callers. New selections always make a separate package.
    func replace(assetIdentifiers: [String]) async {
        await create(assetIdentifiers: assetIdentifiers)
    }

    func resume() { resume(userInitiated: true) }

    private func resume(userInitiated: Bool) {
        guard canResume, let packageID = job?.id else { return }
        isBusy = true; message = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let token = UUID(); progressToken = token
        beginBackgroundExecution(token: token, userInitiated: userInitiated)
        attemptPackageID = packageID
        activity.begin(token: token, initial: activitySnapshot(
            stage: job?.packagingRequested == false ? "读取所选资源" : "继续打包"))
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.finishOperation() }
            do { try await run(packageID: packageID, token: token,
                               packageAfterPreparation: job?.packagingRequested != false) }
            catch { await handle(error, packageID: packageID) }
            await refreshLibrary()
        }
    }

    func pause() {
        // A manual pause must never be undone by foreground reconciliation.
        backgroundResumePackageID = nil
        requestPause()
    }

    private func requestPause() {
        guard canPause, let token = progressToken else { return }
        isPauseRequested = true
        activity.suspend(token: token)
        worker?.cancel()
        message = "正在暂停，保留已完成的照片并恢复当前 ZIP 检查点…"
    }

    @discardableResult
    func deletePackage(id: UUID) async -> Bool {
        guard !isBusy else { message = "请先暂停，等待当前操作结束后再删除照片包。"; return false }
        isBusy = true
        defer { activity.reset(snapshot: activitySnapshot()); isBusy = false }
        do {
            let identity = await deletionIdentity(for: id)
            try await service.deletePackage(id: id)
            for revision in identity.revisions { pickerSelections.removeValue(forKey: revision) }
            if job?.id == id || recoveryFailureID == id ||
                (identity.albumID != nil && job?.stableAlbumID == identity.albumID) {
                job = nil; archiveURL = nil; message = nil; requiresReset = false; recoveryFailureID = nil
            }
            await refreshLibrary()
            return true
        } catch {
            message = "无法删除照片包：\(error.localizedDescription)"
            return false
        }
    }

    func clear() {
        guard !isBusy, let id = job?.id ?? recoveryFailureID else { return }
        // Match the old synchronous entry point, but reserve the operation before
        // returning so callers waiting on isBusy cannot race the deletion task.
        isBusy = true
        activity.reset(snapshot: activitySnapshot(stage: "清理照片包"))
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.finishOperation() }
            do {
                let identity = await deletionIdentity(for: id)
                try await service.deletePackage(id: id)
                for revision in identity.revisions { pickerSelections.removeValue(forKey: revision) }
                job = nil; archiveURL = nil; message = nil; requiresReset = false; recoveryFailureID = nil
            } catch { message = "无法清除照片包：\(error.localizedDescription)"; requiresReset = true }
            await refreshLibrary()
        }
    }

    /// A library delete removes every local revision of one sharing album. A
    /// currently selected newer revision must not retain URLs to deleted files.
    /// This identity lookup never changes the system Photos album or its members.
    private func deletionIdentity(for id: UUID) async -> (albumID: UUID?, revisions: Set<UUID>) {
        // A corrupt journal must remain removable through the recovery UI.
        let albumID = (try? await service.job(packageID: id))?.stableAlbumID
        var revisions: Set<UUID> = [id]
        if let albumID {
            for revision in Array(pickerSelections.keys) {
                if (try? await service.job(packageID: revision))?.stableAlbumID == albumID { revisions.insert(revision) }
            }
        }
        return (albumID, revisions)
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        UIApplication.shared.isIdleTimerDisabled = false
        backgroundExecution.sceneDidEnterBackground()
    }

    func sceneDidBecomeActive() {
        isInBackground = false
        backgroundExecution.sceneDidBecomeActive()
        UIApplication.shared.isIdleTimerDisabled = canPause
        resumeAfterSystemPauseIfPossible()
    }

    private func run(packageID: UUID, token: UUID, packageAfterPreparation: Bool) async throws {
        // Resource callbacks originate on PhotoKit/provider/I/O queues. Stamp
        // them before hopping to MainActor so scheduling cannot regress the
        // visible asset or erase a checkpoint that is still being throttled.
        let sequence = PackageProgressSequence()
        let report: @Sendable (PackageUpdate) -> Void = { [weak self] update in
            let ordinal = sequence.next()
            Task { @MainActor [weak self] in
                guard let self, self.progressToken == token else { return }
                self.activity.receive(token: token, completedCount: update.job?.completedCount,
                    totalCount: update.job?.totalCount, stage: update.stage,
                    name: update.name, fraction: update.fraction, readBytes: update.readBytes,
                    packageID: packageID, assetID: update.assetID,
                    completedAssetIDs: update.job.map { Set($0.assets.filter(\.isCompleted).map(\.id)) },
                    originalProgress: update.originalProgress, packingFraction: update.packingFraction,
                    sequence: ordinal)
            }
        }
        if let current = try await service.job(packageID: packageID),
           current.assets.contains(where: { $0.pickerResourcePending == true }) {
            guard let selection = retainedSelection(for: current) else {
                throw PhotoPackageError.pickerReselection
            }
            try await service.preparePickerSources(packageID: packageID, selection: selection, progress: report)
            let capturedTokens = Set(selection.items.map(\.id))
            for id in Array(pickerSelections.keys) {
                guard let retained = pickerSelections[id] else { continue }
                let remaining = retained.items.filter { !capturedTokens.contains($0.id) }
                pickerSelections[id] = remaining.isEmpty ? nil : PhotoPickerSelection(items: remaining)
            }
            job = try await service.job(packageID: packageID)
            await refreshLibrary()
        }
        if packageAfterPreparation {
            let result = try await service.run(packageID: packageID, progress: report)
            job = result.job; archiveURL = result.archiveURL
        } else {
            job = try await service.job(packageID: packageID)
            archiveURL = nil
        }
        message = nil
    }

    private func handle(_ error: Error, packageID: UUID?) async {
        archiveURL = nil
        if let packageID, let latest = try? await service.job(packageID: packageID) { job = latest }
        if error is CancellationError {
            message = "已暂停，完成的照片已保留。继续时会重新读取当前未完成的一项。"
        } else {
            message = error.localizedDescription
            if error is PackageModelError { requiresReset = true }
            if case PhotoPackageError.archiveMismatch = error { requiresReset = true }
            if requiresReset { recoveryFailureID = packageID }
        }
    }

    private func finishOperation() {
        let token = progressToken
        progressToken = nil
        if token != nil {
            let preparedDraft = job?.isDraft == true && job?.assets.contains { $0.pickerResourcePending == true } == false
            backgroundExecution.finish(success: (archiveURL != nil && job?.phase == .ready) || preparedDraft)
        }
        if let token { activity.finish(token: token, final: activitySnapshot()) }
        else { activity.reset(snapshot: activitySnapshot()) }
        isBusy = false; worker = nil; isPauseRequested = false
        UIApplication.shared.isIdleTimerDisabled = false
        // Allow the cancelled task to unwind fully before admitting a successor.
        attemptPackageID = nil
        if backgroundResumePackageID != nil, !isInBackground {
            Task { [weak self] in
                await Task.yield()
                self?.resumeAfterSystemPauseIfPossible()
            }
        }
    }

    private func activitySnapshot(stage: String = "") -> PackageActivitySnapshot {
        PackageActivitySnapshot(completedCount: job?.completedCount ?? 0,
                                totalCount: job?.totalCount ?? 0, stage: stage,
                                packageID: job?.id,
                                completedAssetIDs: Set(job?.assets.filter(\.isCompleted).map(\.id) ?? []))
    }
    private func beginBackgroundExecution(token: UUID, userInitiated: Bool = true) {
        isPauseRequested = false
        attemptPackageID = nil
        backgroundResumePackageID = nil
        backgroundExecution.begin(token: token, userInitiated: userInitiated, onExpiration: { [weak self] reason in
            guard let self, self.progressToken == token, !self.isPauseRequested else { return }
            // Only an OS time budget pause is automatically continued on return.
            // A user's Stop in the system task UI remains an explicit pause.
            self.backgroundResumePackageID = reason == .timeLimit ? self.attemptPackageID : nil
            self.requestPause()
        }, onSystemProgress: { [weak self] presented in
            guard let self, self.progressToken == token || (self.progressToken == nil && !presented) else { return }
            self.usesSystemBackgroundProgress = presented
        })
    }

    private func resumeAfterSystemPauseIfPossible() {
        guard let expectedID = backgroundResumePackageID, !isInBackground, !isBusy else { return }
        backgroundResumePackageID = nil
        guard canResume, job?.id == expectedID, job?.phase != .failed else { return }
        resume(userInitiated: false)
    }
}

/// Shared by picker preparation and ZIP work for one controller attempt.
private final class PackageProgressSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
