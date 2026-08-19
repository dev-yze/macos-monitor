import Foundation

/// Sanity bounds for values parsed from the powermetrics FIFO. The pipe is
/// writable by any local process (root:admin 0660 at best), so treat every
/// number as untrusted: out-of-range values are dropped instead of being
/// shown in the UI or triggering (future) threshold alerts.
public enum MetricSanity {
    public static func watts(_ value: Double) -> Double? {
        (0...500).contains(value) ? value : nil
    }

    public static func megahertz(_ value: Double) -> Double? {
        (0...10_000).contains(value) ? value : nil
    }

    /// GPU active residency as reported by powermetrics, in percent.
    public static func percent(_ value: Double) -> Double? {
        (0...100).contains(value) ? value : nil
    }

    public static func celsius(_ value: Double) -> Double? {
        (-40...150).contains(value) ? value : nil
    }
}

public enum PowermetricsParser {
    /// Parse output plus the number of values dropped by sanity checks.
    public struct ParseResult: Equatable {
        public let snapshot: MetricsSnapshot
        public let droppedInvalidCount: Int
    }

    public static func parse(_ text: String, timestamp: Date = Date()) -> MetricsSnapshot {
        parseDetailed(text, timestamp: timestamp).snapshot
    }

    public static func parseDetailed(_ text: String, timestamp: Date = Date()) -> ParseResult {
        var snapshot = MetricsSnapshot(timestamp: timestamp)
        var temperatures: [TemperatureMetric] = []
        var bestCPUFrequency: Double?
        var dropped = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let milliWatts = number(in: line, after: "Combined Power (CPU + GPU + ANE):", before: "mW") {
                if let watts = MetricSanity.watts(milliWatts / 1000) {
                    snapshot.systemPowerWatts = watts
                } else {
                    dropped += 1
                }
            } else if let milliWatts = number(in: line, after: "CPU Power:", before: "mW") {
                if snapshot.systemPowerWatts == nil {
                    if let watts = MetricSanity.watts(milliWatts / 1000) {
                        snapshot.systemPowerWatts = watts
                    } else {
                        dropped += 1
                    }
                }
            } else if let milliWatts = number(in: line, after: "GPU Power:", before: "mW") {
                if let watts = MetricSanity.watts(milliWatts / 1000) {
                    snapshot.gpu.powerWatts = watts
                } else {
                    dropped += 1
                }
            }

            if line.localizedCaseInsensitiveContains("active frequency"),
               !line.localizedCaseInsensitiveContains("GPU"),
               let mhz = number(in: line, after: ":", before: "MHz") {
                if MetricSanity.megahertz(mhz) != nil {
                    bestCPUFrequency = max(bestCPUFrequency ?? 0, mhz)
                } else {
                    dropped += 1
                }
            }

            if let residency = number(in: line, after: "GPU HW active residency:", before: "%") {
                if MetricSanity.percent(residency) != nil {
                    snapshot.gpu.usage = residency / 100
                } else {
                    dropped += 1
                }
            }

            if line.localizedCaseInsensitiveContains("temperature"),
               let celsius = number(in: line, after: ":", before: "C") {
                if MetricSanity.celsius(celsius) != nil {
                    let name = line.components(separatedBy: ":").first?
                        .replacingOccurrences(of: " temperature", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Temperature"
                    temperatures.append(TemperatureMetric(name: name, celsius: celsius))
                } else {
                    dropped += 1
                }
            }
        }

        snapshot.cpu.frequencyMHz = bestCPUFrequency
        snapshot.temperatures = temperatures
        return ParseResult(snapshot: snapshot, droppedInvalidCount: dropped)
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
