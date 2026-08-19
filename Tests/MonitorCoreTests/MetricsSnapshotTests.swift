import XCTest
@testable import MonitorCore

final class MetricsSnapshotTests: XCTestCase {
    func testMergeOverwritesOnlyNonNilFields() {
        var base = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 1),
            cpu: CPUMetrics(usage: 0.5),
            systemPowerWatts: 10
        )

        base.merge(MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 2),
            memory: MemoryMetrics(usedBytes: 100)
        ))

        XCTAssertEqual(base.timestamp, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(base.cpu.usage, 0.5, "incoming snapshot 未携带的字段必须保留")
        XCTAssertEqual(base.systemPowerWatts, 10)
        XCTAssertEqual(base.memory.usedBytes, 100)
    }

    func testMergeEmptyArraysDoNotClobberExistingValues() {
        var base = MetricsSnapshot(
            cpu: CPUMetrics(perCoreUsage: [0.1, 0.2], perCoreLabels: ["E1", "E2"]),
            storageVolumes: [StorageVolumeMetrics(name: "U盘", mountPath: "/Volumes/U")]
        )

        base.merge(MetricsSnapshot())

        XCTAssertEqual(base.cpu.perCoreUsage, [0.1, 0.2])
        XCTAssertEqual(base.cpu.perCoreLabels, ["E1", "E2"])
        XCTAssertEqual(base.storageVolumes.count, 1)
    }

    func testCollectorsCycleComposesIntoSingleCompleteSnapshot() {
        // 模拟基础采集循环：多个采集器的稀疏快照按序合并成一条完整记录。
        var cycle = MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100))
        cycle.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100), cpu: CPUMetrics(usage: 0.3)))
        cycle.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100), battery: BatteryMetrics(percent: 0.9)))
        cycle.merge(MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100), diskReadBytesPerSecond: 2048))

        XCTAssertEqual(cycle.cpu.usage, 0.3)
        XCTAssertEqual(cycle.battery.percent, 0.9)
        XCTAssertEqual(cycle.diskReadBytesPerSecond, 2048)
    }
}
