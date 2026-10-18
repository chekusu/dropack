import Foundation

/// Per-task presentation lifetime. Clearing a selection can be reversed by an
/// actual resumed run; dismissal by the person/system is sticky for that task.
public struct TransferActivityLifecyclePolicy: Sendable {
    public enum Mode: Sendable { case working, paused, terminal }
    public enum Action: Equatable, Sendable { case none, request, update, end }
    public private(set) var isCleared = false
    public private(set) var isSuppressed = false

    public init() {}
    public mutating func clear() { isCleared = true }
    public mutating func suppress() { isSuppressed = true }

    /// A paused restore/callback cannot resurrect a cleared presentation. A
    /// genuine resumed operation may, even if it uses the same library job UUID.
    public mutating func accept(isWorking: Bool) -> Bool {
        if isWorking { isCleared = false }
        return !isCleared
    }

    public func action(mode: Mode, hasActivity: Bool, activitiesEnabled: Bool,
                       removeImmediately: Bool = false) -> Action {
        if !activitiesEnabled || removeImmediately || isCleared || mode == .terminal {
            return hasActivity ? .end : .none
        }
        if hasActivity { return .update } // Pause retains an existing activity.
        return mode == .working && !isSuppressed ? .request : .none
    }
}
