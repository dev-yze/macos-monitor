import AppKit
import MonitorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MetricsStore()

    private var samplingTask: Task<Void, Never>?
    private var advancedStream: PowermetricsStream?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff = ReconnectBackoff()
    private var isTerminating = false
    /// 最近一次收到高级指标样本的时刻，供周期巡检判断流是否健康。
    private var lastAdvancedSampleAt = Date.distantPast
    /// 首次收到样本后置 true：此前由「安装/启动」路径负责，巡检不介入。
    private var advancedEverConnected = false
    private var advancedWatchdogTask: Task<Void, Never>?
    private var screenFrameRateStream: ScreenFrameRateStream?
    private var statusItem: NSStatusItem?
    private var parameterPopover: NSPopover?
    private var settingsPopover: NSPopover?
    private var clickOutsideMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observeTitleChanges()
        observeScreenFrameRateSetting()

        samplingTask = Task { [weak self] in
            await self?.runBasicSamplingLoop()
        }
        advancedWatchdogTask = Task { @MainActor [weak self] in
            await self?.runAdvancedWatchdogLoop()
        }
        observeAdvancedMonitoringSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        samplingTask?.cancel()
        reconnectTask?.cancel()
        advancedWatchdogTask?.cancel()
        advancedStream?.stop()
        screenFrameRateStream?.stop()
    }

    /// 用户可能刚在系统设置里授予了屏幕录制权限：FPS 开关处于开启但流
    /// 未运行时自动重试，无需手动拨动开关。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard store.screenFramesPerSecondEnabled,
              screenFrameRateStream == nil,
              CGPreflightScreenCaptureAccess() else { return }
        DebugLog.log("screen FPS: retrying after permission grant")
        configureScreenFrameRateStream()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            toggleSettingsPopover()
        } else {
            toggleParameterPopover()
        }
    }

    private func toggleParameterPopover() {
        guard let button = statusItem?.button else { return }
        if let popover = parameterPopover, popover.isShown {
            closePopovers()
            return
        }
        closePopovers()
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: MonitorMenuView(store: store))
        popover.behavior = .transient
        parameterPopover = popover
        show(popover, relativeTo: button)
    }

    private func toggleSettingsPopover() {
        guard let button = statusItem?.button else { return }
        if let popover = settingsPopover, popover.isShown {
            closePopovers()
            return
        }
        closePopovers()
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        popover.behavior = .transient
        settingsPopover = popover
        show(popover, relativeTo: button)
    }

    private func show(_ popover: NSPopover, relativeTo button: NSStatusBarButton) {
        // 激活 App，让 .transient 的「点击外部关闭」能正常生效
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installClickOutsideMonitor()
    }

    private func closePopovers() {
        parameterPopover?.performClose(nil)
        settingsPopover?.performClose(nil)
        removeClickOutsideMonitor()
    }

    /// 兜底：监听全局鼠标点击，点击面板外部时关闭（菜单栏 app 的 transient 有时不生效）。
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopovers()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Menu bar title

    private func observeTitleChanges() {
        withObservationTracking {
            _ = store.current.systemPowerWatts
            _ = store.current.cpu.usage
            _ = store.current.temperatures
            _ = store.menuBarMetric
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateTitle()
                self?.observeTitleChanges()
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        switch store.menuBarMetric {
        case .power:
            button.title = MetricFormatters.watts(store.current.systemPowerWatts)
        case .cpuUsage:
            button.title = MetricFormatters.percent(store.current.cpu.usage)
        case .temperature:
            if let celsius = store.current.temperatures.first?.celsius {
                button.title = MetricFormatters.celsius(celsius)
            } else {
                button.title = "-- C"
            }
        }
    }

    // MARK: - Basic sampling (always available, no privileges)

    private func runBasicSamplingLoop() async {
        let system = SystemStatsCollector()
        let battery = BatteryCollector()
        let display = DisplayCollector()
        let storage = StorageCollector()

        while !Task.isCancelled {
            // 一轮采集先合并成单条完整快照再入历史：每个采样周期恰好一条记录。
            // （过去每个采集器各 merge 一次，历史里全是半成品快照，条数是周期的 4 倍。）
            var cycle = MetricsSnapshot()
            cycle.merge(system.collect())
            cycle.merge(battery.collect())
            cycle.merge(display.collect())
            cycle.merge(storage.collect())
            store.merge(cycle)
            store.updateStatus(name: "基础指标", state: .running)

            try? await Task.sleep(nanoseconds: UInt64(store.samplingInterval * 1_000_000_000))
        }
    }

    // MARK: - Optional screen frame rate sampling

    private func observeScreenFrameRateSetting() {
        withObservationTracking {
            _ = store.screenFramesPerSecondEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.configureScreenFrameRateStream()
                self?.observeScreenFrameRateSetting()
            }
        }
        configureScreenFrameRateStream()
    }

    private func configureScreenFrameRateStream() {
        screenFrameRateStream?.stop()
        screenFrameRateStream = nil
        store.setScreenFramesPerSecond(nil)

        guard store.screenFramesPerSecondEnabled else {
            store.updateStatus(name: "屏幕 FPS", state: .idle)
            return
        }

        // 取证：TCC 对裸可执行文件按「路径+代码哈希」识别，重建二进制或
        // 授权后未重启进程都会表现为 preflight=false。
        DebugLog.log("screen FPS: configuring, preflight=\(CGPreflightScreenCaptureAccess())")

        let stream = ScreenFrameRateStream()
        screenFrameRateStream = stream
        stream.onFrameRate = { [weak self, weak stream] fps in
            Task { @MainActor [weak self] in
                guard self?.screenFrameRateStream === stream else { return }
                self?.store.setScreenFramesPerSecond(fps)
                self?.store.updateStatus(name: "屏幕 FPS", state: .running)
            }
        }
        stream.onFailure = { [weak self, weak stream] message in
            Task { @MainActor [weak self] in
                guard self?.screenFrameRateStream === stream else { return }
                self?.store.setScreenFramesPerSecond(nil)
                self?.store.updateStatus(name: "屏幕 FPS", state: .failed(message))
            }
        }

        Task { [weak self, weak stream] in
            do {
                try await stream?.start()
                DebugLog.log("screen FPS: stream started")
            } catch {
                DebugLog.log("screen FPS: stream failed: \(error.localizedDescription)")
                guard self?.screenFrameRateStream === stream else { return }
                self?.store.setScreenFramesPerSecond(nil)
                self?.store.updateStatus(name: "屏幕 FPS", state: .unavailable(error.localizedDescription))
                self?.screenFrameRateStream = nil
            }
        }
    }

    // MARK: - Advanced sampling (root LaunchDaemon helper)

    /// 跟随「高级监控」开关（设置面板里卸载/安装后台服务会翻转它）。
    private func observeAdvancedMonitoringSetting() {
        withObservationTracking {
            _ = store.advancedMonitoringEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.configureAdvancedMonitoring()
                self?.observeAdvancedMonitoringSetting()
            }
        }
        configureAdvancedMonitoring()
    }

    private func configureAdvancedMonitoring() {
        DebugLog.log("configure advanced monitoring: enabled=\(store.advancedMonitoringEnabled)")
        guard store.advancedMonitoringEnabled else {
            // 用户卸载了后台服务：彻底停流、取消重连，巡检也不再介入。
            DebugLog.log("advanced monitoring disabled, tearing down stream")
            reconnectTask?.cancel()
            advancedStream?.stop()
            advancedStream = nil
            advancedEverConnected = false
            reconnectBackoff = ReconnectBackoff()
            store.updateStatus(name: "高级指标", state: .idle)
            return
        }
        if HelperInstaller.needsUpgrade {
            // 旧版本 helper（如 FIFO 还是 666 权限）：一次性授权升级。
            DebugLog.log("helper is outdated, upgrading")
            installHelperThenStart(statusMessage: "正在升级后台服务…")
            return
        }
        startAdvancedStream()
    }

    private func startAdvancedStream() {
        store.updateStatus(name: "高级指标", state: .unavailable("启动中…"))
        do {
            try startStream()
        } catch PowermetricsStreamError.helperNotRunning {
            installHelperThenStart()
        } catch {
            store.updateStatus(name: "高级指标", state: .failed(error.localizedDescription))
        }
    }

    private func startStream() throws {
        // 替换旧流之前先停掉，避免旧 fd 占用/helper 侧以为还有读者。
        advancedStream?.stop()
        let stream = PowermetricsStream()
        advancedStream = stream

        stream.onSample = { [weak self, weak stream] sample in
            Task { @MainActor [weak self] in
                guard let self, self.advancedStream === stream else { return }
                if !self.advancedEverConnected || self.reconnectBackoff.attempt > 0 {
                    DebugLog.log("advanced stream: sample received (everConnected=\(self.advancedEverConnected), backoffAttempt=\(self.reconnectBackoff.attempt))")
                }
                self.advancedEverConnected = true
                self.lastAdvancedSampleAt = Date()
                self.reconnectBackoff.reset()
                // 高级样本只更新当前状态，不单独入历史：
                // 历史由基础采集周期统一产生，保证一个周期一条完整快照。
                self.store.merge(sample, recordsHistory: false)
                self.store.updateStatus(name: "高级指标", state: .running)
            }
        }

        stream.onEnd = { [weak self, weak stream] in
            Task { @MainActor [weak self] in
                guard let self, self.advancedStream === stream else { return }
                // helper 重建 FIFO 后旧 fd 读到 EOF：标记断开并自动重连。
                DebugLog.log("advanced stream: EOF")
                self.store.updateStatus(name: "高级指标", state: .unavailable("连接已断开"))
                self.scheduleReconnect()
            }
        }

        stream.onFailure = { [weak self, weak stream] message in
            Task { @MainActor [weak self] in
                guard let self, self.advancedStream === stream else { return }
                DebugLog.log("advanced stream: failure: \(message)")
                self.store.updateStatus(name: "高级指标", state: .failed(message))
                self.scheduleReconnect()
            }
        }

        try stream.start()
        DebugLog.log("advanced stream: started")
    }

    // MARK: - Advanced stream reconnect

    /// 指数退避自动重连（1s → 2s → … → 30s 封顶）。收到首个样本后退避重置。
    private func scheduleReconnect() {
        guard !isTerminating, store.advancedMonitoringEnabled else { return }
        reconnectTask?.cancel()
        let delay = reconnectBackoff.nextDelay()
        DebugLog.log("advanced stream: reconnect scheduled in \(Int(delay))s (attempt \(self.reconnectBackoff.attempt))")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard !isTerminating, store.advancedMonitoringEnabled else { return }
        store.updateStatus(name: "高级指标", state: .unavailable("重连中…"))
        do {
            try startStream()
        } catch PowermetricsStreamError.helperNotRunning {
            DebugLog.log("advanced stream: reconnect failed, helper not running")
            store.updateStatus(name: "高级指标", state: .unavailable("后台服务未运行，等待重试"))
            scheduleReconnect()
        } catch {
            DebugLog.log("advanced stream: reconnect failed: \(error.localizedDescription)")
            store.updateStatus(name: "高级指标", state: .failed(error.localizedDescription))
            scheduleReconnect()
        }
    }

    /// 周期兜底巡检：事件驱动重连存在盲区——重连瞬间 helper 可能尚未重建
    /// FIFO，App 会停在已删除的 inode 上，此后没有任何事件可等。每 10 秒
    /// 检查一次样本新鲜度，超过阈值直接重建流。
    private func runAdvancedWatchdogLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, !isTerminating else { return }
            // 高级监控被关闭（用户卸载了后台服务）时不介入。
            guard store.advancedMonitoringEnabled else { continue }
            // 首次连通前由「安装/启动」路径负责，巡检不介入。
            guard advancedEverConnected else { continue }
            let gap = Date().timeIntervalSince(lastAdvancedSampleAt)
            guard gap > 12 else { continue }
            DebugLog.log("advanced watchdog: no sample for \(Int(gap))s, forcing reconnect")
            store.updateStatus(name: "高级指标", state: .unavailable("数据中断，重连中…"))
            attemptReconnect()
        }
    }

    /// 安装/升级流程互斥：observation 偶发的重复触发（或任何其他重复入口）
    /// 都必须被挡在这里，否则用户会看到两个管理员授权框。
    private var helperInstallInProgress = false

    private func installHelperThenStart(statusMessage: String = "首次需要安装后台服务…") {
        guard !helperInstallInProgress else {
            DebugLog.log("helper install already in progress, ignoring duplicate request")
            return
        }
        helperInstallInProgress = true
        DebugLog.log("helper install started")
        store.updateStatus(name: "高级指标", state: .unavailable(statusMessage))

        let completion: @MainActor (Result<Void, HelperInstallerError>) -> Void = { [weak self] result in
            guard let self else { return }
            self.helperInstallInProgress = false
            DebugLog.log("helper install finished: \(result)")
            switch result {
            case .success:
                self.store.updateStatus(name: "高级指标", state: .unavailable("启动中…"))
                self.retryStartStream()
            case .failure(let error):
                switch error {
                case .authorizationDenied:
                    self.store.updateStatus(name: "高级指标", state: .unavailable("未授权安装后台服务（重启 App 可重试）"))
                case .installFailed(let message):
                    self.store.updateStatus(name: "高级指标", state: .failed("后台服务安装失败：\(message)"))
                }
            }
        }

        Task.detached(priority: .utility) {
            let result: Result<Void, HelperInstallerError>
            do {
                try HelperInstaller.install()
                result = .success(())
            } catch let error as HelperInstallerError {
                result = .failure(error)
            } catch {
                result = .failure(.installFailed(error.localizedDescription))
            }
            await completion(result)
        }
    }

    private func retryStartStream(attempt: Int = 0) {
        do {
            try startStream()
        } catch PowermetricsStreamError.helperNotRunning {
            guard attempt < 5 else {
                store.updateStatus(name: "高级指标", state: .failed("后台服务未运行"))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.retryStartStream(attempt: attempt + 1)
            }
        } catch {
            store.updateStatus(name: "高级指标", state: .failed(error.localizedDescription))
        }
    }
}
