import Foundation
import IOKit

/// Collects external-volume capacity and whole-system disk I/O throughput.
/// Stateful: it remembers the previous cumulative I/O counters to compute deltas.
public final class StorageCollector {
    private var previousIO: (read: UInt64, write: UInt64)?
    private var previousTimestamp: Date?

    public init() {}

    public func collect() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        snapshot.storageVolumes = volumeMetrics()

        let io = diskIOTotals()
        let now = Date()
        if let previous = previousIO, let previousTime = previousTimestamp {
            let elapsed = now.timeIntervalSince(previousTime)
            if elapsed > 0 {
                let readDelta = io.read >= previous.read ? io.read - previous.read : 0
                let writeDelta = io.write >= previous.write ? io.write - previous.write : 0
                snapshot.diskReadBytesPerSecond = UInt64(Double(readDelta) / elapsed)
                snapshot.diskWriteBytesPerSecond = UInt64(Double(writeDelta) / elapsed)
            }
        }
        previousIO = io
        previousTimestamp = now
        return snapshot
    }

    private func volumeMetrics() -> [StorageVolumeMetrics] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.compactMap { url -> StorageVolumeMetrics? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsInternal == false else { return nil }
            return StorageVolumeMetrics(
                name: values?.volumeName ?? url.lastPathComponent,
                mountPath: url.path,
                totalBytes: values?.volumeTotalCapacity.map(UInt64.init),
                availableBytes: values?.volumeAvailableCapacity.map(UInt64.init)
            )
        }
    }

    private func diskIOTotals() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var entry: io_registry_entry_t = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                totalRead += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                totalWrite += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (totalRead, totalWrite)
    }
}
