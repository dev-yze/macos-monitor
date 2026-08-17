import AppKit
import MonitorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MetricsStore()

    private var samplingTask: Task<Void, Never>?
    private var advancedStream: PowermetricsStream?
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
        startAdvancedStream()
    }

    func applicationWillTerminate(_ notification: Notification) {
        samplingTask?.cancel()
        advancedStream?.stop()
        screenFrameRateStream?.stop()
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
            store.merge(system.collect())
            store.merge(battery.collect())
            store.merge(display.collect())
            store.merge(storage.collect())
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
            } catch {
                guard self?.screenFrameRateStream === stream else { return }
                self?.store.setScreenFramesPerSecond(nil)
                self?.store.updateStatus(name: "屏幕 FPS", state: .unavailable(error.localizedDescription))
                self?.screenFrameRateStream = nil
            }
        }
    }

    // MARK: - Advanced sampling (root LaunchDaemon helper)

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
        let stream = PowermetricsStream()
        advancedStream = stream

        stream.onSample = { [weak self] sample in
            Task { @MainActor [weak self] in
                self?.store.merge(sample)
                self?.store.updateStatus(name: "高级指标", state: .running)
            }
        }

        stream.onEnd = { [weak self] in
            Task { @MainActor [weak self] in
                self?.store.updateStatus(name: "高级指标", state: .failed("高级指标已停止"))
            }
        }

        stream.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.store.updateStatus(name: "高级指标", state: .failed(message))
            }
        }

        try stream.start()
    }

    private func installHelperThenStart() {
        store.updateStatus(name: "高级指标", state: .unavailable("首次需要安装后台服务…"))

        let completion: @MainActor (Result<Void, HelperInstallerError>) -> Void = { [weak self] result in
            switch result {
            case .success:
                self?.store.updateStatus(name: "高级指标", state: .unavailable("启动中…"))
                self?.retryStartStream()
            case .failure(let error):
                switch error {
                case .authorizationDenied:
                    self?.store.updateStatus(name: "高级指标", state: .unavailable("未授权安装后台服务（重启 App 可重试）"))
                case .installFailed(let message):
                    self?.store.updateStatus(name: "高级指标", state: .failed("后台服务安装失败：\(message)"))
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
