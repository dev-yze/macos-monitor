import Foundation

/// Exponential backoff schedule for reconnecting a broken stream.
/// Delays double from `initialDelay` up to `maxDelay`, then stay there.
/// Call `reset()` when the connection is proven healthy again.
public struct ReconnectBackoff: Equatable, Sendable {
    public private(set) var attempt: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(initialDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.attempt = 0
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// Returns the delay to wait before the next reconnect attempt and
    /// advances the schedule.
    public mutating func nextDelay() -> TimeInterval {
        let delay = min(initialDelay * pow(2.0, Double(attempt)), maxDelay)
        attempt += 1
        return delay
    }

    /// Call once the reconnected stream has produced data.
    public mutating func reset() {
        attempt = 0
    }
}
