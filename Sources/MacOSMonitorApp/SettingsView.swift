import AppKit
import MonitorCore
import SwiftUI

struct SettingsView: View {
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("设置") {
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
            section("状态") {
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
                    Spacer()
                    Text(detail(for: status.state))
                        .foregroundStyle(tint(for: status.state))
                }
                .font(.caption)
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
        case .running, .idle: return .secondary
        case .unavailable, .failed: return .orange
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
