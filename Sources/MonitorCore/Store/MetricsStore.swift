import Foundation
import Observation

@MainActor
@Observable
public final class MetricsStore {
    private enum Keys {
        static let samplingInterval = "samplingInterval"
        static let menuBarMetric = "menuBarMetric"
        static let screenFramesPerSecondEnabled = "screenFramesPerSecondEnabled"
        static let advancedMonitoringEnabled = "advancedMonitoringEnabled"
    }

    public private(set) var current: MetricsSnapshot
    public private(set) var history: [MetricsSnapshot]
    public private(set) var collectorStatuses: [String: CollectorStatus]
    public private(set) var samplingInterval: TimeInterval
    public private(set) var menuBarMetric: MenuBarMetric
    public private(set) var screenFramesPerSecondEnabled: Bool
    /// 是否启用高级监控（root LaunchDaemon + powermetrics）。用户卸载后台
    /// 服务后置 false，避免下次启动又弹安装授权框。
    public private(set) var advancedMonitoringEnabled: Bool
    private let historyWindow: TimeInterval
    private let defaults: UserDefaults

    public init(
        current: MetricsSnapshot = MetricsSnapshot(),
        historyWindow: TimeInterval = 300,
        samplingInterval: TimeInterval = 2,
        defaults: UserDefaults = .standard
    ) {
        self.current = current
        self.history = []
        self.collectorStatuses = [:]
        self.historyWindow = historyWindow
        self.defaults = defaults

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
        self.screenFramesPerSecondEnabled = defaults.bool(forKey: Keys.screenFramesPerSecondEnabled)
        if defaults.object(forKey: Keys.advancedMonitoringEnabled) != nil {
            self.advancedMonitoringEnabled = defaults.bool(forKey: Keys.advancedMonitoringEnabled)
        } else {
            self.advancedMonitoringEnabled = true
        }
    }

    public func setSamplingInterval(_ interval: TimeInterval) {
        samplingInterval = interval
        defaults.set(interval, forKey: Keys.samplingInterval)
    }

    public func setMenuBarMetric(_ metric: MenuBarMetric) {
        menuBarMetric = metric
        defaults.set(metric.rawValue, forKey: Keys.menuBarMetric)
    }

    public func setScreenFramesPerSecondEnabled(_ enabled: Bool) {
        screenFramesPerSecondEnabled = enabled
        defaults.set(enabled, forKey: Keys.screenFramesPerSecondEnabled)
    }

    public func setAdvancedMonitoringEnabled(_ enabled: Bool) {
        // 幂等：同值重复设置直接忽略。observation 对同值 set 也会触发变更回调，
        // 不去重会导致下游「配置/安装」逻辑被重复执行（重复弹授权框）。
        guard advancedMonitoringEnabled != enabled else { return }
        advancedMonitoringEnabled = enabled
        defaults.set(enabled, forKey: Keys.advancedMonitoringEnabled)
    }

    public func setScreenFramesPerSecond(_ value: Double?) {
        current.screenFramesPerSecond = value
    }

    /// Merges a partial snapshot into the current state.
    ///
    /// `recordsHistory` controls whether the merged result is appended to the
    /// history window. Callers that push high-frequency partial updates
    /// (e.g. every powermetrics sample) should pass `false` so history holds
    /// exactly one full snapshot per sampling cycle instead of interleaved
    /// half-populated ones.
    public func merge(_ partial: MetricsSnapshot, recordsHistory: Bool = true) {
        var merged = current
        merged.merge(partial)

        current = merged
        if recordsHistory {
            history.append(merged)
            trimHistory(now: partial.timestamp)
        }
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
