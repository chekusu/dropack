import Foundation

/// Reporting policy for a stream whose final size is unknown. Counts are actual
/// successfully written bytes; this type never estimates a total or percentage.
struct ReadByteProgressThrottle {
    private let interval: TimeInterval
    private var lastEmissionTime: TimeInterval?
    private var lastEmittedBytes: UInt64?

    init(interval: TimeInterval = 0.1) {
        precondition(interval.isFinite && interval >= 0)
        self.interval = interval
    }

    mutating func update(readBytes: UInt64, now: TimeInterval, force: Bool = false) -> UInt64? {
        guard now.isFinite else { return nil }
        if let previous = lastEmittedBytes, readBytes <= previous { return nil }
        if !force, let lastEmissionTime, now - lastEmissionTime < interval { return nil }
        lastEmissionTime = now
        lastEmittedBytes = readBytes
        return readBytes
    }
}
