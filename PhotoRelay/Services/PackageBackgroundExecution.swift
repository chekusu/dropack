import BackgroundTasks
import Foundation
import UIKit

enum PackageBackgroundExpirationReason: Equatable, Sendable {
    /// A short UIKit assertion is running out. The user may resume in foreground.
    case timeLimit
    /// Continued processing was stopped by the system or its user-facing UI.
    /// The API does not distinguish those two causes; neither is auto-retried.
    case systemCancelled
}

@MainActor
protocol PackageBackgroundManaging: AnyObject {
    func begin(token: UUID, userInitiated: Bool,
               onExpiration: @escaping @MainActor (PackageBackgroundExpirationReason) -> Void,
               onSystemProgress: @escaping @MainActor (Bool) -> Void)
    func update(_ snapshot: PackageActivitySnapshot)
    func finish(success: Bool)
    func sceneDidEnterBackground()
    func sceneDidBecomeActive()
}

/// Owns execution assertions, not the packaging worker or its checkpoint.
/// The controller starts exactly one worker and calls finish only after that
/// worker has completed its ZIP commit or rollback. A Live Activity on its own
/// never grants background runtime.
@MainActor
final class PackageBackgroundExecution: PackageBackgroundManaging {
    static let shared = PackageBackgroundExecution()
    static let permittedIdentifier = "app.dropack.ios.package.*"

    private var token: UUID?
    private var onExpiration: (@MainActor (PackageBackgroundExpirationReason) -> Void)?
    private var onSystemProgress: (@MainActor (Bool) -> Void)?
    private var expirationDelivered = false
    private var reportsSystemProgress = false
    private var latest = PackageActivitySnapshot()
    private var isInBackground = false

    private var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var shortTaskGeneration: UUID?
    private var deadlineMonitor: Task<Void, Never>?
    // BGTask is available on the app's iOS 17 deployment target. Access to its
    // continued-processing subclass is confined to iOS 26 availability checks.
    private var systemTask: BGTask?
    private var pendingRequestIdentifier: String?
    private var registeredIdentifiers = Set<String>()

    private init() {}

    func begin(token: UUID, userInitiated: Bool,
               onExpiration: @escaping @MainActor (PackageBackgroundExpirationReason) -> Void,
               onSystemProgress: @escaping @MainActor (Bool) -> Void) {
        // Replacing a live owner could revoke runtime from a ZIP rollback.
        // PackageController serializes attempts and must finish the old one first.
        guard self.token == nil else { return }
        self.token = token
        self.onExpiration = onExpiration
        self.onSystemProgress = onSystemProgress
        expirationDelivered = false
        latest = PackageActivitySnapshot()
        isInBackground = UIApplication.shared.applicationState == .background
        onSystemProgress(false)
        beginShortTask(token: token)
        // A resumed checkpoint also requires an explicit foreground user action.
        // Never submit a continued task merely because the scene backgrounded.
        if #available(iOS 26.0, *), userInitiated,
           UIApplication.shared.applicationState == .active {
            requestContinuedProcessing(token: token)
        }
        if isInBackground { monitorDeadline(token: token) }
    }

