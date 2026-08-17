import CoreGraphics
import Foundation

public struct DisplayCollector {
    public init() {}

    public func collect() -> MetricsSnapshot {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        let displays = ids.enumerated().map { index, id in
            DisplayMetrics(
                id: id,
                name: "D\(index + 1)",
                refreshRate: CGDisplayCopyDisplayMode(id)?.refreshRate
            )
        }

        var snapshot = MetricsSnapshot()
        snapshot.displays = displays
        return snapshot
    }
}
