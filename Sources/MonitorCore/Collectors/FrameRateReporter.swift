import Foundation

public struct FrameRateReporter: Sendable {
    private var counter = FramesPerSecondCounter()
    private let reportingInterval: TimeInterval
    private var lastReportAt: Date?

    public init(reportingInterval: TimeInterval) {
        self.reportingInterval = reportingInterval
    }

    public mutating func recordFrame(at timestamp: Date = Date()) -> Double? {
        counter.recordFrame(at: timestamp)
        guard lastReportAt.map({ timestamp.timeIntervalSince($0) >= reportingInterval }) ?? true else {
            return nil
        }
        lastReportAt = timestamp
        return counter.framesPerSecond(at: timestamp)
    }
}
