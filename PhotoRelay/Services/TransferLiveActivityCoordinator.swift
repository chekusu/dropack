import ActivityKit
import Combine
import Foundation
import UIKit

/// Local presentation only: a Live Activity never grants background execution.
/// Requests and updates are serialized on MainActor; updates never overlap an
/// end operation. Call receive only with the current durable controller state.
@MainActor
final class TransferLiveActivityCoordinator: ObservableObject {
    typealias Attributes = TransferActivityAttributes
    typealias State = Attributes.ContentState
    typealias Kind = Attributes.Kind
    private typealias NativeActivity = Activity<Attributes>

    @Published private(set) var presentedJobIDs: Set<UUID> = []
    /// Session history only. Ending a native activity must not cause an old
    /// custom completion banner to reappear for a job already presented natively.
    @Published private(set) var hasPresentedJobIDs: Set<UUID> = []
    @Published private(set) var fallbackReason: String?

    private struct Desired: Equatable, Sendable {
        let jobID: UUID
        let kind: Kind
        let state: State
        let isWorking: Bool
        var removeImmediately = false
    }

    private let authorization = ActivityAuthorizationInfo()
    private var activities: [UUID: NativeActivity] = [:]
    private var duplicatesToEnd: [NativeActivity] = []
    private var latest: [UUID: Desired] = [:]
    private var buffers: [UUID: TransferActivityUpdateBuffer<Desired>] = [:]
    private var lifetimes: [UUID: TransferActivityLifecyclePolicy] = [:]
    private var intentionalEnds: Set<String> = []
    private var observers: [String: Task<Void, Never>] = [:]
    private var permissionObserver: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var wakeGeneration = UUID()
    private var heartbeat: Task<Void, Never>?

    init() {
        restoreExistingActivities()
        let authorization = self.authorization
        permissionObserver = Task { [weak self] in
            for await enabled in authorization.activityEnablementUpdates {
                guard let self, !Task.isCancelled else { return }
                self.authorizationDidChange(enabled)
            }
        }
    }

    deinit {
        permissionObserver?.cancel()
        worker?.cancel()
        wake?.cancel()
        heartbeat?.cancel()
        for observer in observers.values { observer.cancel() }
    }

    func isPresented(jobID: UUID) -> Bool { presentedJobIDs.contains(jobID) }

    /// A nonworking `.running` snapshot is normalized to paused. This is vital
    /// during journal restoration: an old running marker is not a running job.
    func receive(jobID: UUID, kind: Kind, state: State, isWorking: Bool) {
        let actualWork = isWorking && state.stage == .running
        var lifetime = lifetimes[jobID] ?? TransferActivityLifecyclePolicy()
        let accepts = lifetime.accept(isWorking: actualWork)
        lifetimes[jobID] = lifetime
        guard accepts else { return }
        let normalized = State(completed: state.completed, total: state.total,
                               stage: !isWorking && state.stage == .running ? .paused : state.stage,
                               languageCode: state.languageCode, currentFraction: state.currentFraction,
                               currentReadBytes: state.currentReadBytes)
        let desired = Desired(jobID: jobID, kind: kind, state: normalized,
                              isWorking: isWorking && normalized.stage == .running)
        latest[jobID] = desired
        enqueue(desired, urgent: normalized.stage != .running)
        refreshPresentation()
    }

    /// Delete/clear only removes the system presentation; no media is touched.
    /// Paused/restore callbacks cannot recreate it. An actual resumed run of the
    /// same library job may re-enable it, unless the person dismissed that job.
    func clear(jobID: UUID) {
        var lifetime = lifetimes[jobID] ?? TransferActivityLifecyclePolicy()
        lifetime.clear()
        lifetimes[jobID] = lifetime
        guard let desired = latest[jobID] ?? activities[jobID].map({
            Desired(jobID: jobID, kind: $0.attributes.kind, state: $0.content.state, isWorking: false)
        }) else { return }
        let cleared = Desired(jobID: jobID, kind: desired.kind,
            state: State(completed: desired.state.completed, total: desired.state.total, stage: .paused),
            isWorking: false, removeImmediately: true)
        latest[jobID] = cleared
        enqueue(cleared, urgent: true)
        refreshPresentation()
    }

    func clearAll() {
        for jobID in Set(latest.keys).union(activities.keys) { clear(jobID: jobID) }
    }

