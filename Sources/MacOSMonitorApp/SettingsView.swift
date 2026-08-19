import AppKit
import CoreGraphics
import MonitorCore
import SwiftUI

struct SettingsView: View {
    let store: MetricsStore

    @State private var showUninstallConfirm = false
    @State private var helperActionInProgress = false
    @State private var helperMessage: String?
    /// 每次 App 重新激活 +1，驱动 hasScreenCapturePermission 重新求值
    /// （用户在系统设置里授权并返回后，「前往授权」行自动消失）。
    @State private var permissionRefreshTick = 0

    /// 屏幕录制权限（CGPreflightScreenCaptureAccess 非响应式，靠 tick 刷新）。
    private var hasScreenCapturePermission: Bool {
        _ = permissionRefreshTick
        return CGPreflightScreenCaptureAccess()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mac 能耗监控")
                    .font(.headline)
                Spacer()
                MacaronBadge(text: appVersion, color: Macaron.lavender)
            }
            Divider()
            section("设置", color: Macaron.lavender) {
                Picker("采样间隔", selection: samplingIntervalBinding) {
                    Text("1 秒").tag(TimeInterval(1))
                    Text("2 秒").tag(TimeInterval(2))
                    Text("5 秒").tag(TimeInterval(5))
                    Text("10 秒").tag(TimeInterval(10))
                }
                Picker("菜单栏显示", selection: menuBarMetricBinding) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                Toggle("采集实时屏幕 FPS", isOn: screenFramesPerSecondBinding)
                    .help("开启后需要屏幕录制权限，并会统计主显示器最近一秒的捕获帧数")
                if store.screenFramesPerSecondEnabled && !hasScreenCapturePermission {
                    HStack(spacing: 8) {
                        Text("未授予屏幕录制权限")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("前往授权…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }
            }
            section("后台服务", color: Macaron.sky) {
                helperContent
            }
            section("状态", color: Macaron.mint) {
                statusContent
            }
            HStack {
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshTick += 1
        }
        .alert("卸载后台服务？", isPresented: $showUninstallConfirm) {
            Button("卸载", role: .destructive) { uninstallHelper() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止并删除 root LaunchDaemon 与命名管道。高级指标（功耗/GPU/频率/温度）将不可用，需要一次管理员授权。")
        }
    }

    /// 版本号单一来源：打包产物的 Info.plist；裸跑（swift run/debug）时显示 dev。
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.flatMap { "v\($0)" } ?? "dev"
    }

    private var samplingIntervalBinding: Binding<TimeInterval> {
        Binding(
            get: { store.samplingInterval },
            set: { store.setSamplingInterval($0) }
        )
    }

    private var menuBarMetricBinding: Binding<MenuBarMetric> {
        Binding(
            get: { store.menuBarMetric },
            set: { store.setMenuBarMetric($0) }
        )
    }

    private var screenFramesPerSecondBinding: Binding<Bool> {
        Binding(
            get: { store.screenFramesPerSecondEnabled },
            set: { store.setScreenFramesPerSecondEnabled($0) }
        )
    }

    // MARK: - 后台服务（root LaunchDaemon 生命周期）

    @ViewBuilder
    private var helperContent: some View {
        HStack(spacing: 8) {
            if store.advancedMonitoringEnabled {
                Button("卸载后台服务…", role: .destructive) {
                    showUninstallConfirm = true
                }
            } else {
                Button("安装后台服务…") {
                    helperMessage = nil
                    store.setAdvancedMonitoringEnabled(true)
                }
            }
            if helperActionInProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(helperActionInProgress)

        if let helperMessage {
            Text(helperMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !store.advancedMonitoringEnabled {
            Text("高级指标（功耗/GPU/频率/温度）不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func uninstallHelper() {
        helperActionInProgress = true
        helperMessage = nil
        DebugLog.log("helper uninstall started")
        Task.detached(priority: .userInitiated) {
            do {
                try HelperInstaller.uninstall()
                DebugLog.log("helper uninstall finished: success")
                await MainActor.run {
                    // 翻转开关：AppDelegate 会停流、取消重连并把状态置为空闲。
                    store.setAdvancedMonitoringEnabled(false)
                    helperMessage = "后台服务已卸载"
                    helperActionInProgress = false
                }
            } catch HelperInstallerError.authorizationDenied {
                DebugLog.log("helper uninstall finished: authorization denied")
                await MainActor.run {
                    helperMessage = "已取消授权，未卸载"
                    helperActionInProgress = false
                }
            } catch {
                DebugLog.log("helper uninstall finished: \(error.localizedDescription)")
                await MainActor.run {
                    helperMessage = "卸载失败：\(error.localizedDescription)"
                    helperActionInProgress = false
                }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if !store.hasData {
            Label("正在初始化…", systemImage: "hourglass")
                .font(.callout)
        } else if store.isStale() {
            Label("数据可能已过期", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        ForEach(sortedStatusKeys, id: \.self) { name in
            if let status = store.collectorStatuses[name] {
                HStack {
                    Text(name)
                        .font(.caption)
                    Spacer()
                    MacaronBadge(text: detail(for: status.state), color: tint(for: status.state))
                }
            }
        }
    }

    private var sortedStatusKeys: [String] {
        store.collectorStatuses.keys.sorted()
    }

    private func detail(for state: CollectorStatus.State) -> String {
        switch state {
        case .idle: return "空闲"
        case .running: return "正常"
        case .unavailable(let reason): return reason
        case .failed(let reason): return "失败：\(reason)"
        }
    }

    private func tint(for state: CollectorStatus.State) -> Color {
        switch state {
        case .running: return Macaron.mint
        case .idle: return .secondary
        case .unavailable: return Macaron.cream
        case .failed: return Macaron.rose
        }
    }

    private func section<Content: View>(_ title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}
