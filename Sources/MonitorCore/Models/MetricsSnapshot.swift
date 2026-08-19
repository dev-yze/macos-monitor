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
    /// Per-core utilization (0…1 each), in the kernel's processor order.
    public var perCoreUsage: [Double]
    /// Display labels for each core, e.g. "E1"…"P6".
    public var perCoreLabels: [String]

    public init(usage: Double? = nil, frequencyMHz: Double? = nil, perCoreUsage: [Double] = [], perCoreLabels: [String] = []) {
        self.usage = usage
        self.frequencyMHz = frequencyMHz
        self.perCoreUsage = perCoreUsage
        self.perCoreLabels = perCoreLabels
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

/// Battery availability derived from whether any battery field has data.
/// Desktop Macs have no battery: every field is nil, and showing
/// "未充电" there would be misleading.
public enum BatteryState: Equatable, Sendable {
    case charging
    case notCharging
    case unavailable
}

extension BatteryMetrics {
    public var state: BatteryState {
        guard percent != nil || powerWatts != nil || isCharging != nil else {
            return .unavailable
        }
        return isCharging == true ? .charging : .notCharging
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
    public var diskReadBytesPerSecond: UInt64?
    public var diskWriteBytesPerSecond: UInt64?
    public var screenFramesPerSecond: Double?

    public init(
        timestamp: Date = Date(),
        cpu: CPUMetrics = CPUMetrics(),
        gpu: GPUMetrics = GPUMetrics(),
        memory: MemoryMetrics = MemoryMetrics(),
        battery: BatteryMetrics = BatteryMetrics(),
        storageVolumes: [StorageVolumeMetrics] = [],
        displays: [DisplayMetrics] = [],
        temperatures: [TemperatureMetric] = [],
        systemPowerWatts: Double? = nil,
        diskReadBytesPerSecond: UInt64? = nil,
        diskWriteBytesPerSecond: UInt64? = nil,
        screenFramesPerSecond: Double? = nil
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
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.screenFramesPerSecond = screenFramesPerSecond
    }
}

extension MetricsSnapshot {
    /// Merges another (usually partial) snapshot into this one: only non-nil /
    /// non-empty fields are overwritten, and the timestamp follows the
    /// incoming snapshot. Collectors produce sparse snapshots; this composes
    /// them into a complete picture of the current state.
    public mutating func merge(_ other: MetricsSnapshot) {
        timestamp = other.timestamp

        if other.cpu.usage != nil { cpu.usage = other.cpu.usage }
        if other.cpu.frequencyMHz != nil { cpu.frequencyMHz = other.cpu.frequencyMHz }
        if !other.cpu.perCoreUsage.isEmpty { cpu.perCoreUsage = other.cpu.perCoreUsage }
        if !other.cpu.perCoreLabels.isEmpty { cpu.perCoreLabels = other.cpu.perCoreLabels }
        if other.gpu.usage != nil { gpu.usage = other.gpu.usage }
        if other.gpu.powerWatts != nil { gpu.powerWatts = other.gpu.powerWatts }
        if other.memory.usedBytes != nil { memory.usedBytes = other.memory.usedBytes }
        if other.memory.totalBytes != nil { memory.totalBytes = other.memory.totalBytes }
        if other.memory.pressure != nil { memory.pressure = other.memory.pressure }
        if other.memory.swapUsedBytes != nil { memory.swapUsedBytes = other.memory.swapUsedBytes }
        if other.battery.percent != nil { battery.percent = other.battery.percent }
        if other.battery.powerWatts != nil { battery.powerWatts = other.battery.powerWatts }
        if other.battery.isCharging != nil { battery.isCharging = other.battery.isCharging }
        if !other.storageVolumes.isEmpty { storageVolumes = other.storageVolumes }
        if !other.displays.isEmpty { displays = other.displays }
        if !other.temperatures.isEmpty { temperatures = other.temperatures }
        if other.systemPowerWatts != nil { systemPowerWatts = other.systemPowerWatts }
        if other.diskReadBytesPerSecond != nil { diskReadBytesPerSecond = other.diskReadBytesPerSecond }
        if other.diskWriteBytesPerSecond != nil { diskWriteBytesPerSecond = other.diskWriteBytesPerSecond }
        if other.screenFramesPerSecond != nil { screenFramesPerSecond = other.screenFramesPerSecond }
    }
}

/// Which metric to show in the menu bar.
public enum MenuBarMetric: String, CaseIterable, Sendable {
    case power
    case cpuUsage
    case temperature

    public var title: String {
        switch self {
        case .power: return "功耗"
        case .cpuUsage: return "CPU 使用率"
        case .temperature: return "温度"
        }
    }
}