    /// Call once after both controllers finish restoring their journals. Until
    /// then, an absent in-memory job is not evidence that its activity is stale.
    func reconcile(validJobIDs: Set<UUID>) {
        let obsolete = Set(activities.keys).union(latest.keys).subtracting(validJobIDs)
        for jobID in obsolete {
            // clear queues its own final payload before we discard the cache;
            // the serialized end therefore still has the last confirmed count.
            clear(jobID: jobID)
            latest.removeValue(forKey: jobID)
        }
        refreshPresentation()
    }

    /// Foreground-only request failures caused by backgrounding are deferred.
    /// A dismissed/failed session remains suppressed; this is not a retry loop.
    func sceneDidBecomeActive() {
        authorizationDidChange(authorization.areActivitiesEnabled)
        guard authorization.areActivitiesEnabled else { return }
        for value in latest.values where value.isWorking && lifetimes[value.jobID]?.isSuppressed != true {
            enqueue(value, urgent: false, force: true)
        }
    }

    private func restoreExistingActivities() {
        // Keep the most advanced duplicate deterministically; all other records
        // of the same task are ended before this coordinator makes any requests.
        let existing = NativeActivity.activities.sorted {
            if $0.content.state.completed != $1.content.state.completed {
                return $0.content.state.completed > $1.content.state.completed
            }
            return $0.id < $1.id
        }

        for activity in existing {
            guard activity.activityState != .ended && activity.activityState != .dismissed else { continue }
            let id = activity.attributes.jobID
            guard activities[id] == nil else { duplicatesToEnd.append(activity); continue }
            activities[id] = activity
            observe(activity)
            let old = activity.content.state
            // The root may replace this queued paused snapshot with actual work
            // before delivery. Otherwise it remains visibly paused; it must
            // never imply that a terminated process is still processing media.
            receive(jobID: id, kind: activity.attributes.kind,
                    state: State(completed: old.completed, total: old.total, stage: .paused), isWorking: false)
        }
        schedule()
        if !authorization.areActivitiesEnabled { authorizationDidChange(false) }
    }

    private func authorizationDidChange(_ enabled: Bool) {
        fallbackReason = enabled ? nil : "系统实时活动已关闭"
        if !enabled {
            for (id, activity) in activities {
                let content = latest[id]?.state ?? activity.content.state
                let paused = Desired(jobID: id, kind: activity.attributes.kind,
                    state: State(completed: content.completed, total: content.total, stage: .paused),
                    isWorking: false, removeImmediately: true)
                // Preserve latest actual work so a user enabling the setting in
                // the foreground can request a presentation for that work.
                enqueue(paused, urgent: true)
            }
        }
        refreshPresentation()
    }

    private func enqueue(_ desired: Desired, urgent: Bool, force: Bool = false) {
        var buffer = buffers[desired.jobID] ?? TransferActivityUpdateBuffer(interval: 1)
        buffer.enqueue(desired, urgent: urgent, force: force)
        buffers[desired.jobID] = buffer
        schedule()
    }

