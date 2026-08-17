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
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unitIndex = 0

        while amount >= 1024, unitIndex < units.count - 1 {
            amount /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(amount)) B"
        }
        return String(format: "%.1f %@", amount, units[unitIndex])
    }

    public static func throughput(_ value: UInt64?) -> String {
        guard let value else { return "--/s" }
        return "\(bytes(value))/s"
    }

    public static func framesPerSecond(_ value: Double?) -> String {
        guard let value else { return "-- FPS" }
        return String(format: "%.0f FPS", value)
    }
}
