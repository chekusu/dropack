import Combine
import Foundation

/// Availability of the exact original(s) used by this attempt. A thumbnail does
/// not prove an original is local, and a download reaching 100% is not success.
/// This is deliberately transient; only captured picker sources / ZIP journal
/// records survive an attempt, never a guess about PhotoKit's future cache.
struct PackageOriginalProgress: Equatable, Sendable {
    enum State: Equatable, Sendable { case unknown, preparing, downloading, ready }
    let state: State
    let fraction: Double?
    let cloudConfirmed: Bool

    init(state: State, fraction: Double? = nil, cloudConfirmed: Bool = false) {
        self.state = state
        self.fraction = (state == .preparing || state == .downloading)
            ? fraction.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil } : nil
        self.cloudConfirmed = cloudConfirmed || state == .downloading
    }

    static let unknown = Self(state: .unknown)
    static let ready = Self(state: .ready)
}

/// A single, bounded progress value. Completed counts describe committed ZIP
/// checkpoints; `fraction` describes the current preparation or packing stage,
/// never the whole album. The two thumbnail indicators use their typed fields.
struct PackageActivitySnapshot: Equatable, Sendable {
    /// Snapshot identity, independent of display names and stable album aliases.
    let packageID: UUID?
    /// The journal's item ID, shared by both resources of a Live Photo.
    let assetID: String?
    /// Only assets committed to a durable ZIP checkpoint are complete.
    let completedAssetIDs: Set<String>
    let completedCount: Int
    let totalCount: Int
    let stage: String
    let name: String
    let fraction: Double
    /// Actual bytes written for a PhotoKit resource whose total is unknown.
    let readBytes: UInt64?
    /// Sparse, per-item original preparation state. ZIP completion is separate.
    let originalProgressByAssetID: [String: PackageOriginalProgress]
    /// Current item's total bytes appended across all ZIP entries, including
    /// Live Photo pairs. Nil means the ZIP stage has not started for this item.
    let packingFraction: Double?

    init(completedCount: Int = 0, totalCount: Int = 0, stage: String = "",
         name: String = "", fraction: Double = 0, readBytes: UInt64? = nil,
         packageID: UUID? = nil, assetID: String? = nil, completedAssetIDs: Set<String> = [],
         originalProgressByAssetID: [String: PackageOriginalProgress] = [:], packingFraction: Double? = nil) {
        self.packageID = packageID
        self.assetID = assetID
        self.completedAssetIDs = completedAssetIDs
        self.totalCount = max(0, totalCount)
        self.completedCount = max(0, min(completedCount, self.totalCount))
        self.stage = stage
        self.name = name
        self.readBytes = readBytes
        self.fraction = fraction.isFinite ? max(0, min(1, fraction)) : 0
        self.originalProgressByAssetID = originalProgressByAssetID
        self.packingFraction = packingFraction.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
    }
}

/// Observe this object only from the task panel. Its changes deliberately do not
/// propagate through PackageController's objectWillChange to the page/navigation.
@MainActor
final class PackageActivity: ObservableObject {
    @Published private(set) var snapshot = PackageActivitySnapshot()

    private let interval: Duration
    private let clock = ContinuousClock()
    private var lastPublication: ContinuousClock.Instant?
    private var token: UUID?
    private var acceptsUpdates = false
    private var lastSequence: UInt64?
    private var originalSequences: [String: UInt64] = [:]
    private var latest = PackageActivitySnapshot()
    private var pendingPublication: Task<Void, Never>?
    private var publicationGeneration = UUID()

    init(interval: Duration = .milliseconds(200)) {
        self.interval = max(.zero, interval)
    }

    func begin(token: UUID, initial: PackageActivitySnapshot) {
        cancelPendingPublication()
        self.token = token
        acceptsUpdates = true
        lastSequence = nil
        originalSequences = [:]
        latest = initial
        publish(initial)
        lastPublication = clock.now
    }

