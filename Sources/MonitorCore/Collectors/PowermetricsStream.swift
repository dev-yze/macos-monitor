import Darwin
import Foundation

public enum PowermetricsStreamError: Error, Equatable {
    case helperNotRunning
    case launchFailed(String)
}

/// Reads `powermetrics` samples from the named pipe written by the root
/// LaunchDaemon helper. The app no longer runs `powermetrics` itself, so no
/// administrator password is required at runtime.
public final class PowermetricsStream: @unchecked Sendable {
    public static let fifoPath = "/tmp/macosmonitor.powermetrics.fifo"

    public var onSample: ((MetricsSnapshot) -> Void)?
    public var onEnd: (() -> Void)?
    public var onFailure: ((String) -> Void)?

    /// If no sample arrives within this window after launch, treat the stream as failed.
    private static let startupTimeout: TimeInterval = 15

    private let path: String
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var readBuffer = Data()
    private var splitter = PowermetricsSampleSplitter()
    private var watchdog: DispatchWorkItem?
    private var receivedFirstSample = false

    public init(fifoPath: String = PowermetricsStream.fifoPath) {
        self.path = fifoPath
    }

    /// Opens the helper's FIFO for reading. Throws `helperNotRunning` when the
    /// helper (LaunchDaemon) has not created the pipe yet.
    public func start() throws {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw PowermetricsStreamError.helperNotRunning
        }
        // 排空管道：丢弃（重连前）积压在管道缓冲里的旧样本与不完整数据。
        // parser 用 Date() 打时间戳，旧字节一旦进入 splitter 会被当成「现在」
        // 的样本解析出来，污染历史与 sparkline。fd 仍是 O_NONBLOCK，read 在
        // 无数据（EAGAIN）或无 writer（EOF）时立即结束。
        var drainChunk = [UInt8](repeating: 0, count: 64 * 1024)
        while read(fd, &drainChunk, drainChunk.count) > 0 {}

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }

        lock.lock()
        readBuffer = Data()
        splitter = PowermetricsSampleSplitter()
        receivedFirstSample = false
        lock.unlock()

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lock.lock()
        fileHandle = handle
        lock.unlock()
        handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }

        armWatchdog()
    }

    public func stop() {
        lock.lock()
        disarmWatchdogLocked()
        let handle = fileHandle
        fileHandle = nil
        lock.unlock()

        handle?.readabilityHandler = nil
    }

    // MARK: - Watchdog

    private func armWatchdog() {
        let work = DispatchWorkItem { [weak self] in self?.watchdogFired() }
        lock.lock()
        watchdog = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.startupTimeout, execute: work)
    }

    private func disarmWatchdogLocked() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogFired() {
        lock.lock()
        let hasSample = receivedFirstSample
        lock.unlock()
        guard !hasSample else { return }
        stop()
        onFailure?("高级指标启动超时（\(Int(Self.startupTimeout)) 秒未收到数据）")
    }

    // MARK: - Streaming

    private func consume(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            lock.unlock()
            fileHandle?.readabilityHandler = nil
            onEnd?()
            return
        }
        readBuffer.append(data)
        var samples: [MetricsSnapshot] = []
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if let sample = splitter.consume(line: line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                samples.append(sample)
            }
        }
        if !samples.isEmpty {
            receivedFirstSample = true
            disarmWatchdogLocked()
        }
        lock.unlock()
        for sample in samples {
            onSample?(sample)
        }
    }
}