    private func schedule() {
        guard worker == nil else { return }
        wake?.cancel(); wake = nil
        wakeGeneration = UUID()
        let now = ProcessInfo.processInfo.systemUptime
        guard let delay = duplicatesToEnd.isEmpty ? buffers.values.compactMap({ $0.delay(at: now) }).min() : 0 else { return }
        if delay <= 0 {
            worker = Task { [weak self] in await self?.drain() }
        } else {
            let generation = wakeGeneration
            wake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.wakeGeneration == generation, !Task.isCancelled else { return }
                self.wake = nil
                self.schedule()
            }
        }
    }

    private func drain() async {
        while let duplicate = duplicatesToEnd.popLast() {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            guard let id = buffers.first(where: { $0.value.delay(at: now) == 0 })?.key,
                  var buffer = buffers[id], let desired = buffer.take(at: now) else { break }
            buffers[id] = buffer
            await deliver(desired)
        }
        worker = nil
        refreshPresentation()
        schedule()
        scheduleHeartbeat()
    }

    private func deliver(_ desired: Desired) async {
        let id = desired.jobID
        let lifetime = lifetimes[id] ?? TransferActivityLifecyclePolicy()
        let mode: TransferActivityLifecyclePolicy.Mode = desired.isWorking ? .working
            : desired.state.stage == .paused ? .paused : .terminal
        switch lifetime.action(mode: mode, hasActivity: activities[id] != nil,
                               activitiesEnabled: authorization.areActivitiesEnabled,
                               removeImmediately: desired.removeImmediately) {
        case .none: return
        case .end:
            if let activity = activities[id] {
                let state = desired.state.stage == .running
                    ? State(completed: desired.state.completed, total: desired.state.total, stage: .paused) : desired.state
                await end(activity, state: state, immediately: desired.removeImmediately || !authorization.areActivitiesEnabled)
            }
            return
        case .update:
            guard let activity = activities[id] else { return }
            guard activity.activityState != .ended && activity.activityState != .dismissed else {
                systemDidEnd(activity)
                return
            }
            // Pause is an update, not an end: it stays in the Dynamic Island
            // with an honest paused state and no running heartbeat/stale date.
            await activity.update(content(desired.state))
            return
        case .request: break
        }
        guard UIApplication.shared.applicationState == .active else {
            fallbackReason = "回到应用后可显示系统实时活动"
            return
        }
        // There is at most one activity per workflow. A newer actual task ends
        // its predecessor; package and import may each have one activity.
        for old in activities.values.filter({ $0.attributes.kind == desired.kind && $0.attributes.jobID != id }) {
            let value = old.content.state
            await end(old, state: State(completed: value.completed, total: value.total, stage: .paused), immediately: true)
        }
        guard latest[id]?.isWorking == true, lifetimes[id]?.isCleared != true,
              authorization.areActivitiesEnabled else { return }
        // request is synchronous and this queue is serial: a callback burst can
        // never race two requests for the same task.
        do {
            let activity = try NativeActivity.request(attributes: Attributes(jobID: id, kind: desired.kind),
                                                       content: content(desired.state), pushType: nil)
            activities[id] = activity
            fallbackReason = nil
            observe(activity)
            refreshPresentation()
        } catch {
            var lifetime = lifetimes[id] ?? TransferActivityLifecyclePolicy()
            lifetime.suppress()
            lifetimes[id] = lifetime
            fallbackReason = "系统实时活动暂不可用"
        }
    }

    private func content(_ state: State) -> ActivityContent<State> {
        // A crashed/suspended process cannot leave an indefinitely fresh running
        // indicator. The widget must render isStale as waiting to continue.
        ActivityContent(state: state, staleDate: state.stage == .running ? Date().addingTimeInterval(90) : nil)
    }

    private func end(_ activity: NativeActivity, state: State, immediately: Bool) async {
        intentionalEnds.insert(activity.id)
        if activities[activity.attributes.jobID]?.id == activity.id {
            activities.removeValue(forKey: activity.attributes.jobID)
        }
        refreshPresentation()
        let linger: TimeInterval = state.stage == .finished ? 60 : 120
        await activity.end(content(state), dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(linger)))
        observers.removeValue(forKey: activity.id)?.cancel()
        intentionalEnds.remove(activity.id)
    }

    private func observe(_ activity: NativeActivity) {
        observers[activity.id]?.cancel()
        observers[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                if state == .ended || state == .dismissed { self.systemDidEnd(activity); return }
                self.refreshPresentation()
            }
        }
    }

    private func systemDidEnd(_ activity: NativeActivity) {
        guard !intentionalEnds.contains(activity.id) else { return }
        let id = activity.attributes.jobID
        guard activities[id]?.id == activity.id else { return }
        activities.removeValue(forKey: id)
        var lifetime = lifetimes[id] ?? TransferActivityLifecyclePolicy()
        lifetime.suppress()
        lifetimes[id] = lifetime
        observers.removeValue(forKey: activity.id)?.cancel()
        fallbackReason = "系统实时活动已结束"
        refreshPresentation()
    }

    private func refreshPresentation() {
        let activated = Set(activities.compactMap { id, activity in
            activity.activityState == .active ? id : nil
        })
        let firstActivations = activated.subtracting(hasPresentedJobIDs)
        if !firstActivations.isEmpty { hasPresentedJobIDs.formUnion(firstActivations) }
        let next = authorization.areActivitiesEnabled ? Set(activities.compactMap { id, activity in
            activity.activityState == .active && latest[id]?.removeImmediately != true
                && (latest[id]?.isWorking == true || latest[id]?.state.stage == .paused)
                && lifetimes[id]?.isCleared != true ? id : nil
        }) : []
        if next != presentedJobIDs { presentedJobIDs = next }
    }

    private func scheduleHeartbeat() {
        guard activities.keys.contains(where: { latest[$0]?.isWorking == true }) else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.heartbeat = nil
            for id in self.activities.keys {
                if let value = self.latest[id], value.isWorking { self.enqueue(value, urgent: false, force: true) }
            }
            self.scheduleHeartbeat()
        }
    }
}
