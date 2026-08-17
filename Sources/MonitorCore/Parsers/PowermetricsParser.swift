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
                if snapshot.systemPowerWatts == nil {
                    snapshot.systemPowerWatts = milliWatts / 1000
                }
            } else if let milliWatts = number(in: line, after: "GPU Power:", before: "mW") {
                snapshot.gpu.powerWatts = milliWatts / 1000
            }

            if line.localizedCaseInsensitiveContains("active frequency"),
               !line.localizedCaseInsensitiveContains("GPU"),
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
