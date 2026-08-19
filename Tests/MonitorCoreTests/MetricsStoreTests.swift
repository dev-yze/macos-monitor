import XCTest
@testable import MonitorCore

@MainActor
final class MetricsStoreTests: XCTestCase {
    func testMergeKeepsExistingValuesWhenPartialSnapshotOmitsThem() {
        let store = MetricsStore(historyWindow: 300)
        store.merge(MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 1),
            cpu: CPUMetrics(usage: 0.5),
            systemPowerWatts: 10
        ))

        store.merge(MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 2),
            memory: MemoryMetrics(usedBytes: 100, totalBytes: 200)
        ))

        XCTAssertEqual(store.current.cpu.usage, 0.5)
        XCTAssertEqual(store.current.memory.usedBytes, 100)
        XCTAssertEqual(store.current.systemPowerWatts, 10)
    }

    func testHistoryIsTrimmedToWindow() {
        let store = MetricsStore(historyWindow: 5)
        store.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 1), systemPowerWatts: 1))
        store.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 10), systemPowerWatts: 2))

        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.systemPowerWatts, 2)
    }

    func testUpdateStatusRecordsCollectorState() {
        let store = MetricsStore(historyWindow: 300)
        store.updateStatus(name: "高级指标", state: .unavailable("未授权"))

        XCTAssertEqual(store.collectorStatuses["高级指标"]?.state, .unavailable("未授权"))
    }

    func testMergeUpdatesScreenFramesPerSecond() {
        let store = MetricsStore(historyWindow: 300)

        store.merge(MetricsSnapshot(screenFramesPerSecond: 59))

        XCTAssertEqual(store.current.screenFramesPerSecond, 59)
    }

    func testSetScreenFramesPerSecondUpdatesLiveValueWithoutAddingHistorySample() {
        let store = MetricsStore(historyWindow: 300)

        store.setScreenFramesPerSecond(59)

        XCTAssertEqual(store.current.screenFramesPerSecond, 59)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testMergeWithoutRecordingHistoryUpdatesCurrentOnly() {
        // 高级指标样本（powermetrics 每次推送）只更新当前状态、不进历史：
        // 历史应严格等于「基础采集周期数」，而不是被高频部分快照撑爆。
        let store = MetricsStore(historyWindow: 300)
        store.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 1), cpu: CPUMetrics(usage: 0.5)))

        store.merge(MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 2),
            systemPowerWatts: 20
        ), recordsHistory: false)

        XCTAssertEqual(store.current.systemPowerWatts, 20)
        XCTAssertEqual(store.history.count, 1, "recordsHistory: false 的合并不得追加历史")
        XCTAssertEqual(store.history.first?.timestamp, Date(timeIntervalSince1970: 1))
    }

    func testOneHistoryEntryPerSamplingCycle() {
        let store = MetricsStore(historyWindow: 300)

        for cycleIndex in 0..<5 {
            var cycle = MetricsSnapshot(timestamp: Date(timeIntervalSince1970: TimeInterval(cycleIndex * 2)))
            cycle.merge(MetricsSnapshot(timestamp: cycle.timestamp, cpu: CPUMetrics(usage: 0.1)))
            cycle.merge(MetricsSnapshot(timestamp: cycle.timestamp, battery: BatteryMetrics(percent: 0.5)))
            cycle.merge(MetricsSnapshot(timestamp: cycle.timestamp, systemPowerWatts: 12))
            store.merge(cycle)
        }

        XCTAssertEqual(store.history.count, 5, "每个采样周期应恰好产生一条历史记录")
        XCTAssertTrue(store.history.allSatisfy { $0.cpu.usage != nil && $0.systemPowerWatts != nil },
                      "每条历史记录都应是完整快照，不含半成品")
    }

    func testAdvancedMonitoringEnabledDefaultsToTrueAndPersists() {
        let suiteName = "macosmonitor-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MetricsStore(defaults: defaults)
        XCTAssertTrue(store.advancedMonitoringEnabled, "默认应启用高级监控（老用户无感升级）")

        store.setAdvancedMonitoringEnabled(false)

        let reloaded = MetricsStore(defaults: defaults)
        XCTAssertFalse(reloaded.advancedMonitoringEnabled, "卸载后台服务后开关必须持久化，避免下次启动又弹安装授权框")
    }

    func testHasDataAndStale() {
        let store = MetricsStore(historyWindow: 300, samplingInterval: 2)
        XCTAssertFalse(store.hasData)
        XCTAssertFalse(store.isStale())

        store.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(store.hasData)
        XCTAssertFalse(store.isStale(now: Date(timeIntervalSince1970: 2)))
        XCTAssertTrue(store.isStale(now: Date(timeIntervalSince1970: 31)))
    }
}
