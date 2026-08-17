import MonitorCore
import SwiftUI

/// The left-click popover: live monitoring metrics only.
struct MonitorMenuView: View {
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            section("CPU", color: Macaron.sakura) {
                metricGroup([
                    ("使用率", MetricFormatters.percent(store.current.cpu.usage)),
                    ("频率", frequencyText(store.current.cpu.frequencyMHz))
                ])
                if !store.current.cpu.perCoreUsage.isEmpty {
                    perCoreChart(store.current.cpu.perCoreUsage, labels: store.current.cpu.perCoreLabels)
                }
            }
            section("GPU", color: Macaron.mint) {
                metricGroup([
                    ("使用率", MetricFormatters.percent(store.current.gpu.usage)),
                    ("功耗", MetricFormatters.watts(store.current.gpu.powerWatts))
                ])
            }
            section("内存", color: Macaron.cream, badge: MacaronBadge(text: pressureText(store.current.memory.pressure), color: pressureColor(store.current.memory.pressure))) {
                metricGroup([
                    ("已用", "\(MetricFormatters.bytes(store.current.memory.usedBytes)) / \(MetricFormatters.bytes(store.current.memory.totalBytes))"),
                    ("Swap", MetricFormatters.bytes(store.current.memory.swapUsedBytes))
                ])
            }
            section("电池", color: Macaron.peach, badge: MacaronBadge(text: store.current.battery.isCharging == true ? "充电中" : "未充电", color: batteryStatusColor())) {
                metricGroup([
                    ("电量", MetricFormatters.percent(store.current.battery.percent)),
                    ("功率", MetricFormatters.watts(store.current.battery.powerWatts))
                ])
            }
            section("磁盘", color: Macaron.sky) {
                metricGroup([
                    ("读取", MetricFormatters.throughput(store.current.diskReadBytesPerSecond)),
                    ("写入", MetricFormatters.throughput(store.current.diskWriteBytesPerSecond))
                ])
            }
            section("外部存储", color: Macaron.lavender) {
                if store.current.storageVolumes.isEmpty {
                    Text("未检测到外部存储").foregroundStyle(.secondary)
                } else {
                    ForEach(store.current.storageVolumes) { volume in
                        metricRow(volume.name, "\(MetricFormatters.bytes(volume.availableBytes)) 可用")
                    }
                }
            }
            section("显示器", color: Macaron.coral) {
                if store.current.displays.isEmpty {
                    Text("未检测到显示器").foregroundStyle(.secondary)
                } else {
                    metricGroup(store.current.displays.map { ($0.name, refreshRateText($0.refreshRate)) })
                }
            }
            section("温度", color: Macaron.rose) {
                if store.current.temperatures.isEmpty {
                    Text("高级温度数据不可用").foregroundStyle(.secondary)
                } else {
                    ForEach(store.current.temperatures) { temperature in
                        metricRow(temperature.name, MetricFormatters.celsius(temperature.celsius))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac 能耗监控")
                        .font(.headline)
                    Text("最近更新 \(store.current.timestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(MetricFormatters.watts(store.current.systemPowerWatts))
                    .font(.title2.monospacedDigit())
            }
            sparkline(powerHistory())
        }
    }

    // MARK: - Charts

    private func powerHistory() -> [Double] {
        store.history.compactMap { $0.systemPowerWatts }
    }

    private func sparkline(_ values: [Double]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            if values.count >= 2 {
                let minValue = values.min() ?? 0
                let maxValue = values.max() ?? 1
                let range = max(maxValue - minValue, 0.001)
                let step = width / CGFloat(values.count - 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height - height * CGFloat((value - minValue) / range)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Macaron.sakura, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func perCoreChart(_ usages: [Double], labels: [String]) -> some View {
        let perRow = 10
        let rows = stride(from: 0, to: usages.count, by: perRow).map { start in
            Array(usages[start..<min(start + perRow, usages.count)])
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowUsages in
                let start = rowIndex * perRow
                let rowLabels = Array(labels.dropFirst(start).prefix(perRow))
                perCoreRow(rowUsages, labels: rowLabels)
            }
        }
    }

    private func perCoreRow(_ usages: [Double], labels: [String]) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(usages.enumerated()), id: \.offset) { _, usage in
                    let clamped = min(max(usage, 0), 1)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(coreColor(clamped))
                        .frame(height: max(4, CGFloat(clamped) * 40))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40, alignment: .bottom)
            .animation(.easeOut(duration: 0.3), value: usages)

            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private func coreColor(_ usage: Double) -> Color {
        Macaron.coreUsage(usage)
    }

    // MARK: - Row helpers

    private func section<Content: View>(
        _ title: String,
        color: Color,
        badge: MacaronBadge? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let badge {
                    Spacer()
                    badge
                }
            }
            content()
        }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.callout)
    }

    /// Multiple metrics in one row (label/value cells side by side).
    private func metricGroup(_ items: [(String, String)]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                metricCell(item.0, item.1)
            }
        }
    }

    private func metricCell(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pressureText(_ level: Double?) -> String {
        guard let level else { return "--" }
        switch level {
        case 0.5: return "偏高"
        case 1.0: return "严重"
        default: return "正常"
        }
    }

    private func pressureColor(_ level: Double?) -> Color {
        guard let level else { return .secondary }
        switch level {
        case 0.5: return Macaron.cream
        case 1.0: return Macaron.rose
        default: return Macaron.mint
        }
    }

    private func batteryStatusColor() -> Color {
        store.current.battery.isCharging == true ? Macaron.mint : Macaron.lavender
    }

    private func frequencyText(_ value: Double?) -> String {
        guard let value else { return "-- MHz" }
        return String(format: "%.0f MHz", value)
    }

    private func refreshRateText(_ value: Double?) -> String {
        guard let value, value > 0 else { return "-- Hz" }
        return String(format: "%.0f Hz", value)
    }
}
