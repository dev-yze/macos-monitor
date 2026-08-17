# Apple Silicon 菜单栏能耗监控工具 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个仅面向 Apple Silicon macOS 的轻量级菜单栏能耗监控 App。

**Architecture:** 使用 Swift Package Manager 组织一个 SwiftUI macOS App target、一个核心库 target 和一个测试 target。核心库负责指标模型、采集器、解析器、格式化和状态合并；App target 只负责菜单栏生命周期与 SwiftUI 展示。

**Tech Stack:** Swift 5.9+、SwiftUI、AppKit、IOKit、CoreGraphics、Foundation、XCTest、`/usr/bin/powermetrics`。

## Global Constraints

- 目标平台：仅 Apple Silicon macOS。
- 初始产品形态：轻量级菜单栏 App。
- 权限模型：接受为了高级指标请求管理员权限。
- 实现路径：原生 Swift/SwiftUI App，MVP 直接集成 `powermetrics`，暂不做独立 helper。
- 默认采样间隔为 2 秒。
- MVP 只在内存中保留最近约 5 分钟的采样，不写入历史数据到磁盘。
- Intel Mac、持久化历史数据库、开机登录自动启动、签名和 notarization 分发包、privileged helper、按 App 统计 FPS 不属于 MVP。

---

## File Structure

- `Package.swift`: Swift package manifest，定义 app、library 和 test targets。
- `Sources/MacOSMonitorApp/MacOSMonitorApp.swift`: SwiftUI App 入口和 `MenuBarExtra`。
- `Sources/MacOSMonitorApp/MonitorMenuView.swift`: 菜单栏弹出面板。
- `Sources/MonitorCore/Models/MetricsSnapshot.swift`: 指标模型和不可用状态。
- `Sources/MonitorCore/Models/MetricFormatters.swift`: 单位格式化。
- `Sources/MonitorCore/Store/MetricsStore.swift`: 状态合并、短期历史和采样控制。
- `Sources/MonitorCore/Collectors/SystemStatsCollector.swift`: CPU 和内存基础指标。
- `Sources/MonitorCore/Collectors/BatteryCollector.swift`: 电池基础指标。
- `Sources/MonitorCore/Collectors/DisplayCollector.swift`: 显示器刷新率。
- `Sources/MonitorCore/Collectors/StorageCollector.swift`: 外部卷容量。
- `Sources/MonitorCore/Collectors/PowermetricsCollector.swift`: `powermetrics` 进程封装。
- `Sources/MonitorCore/Parsers/PowermetricsParser.swift`: `powermetrics` 文本解析。
- `Tests/MonitorCoreTests/MetricFormattersTests.swift`: 单位格式化测试。
- `Tests/MonitorCoreTests/MetricsStoreTests.swift`: 快照合并和历史裁剪测试。
- `Tests/MonitorCoreTests/PowermetricsParserTests.swift`: `powermetrics` 样本文本解析测试。

---

### Task 1: Package and Core Models

**Files:**
- Create: `Package.swift`
- Create: `Sources/MonitorCore/Models/MetricsSnapshot.swift`
- Create: `Sources/MonitorCore/Models/MetricFormatters.swift`
- Create: `Tests/MonitorCoreTests/MetricFormattersTests.swift`

**Interfaces:**
- Produces: `MetricsSnapshot`, `MetricValue<Value>`, `CollectorStatus`, `MetricFormatters.watts(_:)`, `MetricFormatters.celsius(_:)`, `MetricFormatters.percent(_:)`, `MetricFormatters.bytes(_:)`, `MetricFormatters.throughput(_:)`

- [ ] **Step 1: Write formatter tests**

```swift
import XCTest
@testable import MonitorCore

final class MetricFormattersTests: XCTestCase {
    func testFormatsWatts() {
        XCTAssertEqual(MetricFormatters.watts(18.24), "18.2 W")
        XCTAssertEqual(MetricFormatters.watts(nil), "-- W")
    }

    func testFormatsCelsius() {
        XCTAssertEqual(MetricFormatters.celsius(62.6), "63 C")
        XCTAssertEqual(MetricFormatters.celsius(nil), "-- C")
    }

    func testFormatsPercent() {
        XCTAssertEqual(MetricFormatters.percent(0.427), "43%")
        XCTAssertEqual(MetricFormatters.percent(nil), "--%")
    }

    func testFormatsBytesAndThroughput() {
        XCTAssertEqual(MetricFormatters.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(MetricFormatters.throughput(2_097_152), "2.0 MB/s")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MetricFormattersTests`

