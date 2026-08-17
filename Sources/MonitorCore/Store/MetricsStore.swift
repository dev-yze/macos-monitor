import Foundation
import Observation

@MainActor
@Observable
public final class MetricsStore {
    private enum Keys {
        static let samplingInterval = "samplingInterval"
        static let menuBarMetric = "menuBarMetric"
    }

    public private(set) var current: MetricsSnapshot
    public private(set) var history: [MetricsSnapshot]
    public private(set) var collectorStatuses: [String: CollectorStatus]
    public private(set) var samplingInterval: TimeInterval
    public private(set) var menuBarMetric: MenuBarMetric
    private let historyWindow: TimeInterval

    public init(
        current: MetricsSnapshot = MetricsSnapshot(),
        historyWindow: TimeInterval = 300,
        samplingInterval: TimeInterval = 2
    ) {
        self.current = current
        self.history = []
        self.collectorStatuses = [:]
        self.historyWindow = historyWindow

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.samplingInterval) != nil {
            self.samplingInterval = defaults.double(forKey: Keys.samplingInterval)
        } else {
            self.samplingInterval = samplingInterval
        }
        if let raw = defaults.string(forKey: Keys.menuBarMetric), let metric = MenuBarMetric(rawValue: raw) {
            self.menuBarMetric = metric
        } else {
            self.menuBarMetric = .power
        }
    }

    public func setSamplingInterval(_ interval: TimeInterval) {
        samplingInterval = interval
        UserDefaults.standard.set(interval, forKey: Keys.samplingInterval)
    }

    public func setMenuBarMetric(_ metric: MenuBarMetric) {
        menuBarMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Keys.menuBarMetric)
    }

    public func merge(_ partial: MetricsSnapshot) {
        var merged = current
        merged.timestamp = partial.timestamp

        if partial.cpu.usage != nil { merged.cpu.usage = partial.cpu.usage }
        if partial.cpu.frequencyMHz != nil { merged.cpu.frequencyMHz = partial.cpu.frequencyMHz }
        if !partial.cpu.perCoreUsage.isEmpty { merged.cpu.perCoreUsage = partial.cpu.perCoreUsage }
        if !partial.cpu.perCoreLabels.isEmpty { merged.cpu.perCoreLabels = partial.cpu.perCoreLabels }
        if partial.gpu.usage != nil { merged.gpu.usage = partial.gpu.usage }
        if partial.gpu.powerWatts != nil { merged.gpu.powerWatts = partial.gpu.powerWatts }
        if partial.memory.usedBytes != nil { merged.memory.usedBytes = partial.memory.usedBytes }
        if partial.memory.totalBytes != nil { merged.memory.totalBytes = partial.memory.totalBytes }
        if partial.memory.pressure != nil { merged.memory.pressure = partial.memory.pressure }
        if partial.memory.swapUsedBytes != nil { merged.memory.swapUsedBytes = partial.memory.swapUsedBytes }
        if partial.battery.percent != nil { merged.battery.percent = partial.battery.percent }
        if partial.battery.powerWatts != nil { merged.battery.powerWatts = partial.battery.powerWatts }
        if partial.battery.isCharging != nil { merged.battery.isCharging = partial.battery.isCharging }
        if !partial.storageVolumes.isEmpty { merged.storageVolumes = partial.storageVolumes }
        if !partial.displays.isEmpty { merged.displays = partial.displays }
        if !partial.temperatures.isEmpty { merged.temperatures = partial.temperatures }
        if partial.systemPowerWatts != nil { merged.systemPowerWatts = partial.systemPowerWatts }
        if partial.diskReadBytesPerSecond != nil { merged.diskReadBytesPerSecond = partial.diskReadBytesPerSecond }
        if partial.diskWriteBytesPerSecond != nil { merged.diskWriteBytesPerSecond = partial.diskWriteBytesPerSecond }

        current = merged
        history.append(merged)
        trimHistory(now: partial.timestamp)
    }

    public func updateStatus(name: String, state: CollectorStatus.State) {
        collectorStatuses[name] = CollectorStatus(state: state, updatedAt: Date())
    }

    /// Whether the store has received at least one sample.
    public var hasData: Bool { !history.isEmpty }

    /// Whether the latest sample is older than what the sampling interval would suggest.
    public func isStale(now: Date = Date()) -> Bool {
        guard hasData else { return false }
        let threshold = max(samplingInterval * 5, 15)
        return now.timeIntervalSince(current.timestamp) > threshold
    }

    private func trimHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-historyWindow)
        history.removeAll { $0.timestamp < cutoff }
    }
}
