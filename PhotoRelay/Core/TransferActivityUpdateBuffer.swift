import Foundation

/// A latest-value throttle, not a debounce. Every burst has a fixed delivery
/// deadline; terminal state can replace a queued progress update immediately.
public struct TransferActivityUpdateBuffer<Value: Equatable & Sendable>: Sendable {
    public let interval: TimeInterval
    private var pending: Value?
    private var pendingIsUrgent = false
    private var lastDelivered: Value?
    private var lastDeliveryTime: TimeInterval?

    public init(interval: TimeInterval = 1) { self.interval = max(0, interval) }

    public mutating func enqueue(_ value: Value, urgent: Bool = false, force: Bool = false) {
        guard force || value != (pending ?? lastDelivered) else { return }
        pending = value
        // A later authoritative running state (explicit resume) may replace a
        // pause before it is delivered, while retaining the urgent deadline.
        pendingIsUrgent = pendingIsUrgent || urgent
    }

    public func delay(at now: TimeInterval) -> TimeInterval? {
        guard pending != nil else { return nil }
        guard !pendingIsUrgent, let lastDeliveryTime else { return 0 }
        return max(0, interval - (now - lastDeliveryTime))
    }

    public mutating func take(at now: TimeInterval) -> Value? {
        guard let delay = delay(at: now), delay <= 0, let value = pending else { return nil }
        pending = nil
        pendingIsUrgent = false
        lastDelivered = value
        lastDeliveryTime = now
        return value
    }
}