Expected: FAIL because the package and formatter types do not exist yet.

- [ ] **Step 3: Create the package manifest**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacOSMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacOSMonitorApp", targets: ["MacOSMonitorApp"]),
        .library(name: "MonitorCore", targets: ["MonitorCore"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSMonitorApp",
            dependencies: ["MonitorCore"]
        ),
        .target(
            name: "MonitorCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        )
    ]
)
```

- [ ] **Step 4: Create core metric models**

```swift
import Foundation

public enum MetricValue<Value: Equatable>: Equatable {
    case available(Value)
    case unavailable(String)

    public var value: Value? {
        if case .available(let value) = self {
            return value
        }
        return nil
    }
}

public struct CollectorStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case unavailable(String)
        case failed(String)
    }

    public var state: State
    public var updatedAt: Date?

    public init(state: State = .idle, updatedAt: Date? = nil) {
        self.state = state
        self.updatedAt = updatedAt
    }
}

public struct CPUMetrics: Equatable, Sendable {
    public var usage: Double?
    public var frequencyMHz: Double?

    public init(usage: Double? = nil, frequencyMHz: Double? = nil) {
        self.usage = usage
        self.frequencyMHz = frequencyMHz
    }
}

public struct GPUMetrics: Equatable, Sendable {
    public var usage: Double?
    public var powerWatts: Double?

    public init(usage: Double? = nil, powerWatts: Double? = nil) {
        self.usage = usage
        self.powerWatts = powerWatts
    }
}

public struct MemoryMetrics: Equatable, Sendable {
    public var usedBytes: UInt64?
    public var totalBytes: UInt64?
    public var pressure: Double?
    public var swapUsedBytes: UInt64?

    public init(usedBytes: UInt64? = nil, totalBytes: UInt64? = nil, pressure: Double? = nil, swapUsedBytes: UInt64? = nil) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
    }
}

public struct BatteryMetrics: Equatable, Sendable {
    public var percent: Double?
    public var powerWatts: Double?
    public var isCharging: Bool?

    public init(percent: Double? = nil, powerWatts: Double? = nil, isCharging: Bool? = nil) {
        self.percent = percent
        self.powerWatts = powerWatts
        self.isCharging = isCharging
    }
}

public struct StorageVolumeMetrics: Equatable, Identifiable, Sendable {
    public var id: String { mountPath }
    public var name: String
    public var mountPath: String
    public var totalBytes: UInt64?
    public var availableBytes: UInt64?
    public var readBytesPerSecond: UInt64?
    public var writeBytesPerSecond: UInt64?

    public init(name: String, mountPath: String, totalBytes: UInt64? = nil, availableBytes: UInt64? = nil, readBytesPerSecond: UInt64? = nil, writeBytesPerSecond: UInt64? = nil) {
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct DisplayMetrics: Equatable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var refreshRate: Double?

    public init(id: UInt32, name: String, refreshRate: Double? = nil) {
        self.id = id
        self.name = name
        self.refreshRate = refreshRate
    }
}

public struct TemperatureMetric: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct MetricsSnapshot: Equatable, Sendable {
    public var timestamp: Date
    public var cpu: CPUMetrics
    public var gpu: GPUMetrics
    public var memory: MemoryMetrics
    public var battery: BatteryMetrics
    public var storageVolumes: [StorageVolumeMetrics]
    public var displays: [DisplayMetrics]
    public var temperatures: [TemperatureMetric]
    public var systemPowerWatts: Double?

