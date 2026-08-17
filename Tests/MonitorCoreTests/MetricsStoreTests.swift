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