    /// Missing counts mean a resource-only update. Merge with the latest received
    /// checkpoint, including one that has not reached the screen yet.
    func receive(token: UUID, completedCount: Int? = nil, totalCount: Int? = nil,
                 stage: String, name: String, fraction: Double, readBytes: UInt64? = nil,
                 packageID: UUID? = nil, assetID: String? = nil,
                 completedAssetIDs: Set<String>? = nil,
                 originalProgress: PackageOriginalProgress? = nil, packingFraction: Double? = nil,
                 sequence: UInt64? = nil) {
        guard self.token == token, acceptsUpdates else { return }
        // A callback cannot move an active task to a different archive. A new
        // attempt always calls begin with a fresh token and its own journal.
        if let packageID, let currentID = latest.packageID, packageID != currentID { return }
        let isOlder = sequence.map { $0 <= (lastSequence ?? 0) } ?? false
        if let sequence, !isOlder { lastSequence = sequence }
        // A checkpoint callback may arrive after a subsequent resource callback
        // on the main actor. Merge its durable identities even when its transient
        // stage/asset must be discarded. Nil means no new journal was supplied.
        let committedIDs = latest.completedAssetIDs.union(completedAssetIDs ?? [])
        var originals = latest.originalProgressByAssetID
        if let assetID, let originalProgress, !committedIDs.contains(assetID) {
            // A late update for a different item may still carry a valid captured
            // source. Order these per item, independently of the current stage.
            let isOldOriginal = sequence.map { $0 <= (originalSequences[assetID] ?? 0) } ?? false
            if !isOldOriginal {
                originals[assetID] = PackageOriginalProgress(state: originalProgress.state,
                    fraction: originalProgress.fraction,
                    cloudConfirmed: originalProgress.cloudConfirmed || originals[assetID]?.cloudConfirmed == true)
                if let sequence { originalSequences[assetID] = sequence }
            }
        }
        for assetID in completedAssetIDs ?? [] {
            originals.removeValue(forKey: assetID)
            originalSequences.removeValue(forKey: assetID)
        }
        latest = PackageActivitySnapshot(
            completedCount: max(latest.completedCount, completedCount ?? latest.completedCount),
            totalCount: isOlder ? latest.totalCount : (totalCount ?? latest.totalCount),
            stage: isOlder ? latest.stage : stage,
            name: isOlder ? latest.name : name,
            fraction: isOlder ? latest.fraction : fraction,
            readBytes: isOlder ? latest.readBytes : readBytes,
            packageID: latest.packageID ?? packageID,
            assetID: isOlder ? latest.assetID : assetID,
            completedAssetIDs: committedIDs,
            originalProgressByAssetID: originals,
            packingFraction: isOlder ? latest.packingFraction : packingFraction)
        guard latest != snapshot else { return }

        let elapsed = lastPublication.map { $0.duration(to: clock.now) } ?? interval
        if elapsed >= interval {
            cancelPendingPublication()
            publish(latest)
            return
        }
        // This is a latest-value throttle, not a debounce: a stream of callbacks
        // cannot keep pushing the publication deadline into the future.
        guard pendingPublication == nil else { return }
        let generation = publicationGeneration
        let delay = interval - elapsed
        pendingPublication = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled, self.token == token,
                  self.acceptsUpdates, self.publicationGeneration == generation else { return }
            self.pendingPublication = nil
            self.publish(self.latest)
        }
    }

    /// Pause waits for the real ZIP rollback/checkpoint. Keep the last confirmed
    /// count visible while preventing queued resource callbacks from restarting it.
    func suspend(token: UUID) {
        guard self.token == token else { return }
        acceptsUpdates = false
        cancelPendingPublication()
        publish(latest)
    }

    /// Terminal state is authoritative and immediate, even inside the throttle
    /// window. Old callbacks and pending publications cannot overwrite it.
    func finish(token: UUID, final: PackageActivitySnapshot) {
        guard self.token == token else { return }
        reset(snapshot: final)
    }

    func reset(snapshot: PackageActivitySnapshot = PackageActivitySnapshot()) {
        cancelPendingPublication()
        token = nil
        acceptsUpdates = false
        lastSequence = nil
        originalSequences = [:]
        latest = snapshot
        publish(snapshot)
    }

    private func publish(_ value: PackageActivitySnapshot) {
        guard value != snapshot else { return }
        snapshot = value
        lastPublication = clock.now
    }

    private func cancelPendingPublication() {
        pendingPublication?.cancel()
        pendingPublication = nil
        publicationGeneration = UUID()
    }
}
