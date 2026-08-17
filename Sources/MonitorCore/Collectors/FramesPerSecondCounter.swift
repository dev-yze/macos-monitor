import Foundation

public struct FramesPerSecondCounter: Sendable {
    private var frameTimes: [Date] = []

    public init() {}

    public mutating func recordFrame(at timestamp: Date = Date()) {
        frameTimes.append(timestamp)
    }

    public mutating func framesPerSecond(at now: Date = Date()) -> Double {
        let cutoff = now.addingTimeInterval(-1)
        frameTimes.removeAll { $0 < cutoff }
        return Double(frameTimes.count)
    }
}