    public init(
        timestamp: Date = Date(),
        cpu: CPUMetrics = CPUMetrics(),
        gpu: GPUMetrics = GPUMetrics(),
        memory: MemoryMetrics = MemoryMetrics(),
        battery: BatteryMetrics = BatteryMetrics(),
        storageVolumes: [StorageVolumeMetrics] = [],
        displays: [DisplayMetrics] = [],
        temperatures: [TemperatureMetric] = [],
        systemPowerWatts: Double? = nil
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.battery = battery
        self.storageVolumes = storageVolumes
        self.displays = displays
        self.temperatures = temperatures
        self.systemPowerWatts = systemPowerWatts
    }
}
```

- [ ] **Step 5: Create metric formatters**

```swift
import Foundation

public enum MetricFormatters {
    public static func watts(_ value: Double?) -> String {
        guard let value else { return "-- W" }
        return String(format: "%.1f W", value)
    }

    public static func celsius(_ value: Double?) -> String {
        guard let value else { return "-- C" }
        return String(format: "%.0f C", value)
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "--%" }
        return String(format: "%.0f%%", value * 100)
    }

    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    public static func throughput(_ value: UInt64?) -> String {
        guard let value else { return "--/s" }
        return "\(bytes(value))/s"
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter MetricFormattersTests`

Expected: PASS.

---

### Task 2: Powermetrics Parser

**Files:**
- Create: `Sources/MonitorCore/Parsers/PowermetricsParser.swift`
- Create: `Tests/MonitorCoreTests/PowermetricsParserTests.swift`

**Interfaces:**
- Consumes: `MetricsSnapshot`, `CPUMetrics`, `GPUMetrics`, `TemperatureMetric`
- Produces: `PowermetricsParser.parse(_ text: String, timestamp: Date) -> MetricsSnapshot`

- [ ] **Step 1: Write parser tests**

```swift
import XCTest
@testable import MonitorCore

final class PowermetricsParserTests: XCTestCase {
    func testParsesPowerFrequencyAndTemperatures() {
        let sample = """
        **** Processor usage ****
        CPU Power: 5200 mW
        GPU Power: 1800 mW
        Combined Power (CPU + GPU + ANE): 7480 mW
        E-Cluster HW active frequency: 1320 MHz
        P-Cluster HW active frequency: 3100 MHz
        GPU HW active residency: 42.6%

        **** SMC sensors ****
        CPU die temperature: 61.2 C
        GPU die temperature: 58.9 C
        """

        let snapshot = PowermetricsParser.parse(sample, timestamp: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(snapshot.systemPowerWatts, 7.48, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpu.powerWatts, 1.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpu.usage, 0.426, accuracy: 0.001)
        XCTAssertEqual(snapshot.cpu.frequencyMHz, 3100, accuracy: 0.001)
        XCTAssertEqual(snapshot.temperatures.count, 2)
        XCTAssertEqual(snapshot.temperatures.first?.name, "CPU die")
        XCTAssertEqual(snapshot.temperatures.first?.celsius, 61.2, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PowermetricsParserTests`

Expected: FAIL because `PowermetricsParser` does not exist yet.

- [ ] **Step 3: Implement parser**

```swift
import Foundation

public enum PowermetricsParser {
    public static func parse(_ text: String, timestamp: Date = Date()) -> MetricsSnapshot {
        var snapshot = MetricsSnapshot(timestamp: timestamp)
        var temperatures: [TemperatureMetric] = []
        var bestCPUFrequency: Double?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let milliWatts = number(in: line, after: "Combined Power (CPU + GPU + ANE):", before: "mW") {
                snapshot.systemPowerWatts = milliWatts / 1000
            } else if let milliWatts = number(in: line, after: "CPU Power:", before: "mW") {
                snapshot.cpu.frequencyMHz = snapshot.cpu.frequencyMHz
                if snapshot.systemPowerWatts == nil {
                    snapshot.systemPowerWatts = milliWatts / 1000
                }
            } else if let milliWatts = number(in: line, after: "GPU Power:", before: "mW") {
                snapshot.gpu.powerWatts = milliWatts / 1000
            }

            if line.contains("HW active frequency"),
               let mhz = number(in: line, after: ":", before: "MHz") {
                bestCPUFrequency = max(bestCPUFrequency ?? 0, mhz)
            }

            if let residency = number(in: line, after: "GPU HW active residency:", before: "%") {
                snapshot.gpu.usage = residency / 100
            }

            if line.localizedCaseInsensitiveContains("temperature"),
               let celsius = number(in: line, after: ":", before: "C") {
                let name = line.components(separatedBy: ":").first?
                    .replacingOccurrences(of: " temperature", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Temperature"
                temperatures.append(TemperatureMetric(name: name, celsius: celsius))
            }
        }

        snapshot.cpu.frequencyMHz = bestCPUFrequency
        snapshot.temperatures = temperatures
        return snapshot
    }

    private static func number(in line: String, after prefix: String, before suffix: String) -> Double? {
        guard let prefixRange = line.range(of: prefix, options: .caseInsensitive) else {
            return nil
        }
        let remainder = line[prefixRange.upperBound...]
        guard let suffixRange = remainder.range(of: suffix, options: .caseInsensitive) else {
            return nil
        }
        let numberText = remainder[..<suffixRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Double(numberText)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PowermetricsParserTests`

Expected: PASS.

---

### Task 3: Metrics Store

**Files:**
- Create: `Sources/MonitorCore/Store/MetricsStore.swift`
- Create: `Tests/MonitorCoreTests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `MetricsSnapshot`
- Produces: `@MainActor final class MetricsStore`, `MetricsStore.merge(_:)`, `MetricsStore.history`

- [ ] **Step 1: Write store tests**

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MetricsStoreTests`

Expected: FAIL because `MetricsStore` does not exist yet.

- [ ] **Step 3: Implement store**

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class MetricsStore {
    public private(set) var current: MetricsSnapshot
    public private(set) var history: [MetricsSnapshot]
    public var samplingInterval: TimeInterval
    private let historyWindow: TimeInterval

    public init(
        current: MetricsSnapshot = MetricsSnapshot(),
        historyWindow: TimeInterval = 300,
        samplingInterval: TimeInterval = 2
    ) {
        self.current = current
        self.history = []
        self.historyWindow = historyWindow
        self.samplingInterval = samplingInterval
    }

    public func merge(_ partial: MetricsSnapshot) {
        var merged = current
        merged.timestamp = partial.timestamp

        if partial.cpu.usage != nil { merged.cpu.usage = partial.cpu.usage }
        if partial.cpu.frequencyMHz != nil { merged.cpu.frequencyMHz = partial.cpu.frequencyMHz }
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

        current = merged
        history.append(merged)
        trimHistory(now: partial.timestamp)
    }

    private func trimHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-historyWindow)
        history.removeAll { $0.timestamp < cutoff }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MetricsStoreTests`

Expected: PASS.

---

### Task 4: Basic Collectors

**Files:**
- Create: `Sources/MonitorCore/Collectors/SystemStatsCollector.swift`
- Create: `Sources/MonitorCore/Collectors/BatteryCollector.swift`
- Create: `Sources/MonitorCore/Collectors/DisplayCollector.swift`
- Create: `Sources/MonitorCore/Collectors/StorageCollector.swift`

**Interfaces:**
- Consumes: `MetricsSnapshot`
- Produces: `SystemStatsCollector.collect() -> MetricsSnapshot`, `BatteryCollector.collect() -> MetricsSnapshot`, `DisplayCollector.collect() -> MetricsSnapshot`, `StorageCollector.collect() -> MetricsSnapshot`

- [ ] **Step 1: Create basic collectors**

```swift
import Foundation
import Darwin

public struct SystemStatsCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        snapshot.cpu.usage = loadAverage()
        snapshot.memory = memoryMetrics()
        return snapshot
    }

    private func loadAverage() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return nil }
        let processorCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(1, loads[0] / Double(processorCount))
    }

    private func memoryMetrics() -> MemoryMetrics {
        let processInfo = ProcessInfo.processInfo
        let total = processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryMetrics(totalBytes: total)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count + stats.inactive_count) * pageSize
        let used = total > free ? total - free : 0
        let pressure = total == 0 ? nil : Double(used) / Double(total)
        return MemoryMetrics(usedBytes: used, totalBytes: total, pressure: pressure)
    }
}
```

```swift
import Foundation
import IOKit.ps

public struct BatteryCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return MetricsSnapshot()
        }

        let current = description[kIOPSCurrentCapacityKey] as? Double
        let max = description[kIOPSMaxCapacityKey] as? Double
        let percent = (current != nil && max != nil && max! > 0) ? current! / max! : nil
        let isCharging = (description[kIOPSIsChargingKey] as? Bool)

        var snapshotValue = MetricsSnapshot()
        snapshotValue.battery = BatteryMetrics(percent: percent, powerWatts: nil, isCharging: isCharging)
        return snapshotValue
    }
}
```

```swift
import CoreGraphics
import Foundation

public struct DisplayCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        let displays = ids.map { id in
            DisplayMetrics(
                id: id,
                name: "Display \(id)",
                refreshRate: CGDisplayCopyDisplayMode(id)?.refreshRate
            )
        }

        var snapshot = MetricsSnapshot()
        snapshot.displays = displays
        return snapshot
    }
}
```

```swift
import Foundation

public struct StorageCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        let volumes = urls.compactMap { url -> StorageVolumeMetrics? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsInternal == false else { return nil }

            return StorageVolumeMetrics(
                name: values?.volumeName ?? url.lastPathComponent,
                mountPath: url.path,
                totalBytes: values?.volumeTotalCapacity.map(UInt64.init),
                availableBytes: values?.volumeAvailableCapacity.map(UInt64.init)
            )
        }

        var snapshot = MetricsSnapshot()
        snapshot.storageVolumes = volumes
        return snapshot
    }
}
```

- [ ] **Step 2: Run core tests**

Run: `swift test`

Expected: PASS.

---

### Task 5: Powermetrics Collector

**Files:**
- Create: `Sources/MonitorCore/Collectors/PowermetricsCollector.swift`

**Interfaces:**
- Consumes: `PowermetricsParser.parse(_:, timestamp:)`
- Produces: `PowermetricsCollector.collectOnce() async throws -> MetricsSnapshot`

- [ ] **Step 1: Implement collector**

```swift
import Foundation

public struct PowermetricsCollector {
    public enum CollectorError: Error, Equatable {
        case commandFailed(String)
        case emptyOutput
    }

    public init() {}

    public func collectOnce() async throws -> MetricsSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "/usr/bin/powermetrics",
            "--samplers", "cpu_power,gpu_power,thermal",
            "--sample-count", "1",
            "--sample-rate", "1000"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CollectorError.commandFailed(errorText.isEmpty ? text : errorText)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CollectorError.emptyOutput
        }

        return PowermetricsParser.parse(text)
    }
}
```

- [ ] **Step 2: Run core tests**

Run: `swift test`

Expected: PASS.

---

### Task 6: SwiftUI Menu Bar App

**Files:**
- Create: `Sources/MacOSMonitorApp/MacOSMonitorApp.swift`
- Create: `Sources/MacOSMonitorApp/MonitorMenuView.swift`

**Interfaces:**
- Consumes: `MetricsStore`, `SystemStatsCollector`, `BatteryCollector`, `DisplayCollector`, `StorageCollector`, `PowermetricsCollector`
- Produces: runnable `MacOSMonitorApp`

- [ ] **Step 1: Implement app entry and sampling loop**

```swift
import MonitorCore
import SwiftUI

@main
struct MacOSMonitorApp: App {
    @State private var store = MetricsStore()

    var body: some Scene {
        MenuBarExtra {
            MonitorMenuView(store: store)
                .frame(width: 340)
                .task {
                    await runCollectors()
                }
        } label: {
            Text(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarTitle: String {
        if let watts = store.current.systemPowerWatts {
            return MetricFormatters.watts(watts)
        }
        if let firstTemperature = store.current.temperatures.first?.celsius {
            return MetricFormatters.celsius(firstTemperature)
        }
        return "Monitor"
    }

    private func runCollectors() async {
        let system = SystemStatsCollector()
        let battery = BatteryCollector()
        let display = DisplayCollector()
        let storage = StorageCollector()
        let power = PowermetricsCollector()

        while !Task.isCancelled {
            await MainActor.run {
                store.merge(system.collect())
                store.merge(battery.collect())
                store.merge(display.collect())
                store.merge(storage.collect())
            }

            do {
                let advanced = try await power.collectOnce()
                await MainActor.run {
                    store.merge(advanced)
                }
            } catch {
                // Advanced metrics are optional in the MVP; basic metrics should keep updating.
            }

            try? await Task.sleep(nanoseconds: UInt64(store.samplingInterval * 1_000_000_000))
        }
    }
}
```

- [ ] **Step 2: Implement popover view**

```swift
import MonitorCore
import SwiftUI

struct MonitorMenuView: View {
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            section("CPU") {
                metricRow("使用率", MetricFormatters.percent(store.current.cpu.usage))
                metricRow("频率", frequencyText(store.current.cpu.frequencyMHz))
            }
            section("GPU") {
                metricRow("使用率", MetricFormatters.percent(store.current.gpu.usage))
                metricRow("功耗", MetricFormatters.watts(store.current.gpu.powerWatts))
            }
            section("内存") {
                metricRow("已用", "\(MetricFormatters.bytes(store.current.memory.usedBytes)) / \(MetricFormatters.bytes(store.current.memory.totalBytes))")
                metricRow("压力", MetricFormatters.percent(store.current.memory.pressure))
            }
            section("电池") {
                metricRow("电量", MetricFormatters.percent(store.current.battery.percent))
                metricRow("状态", store.current.battery.isCharging == true ? "充电中" : "未充电")
            }
            section("外部存储") {
                if store.current.storageVolumes.isEmpty {
                    Text("未检测到外部存储").foregroundStyle(.secondary)
                } else {
                    ForEach(store.current.storageVolumes) { volume in
                        metricRow(volume.name, "\(MetricFormatters.bytes(volume.availableBytes)) 可用")
                    }
                }
            }
            section("显示器") {
                ForEach(store.current.displays) { display in
                    metricRow(display.name, refreshRateText(display.refreshRate))
                }
            }
            section("温度") {
                if store.current.temperatures.isEmpty {
                    Text("高级温度数据不可用").foregroundStyle(.secondary)
                } else {
                    ForEach(store.current.temperatures) { temperature in
                        metricRow(temperature.name, MetricFormatters.celsius(temperature.celsius))
                    }
                }
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac 能耗监控")
                    .font(.headline)
                Text("最近更新 \(store.current.timestamp.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MetricFormatters.watts(store.current.systemPowerWatts))
                .font(.title2.monospacedDigit())
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.callout)
    }

    private func frequencyText(_ value: Double?) -> String {
        guard let value else { return "-- MHz" }
        return String(format: "%.0f MHz", value)
    }

    private func refreshRateText(_ value: Double?) -> String {
        guard let value, value > 0 else { return "-- Hz" }
        return String(format: "%.0f Hz", value)
    }
}
```

- [ ] **Step 3: Build app**

Run: `swift build`

Expected: PASS.

---

### Task 7: Manual Verification

**Files:**
- Modify only if verification reveals a compile or runtime issue.

**Interfaces:**
- Consumes: runnable app binary.
- Produces: verified MVP behavior.

- [ ] **Step 1: Run all tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 2: Build release binary**

Run: `swift build -c release`

Expected: PASS.

- [ ] **Step 3: Launch app manually**

Run: `.build/release/MacOSMonitorApp`

Expected: the menu bar app starts. Basic metrics should display. Advanced metrics may trigger a sudo password prompt in the launching terminal because the MVP directly invokes `sudo powermetrics`.

- [ ] **Step 4: Verify expected limitations**

Expected:
- If sudo credentials are not available, basic CPU, memory, battery, display, and storage metrics continue updating.
- If no external storage is mounted, the UI shows `未检测到外部存储`.
- If `powermetrics` output differs on M5 Pro, update `PowermetricsParserTests` with a captured sample and adjust `PowermetricsParser`.

---

## Self-Review

- Spec coverage: The plan covers native SwiftUI menu bar app, Apple Silicon scope, administrator-gated advanced metrics, basic collectors, `powermetrics` parser, in-memory history, unavailable states, and focused tests.
- Known MVP gap: The plan includes display of collector failure as simplified unavailable UI, but not a full per-collector status dashboard. This is acceptable for MVP because basic collectors keep updating and advanced failures do not crash the app.
- Placeholder scan: No TODO/TBD placeholders.
- Type consistency: Later tasks use `MetricsStore`, `MetricsSnapshot`, collectors, parser, and formatters defined in earlier tasks.
