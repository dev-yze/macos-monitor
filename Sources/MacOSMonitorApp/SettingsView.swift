import AppKit
import MonitorCore
import SwiftUI

struct SettingsView: View {
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mac 能耗监控")
                    .font(.headline)
                Spacer()
                MacaronBadge(text: "v1.0.0", color: Macaron.lavender)
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
