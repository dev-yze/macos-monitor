import Foundation

#if DEBUG
/// DEBUG-only file log for observing background stream lifecycle
/// (reconnects, watchdog triggers) without a debugger attached.
/// View with: tail -f /tmp/macosmonitor-debug.log
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/macosmonitor-debug.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#else
enum DebugLog {
    static func log(_ message: String) {}
}
#endif
