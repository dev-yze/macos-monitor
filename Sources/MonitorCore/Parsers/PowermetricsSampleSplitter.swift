import Foundation

/// Splits `powermetrics`' continuous text output into per-sample chunks,
/// using the explicit `*** Sampled system activity ... ***` marker as the boundary.
struct PowermetricsSampleSplitter {
    private var sampleBuffer = ""

    /// Feeds one trimmed line; returns a complete sample when a boundary is crossed.
    mutating func consume(line: String) -> MetricsSnapshot? {
        guard line.hasPrefix("*** Sampled system activity") else {
            sampleBuffer += line + "\n"
            return nil
        }
        let completed = sampleBuffer
        sampleBuffer = line + "\n"
        guard completed.contains("****") else { return nil }
        return PowermetricsParser.parse(completed)
    }
}
