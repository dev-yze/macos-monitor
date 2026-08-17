import Darwin
import Foundation

/// Collects real CPU usage (tick deltas), memory usage, memory-pressure level,
/// and swap usage. Stateful: it remembers the previous CPU tick snapshot.
public final class SystemStatsCollector {
    private var previousTicks: [processor_cpu_load_info]?

    public init() {}

    public func collect() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        let cpu = cpuUsage()
        snapshot.cpu.usage = cpu.usage
        snapshot.cpu.perCoreUsage = cpu.perCore
        snapshot.cpu.perCoreLabels = coreLabels(count: cpu.perCore.count)
        snapshot.memory = memoryMetrics()
        return snapshot
    }

    /// Generates per-core display labels. On Apple Silicon the kernel reports
    /// efficiency cores first, then performance cores.
    private func coreLabels(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let performanceCount = physicalCPUCount(level: 0)
        let efficiencyCount = max(0, count - performanceCount)
        var labels: [String] = []
        for index in 0..<efficiencyCount { labels.append("E\(index + 1)") }
        for index in 0..<performanceCount { labels.append("P\(index + 1)") }
        return labels
    }

    private func physicalCPUCount(level: Int) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        let name = "hw.perflevel\(level).physicalcpu"
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    // MARK: - CPU

    /// Returns the overall (0…1) utilization and a per-core utilization array.
    private func cpuUsage() -> (usage: Double?, perCore: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        defer {
            if let info {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
            }
        }
        guard result == KERN_SUCCESS, let info else { return (nil, []) }

        let current = info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: Int(cpuCount)))
        }
        defer { previousTicks = current }

        guard let previous = previousTicks, previous.count == Int(cpuCount) else { return (nil, []) }

        var totalDelta: UInt64 = 0
        var usedDelta: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(Int(cpuCount))

        for index in 0..<Int(cpuCount) {
            let currentTicks = current[index].cpu_ticks
            let previousTicks = previous[index].cpu_ticks
            let user = UInt64(currentTicks.0) - UInt64(previousTicks.0)
            let system = UInt64(currentTicks.1) - UInt64(previousTicks.1)
            let idle = UInt64(currentTicks.2) - UInt64(previousTicks.2)
            let nice = UInt64(currentTicks.3) - UInt64(previousTicks.3)
            let used = user + system + nice
            let total = user + system + idle + nice
            usedDelta += used
            totalDelta += total
            perCore.append(total > 0 ? Double(used) / Double(total) : 0)
        }

        let overall = totalDelta > 0 ? Double(usedDelta) / Double(totalDelta) : nil
        return (overall, perCore)
    }

    // MARK: - Memory

    private func memoryMetrics() -> MemoryMetrics {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryMetrics(totalBytes: total, pressure: memoryPressureLevel(), swapUsedBytes: swapUsedBytes())
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let availableBytes = (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * pageSize
        let usedBytes = total > availableBytes ? total - availableBytes : 0

        return MemoryMetrics(
            usedBytes: usedBytes,
            totalBytes: total,
            pressure: memoryPressureLevel(),
            swapUsedBytes: swapUsedBytes()
        )
    }

    private func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// Maps the kernel memory-pressure level to a normalized 0…1 value.
    private func memoryPressureLevel() -> Double? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return 0.0
        case 2: return 0.5
        case 4: return 1.0
        default: return nil
        }
    }
}
