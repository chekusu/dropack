import Combine
import Foundation

/// Keeps frequent progress events out of the navigation view. Only the
/// coordinator's presentation availability is observed by the app's UI.
@MainActor
final class TransferLiveActivityBridge: ObservableObject {
    private let package: PackageController
    private let importer: ImportController
    private let coordinator: TransferLiveActivityCoordinator
    private var subscriptions = Set<AnyCancellable>()
    private var pendingSync: Task<Void, Never>?
    private var packageID: UUID?
    private var importID: UUID?
    private var backgrounded = false
    private var reconciledRestoration = false

    init(package: PackageController, importer: ImportController,
         coordinator: TransferLiveActivityCoordinator) {
        self.package = package
        self.importer = importer
        self.coordinator = coordinator
        watch(package.$job)
        watch(package.$isBusy)
        watch(package.$isPauseRequested)
        watch(package.$usesSystemBackgroundProgress)
        watch(package.$requiresReset)
        watch(package.$archiveURL)
        watch(package.activity.$snapshot.removeDuplicates())
        watch(importer.$job)
        watch(importer.$isBusy)
        watch(importer.$isPreparing)
        watch(importer.$requiresReset)
        watch(importer.$needsRelink)
        watch(AppPreferences.shared.$language)
    }

    func sceneDidBecomeActive() {
        backgrounded = false
        coordinator.sceneDidBecomeActive()
        scheduleSync()
    }

    func sceneDidEnterBackground() {
        // Packaging may keep running under a real background execution grant.
        // Photo-library import continues to use its separate pause policy.
        backgrounded = true
        sync()
    }

    private func watch<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &subscriptions)
    }

    private func scheduleSync() {
        guard pendingSync == nil else { return }
        pendingSync = Task { [weak self] in
            // @Published sends before the property changes. Read the completed
            // controller transition once, rather than a partly updated tuple.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingSync = nil
            self.sync()
        }
    }

    private func sync() {
        if !reconciledRestoration, !importer.isPreparing, (!package.isBusy || package.canPause) {
            reconciledRestoration = true
            coordinator.reconcile(validJobIDs: Set([package.job?.id, importer.job?.id].compactMap { $0 }))
        }
        if let old = packageID, old != package.job?.id { coordinator.clear(jobID: old) }
        packageID = package.job?.id
        if let job = package.job, package.usesSystemBackgroundProgress {
            coordinator.clear(jobID: job.id)
        } else if let job = package.job {
            let snapshot = package.activity.snapshot
            let completed = snapshot.totalCount == job.totalCount
                ? max(job.completedCount, snapshot.completedCount) : job.completedCount
            let running = package.canPause
            let stage: TransferActivityAttributes.Stage = TransferActivityStagePolicy.resolve(
                isFinished: job.phase == .ready && package.archiveURL != nil,
                needsReset: package.requiresReset, isWorking: running,
                hasPriorFailure: job.phase == .failed && !package.canPause,
                finished: .finished, failed: .failed, running: .running, paused: .paused)
            coordinator.receive(jobID: job.id, kind: .packaging,
                state: .init(completed: completed, total: job.totalCount, stage: stage,
                             currentFraction: snapshot.name.isEmpty || snapshot.readBytes != nil ? nil : snapshot.fraction,
                             currentReadBytes: snapshot.readBytes),
                isWorking: running)
        }

        if let old = importID, old != importer.job?.id { coordinator.clear(jobID: old) }
        importID = importer.job?.id
        if let job = importer.job {
            let running = importer.isBusy && job.phase == .running && !backgrounded
            let stage: TransferActivityAttributes.Stage
            if job.phase == .completed { stage = .finished }
            else if importer.requiresReset || importer.needsRelink
                || (!importer.isBusy && (job.failedCount > 0 || job.uncertainCount > 0)) { stage = .failed }
            else { stage = running ? .running : .paused }
            coordinator.receive(jobID: job.id, kind: .importing,
                state: .init(completed: job.savedCount, total: job.items.count, stage: stage),
                isWorking: running)
        }
    }
}