    func update(_ snapshot: PackageActivitySnapshot) {
        guard token != nil, !expirationDelivered else { return }
        latest = snapshot
        if #available(iOS 26.0, *), let task = systemTask as? BGContinuedProcessingTask {
            updateSystemProgress(task)
        }
    }

    func finish(success: Bool) {
        // Invalidate callbacks before releasing any OS-owned object. A delayed
        // handler from this attempt must never cancel a later packaging job.
        token = nil
        deadlineMonitor?.cancel()
        deadlineMonitor = nil
        if let identifier = pendingRequestIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        pendingRequestIdentifier = nil
        let completedTask = systemTask
        systemTask = nil
        if #available(iOS 26.0, *), success,
           let continued = completedTask as? BGContinuedProcessingTask {
            if continued.progress.totalUnitCount <= 0 { continued.progress.totalUnitCount = 1_000 }
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
        }
        completedTask?.setTaskCompleted(success: success)
        endShortTask()
        setReportsSystemProgress(false)
        onExpiration = nil
        onSystemProgress = nil
        expirationDelivered = false
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        guard let token, !expirationDelivered, systemTask == nil else { return }
        // Short runtime is a fallback, not a promise to complete a 30 GB video.
        // Give cancellation/ZIP rollback a five-second head start before expiry.
        monitorDeadline(token: token)
    }

    func sceneDidBecomeActive() {
        isInBackground = false
        deadlineMonitor?.cancel()
        deadlineMonitor = nil
        guard let token, !expirationDelivered, systemTask == nil else { return }
        // If no assertion could be granted previously, a fresh foreground lease
        // may protect this still-running attempt's next background transition.
        beginShortTask(token: token)
    }

    private func beginShortTask(token: UUID) {
        guard shortTask == .invalid, self.token == token, !expirationDelivered else { return }
        let generation = UUID()
        shortTaskGeneration = generation
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "DropackPackageCheckpoint") { [weak self] in
            // UIKit documents synchronous invocation on the main thread. Do not
            // defer endBackgroundTask to another Task: suspension may follow as
            // soon as this expiration handler returns.
            MainActor.assumeIsolated {
                guard let self, self.shortTaskGeneration == generation else { return }
                if self.token == token, self.systemTask == nil {
                    self.deliverExpiration(.timeLimit, token: token)
                }
                self.endShortTask()
            }
        }
        // An assertion can be refused/expired during acquisition. Do not retain
        // a returned identifier after its synchronous expiration already ran.
        if shortTaskGeneration == generation {
            shortTask = identifier
        } else if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func endShortTask() {
        shortTaskGeneration = nil
        guard shortTask != .invalid else { return }
        let identifier = shortTask
        shortTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func monitorDeadline(token: UUID) {
        deadlineMonitor?.cancel()
        deadlineMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.token == token, self.isInBackground,
                      self.systemTask == nil, !self.expirationDelivered else { return }
                let remaining = UIApplication.shared.backgroundTimeRemaining
                if self.shortTask == .invalid || (remaining.isFinite && remaining <= 5) {
                    self.deliverExpiration(.timeLimit, token: token)
                    // Keep the assertion until finish() confirms the worker's
                    // rollback. Its real expiration handler is the final fallback.
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    private func deliverExpiration(_ reason: PackageBackgroundExpirationReason, token: UUID) {
        guard self.token == token, !expirationDelivered else { return }
        expirationDelivered = true
        deadlineMonitor?.cancel()
        deadlineMonitor = nil
        setReportsSystemProgress(false)
        // Acquisition itself may expire synchronously, before begin() returns
        // and the controller has installed its worker. Deliver on the next actor
        // turn, while ending UIKit's assertion synchronously in its handler.
        let callback = onExpiration
        Task { @MainActor [weak self] in
            guard let self, self.token == token, self.expirationDelivered else { return }
            callback?(reason)
        }
    }

    private func setReportsSystemProgress(_ enabled: Bool) {
        guard reportsSystemProgress != enabled else { return }
        reportsSystemProgress = enabled
        onSystemProgress?(enabled)
    }

    @available(iOS 26.0, *)
    private func requestContinuedProcessing(token: UUID) {
        guard self.token == token, !expirationDelivered else { return }
        let identifier = "app.dropack.ios.package.\(token.uuidString)"
        // Continued handlers may be registered after launch. Register concrete
        // identifiers, never the Info.plist wildcard, and never register twice.
        if !registeredIdentifiers.contains(identifier) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, let continued = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.accept(continued, token: token)
                }
            }
            guard registered else { return } // The bounded UIKit fallback remains.
            registeredIdentifiers.insert(identifier)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: "Dropack", subtitle: L10n.tr("正在打包"))
        request.strategy = .fail
        // Default resources permit CPU and network. ZIP/SHA do not require the
        // GPU entitlement. Queueing would introduce a second execution schedule.
        pendingRequestIdentifier = identifier
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            pendingRequestIdentifier = nil
            // System load, permission, or unsupported runtime must not strand the
            // foreground worker. Its short-task fallback is already active.
        }
    }

    @available(iOS 26.0, *)
    private func accept(_ task: BGContinuedProcessingTask, token: UUID) {
        guard self.token == token, !expirationDelivered, systemTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        pendingRequestIdentifier = nil
        systemTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.deliverExpiration(.systemCancelled, token: token)
            }
        }
        updateSystemProgress(task)
        deadlineMonitor?.cancel()
        deadlineMonitor = nil
        endShortTask()
        setReportsSystemProgress(true)
    }

    @available(iOS 26.0, *)
    private func updateSystemProgress(_ task: BGContinuedProcessingTask) {
        // This is explicitly the current resource's progress. Snapshot.fraction
        // resets for hashing, ZIP writing and the next resource; treating it as
        // monotonic whole-album progress would show 100% while gigabytes remain.
        let stage = latest.stage.isEmpty ? L10n.tr("正在打包") : L10n.tr(latest.stage)
        let count = latest.totalCount > 0 ? " · \(latest.completedCount)/\(latest.totalCount)" : ""
        if let bytes = latest.readBytes {
            // PhotoKit does not expose a reliable total size on iOS 26. Report
            // actual accumulated work with an indeterminate denominator instead
            // of fabricating a percentage or waiting for iCloud-only callbacks.
            task.progress.totalUnitCount = -1
            task.progress.completedUnitCount = Int64(clamping: bytes)
            let read = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
            task.updateTitle("Dropack", subtitle: stage + " · " + read + count)
        } else {
            task.progress.totalUnitCount = 1_000
            task.progress.completedUnitCount = min(999, Int64(latest.fraction * 1_000))
            task.updateTitle("Dropack", subtitle: stage + count)
        }
    }
}
