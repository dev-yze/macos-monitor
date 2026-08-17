import Foundation
import IOKit
import IOKit.ps

public struct BatteryCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        let powerSource = powerSourceInfo()
        var snapshot = MetricsSnapshot()
        snapshot.battery = BatteryMetrics(
            percent: powerSource.percent,
            powerWatts: batteryPowerWatts(),
            isCharging: powerSource.isCharging
        )
        return snapshot
    }

    private func powerSourceInfo() -> (percent: Double?, isCharging: Bool?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return (nil, nil)
        }

        let current = description[kIOPSCurrentCapacityKey] as? Int
        let max = description[kIOPSMaxCapacityKey] as? Int
        let percent: Double?
        if let current, let max, max > 0 {
            percent = Double(current) / Double(max)
        } else {
            percent = nil
        }
        return (percent, description[kIOPSIsChargingKey] as? Bool)
    }

    /// Reads instantaneous battery power (watts) from the `AppleSmartBattery` node:
    /// Voltage (mV) × Amperage (mA) = µW, then / 1_000_000 to watts.
    private func batteryPowerWatts() -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let voltageMV = number(service, "Voltage"),
              let amperageMA = number(service, "Amperage") else {
            return nil
        }
        return abs(voltageMV * amperageMA) / 1_000_000
    }

    private func number(_ service: io_service_t, _ key: String) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let int = value as? Int { return Double(int) }
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
