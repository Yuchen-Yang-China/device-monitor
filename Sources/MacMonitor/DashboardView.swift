import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    @State private var selectedMetric: MetricKind?

    var body: some View {
        Group {
            if let selectedMetric {
                MetricDetailView(metric: selectedMetric, store: store) {
                    self.selectedMetric = nil
                }
            } else {
                overview
            }
        }
        .frame(width: 360)
        .padding(16)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("System")
                    .font(.headline)
                Spacer()
                Text(store.snapshot.capturedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                OverviewMetricRow(
                    kind: .cpu,
                    value: store.snapshot.cpu.primaryText,
                    state: store.snapshot.cpu.level,
                    subtitle: "Processor utilization"
                ) { selectedMetric = .cpu }
                Divider()
                OverviewMetricRow(
                    kind: .memory,
                    value: store.snapshot.memory.primaryText,
                    state: store.snapshot.memory.level,
                    subtitle: "Memory pressure"
                ) { selectedMetric = .memory }
                Divider()
                OverviewMetricRow(
                    kind: .thermal,
                    value: store.snapshot.thermal.primaryText,
                    state: store.snapshot.thermal.level,
                    subtitle: "Average PMU die sensors"
                ) { selectedMetric = .thermal }
            }

            Divider()

            Button { selectedMetric = .network } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Network", systemImage: MetricKind.network.symbol)
                            .font(.headline)
                        Spacer()
                    }
                    HStack {
                        LabeledContent("Upload", value: store.snapshot.network.uploadText)
                        Spacer()
                        LabeledContent("Download", value: store.snapshot.network.downloadText)
                    }
                    .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()

            HStack {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.borderless)
            }
            .font(.subheadline)
        }
    }
}

private struct OverviewMetricRow: View {
    let kind: MetricKind
    let value: String
    let state: MetricLevel
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .frame(width: 16)
                    .foregroundStyle(state.swiftUIColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .monospacedDigit()
                    StatusLabel(level: state)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
    }
}

struct StatusLabel: View {
    let level: MetricLevel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(level.swiftUIColor)
                .frame(width: 6, height: 6)
            Text(level.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct MetricDetailView: View {
    let metric: MetricKind
    @ObservedObject var store: MonitorStore
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")
                .focusable(false)
                Text(metric.title)
                    .font(.headline)
                Spacer()
                if metric != .network {
                    StatusLabel(level: level)
                }
            }

            Text(primaryText)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if metric != .network {
                TrendSection(
                    title: "Last 5 minutes",
                    points: primaryTrend,
                    color: level.swiftUIColor,
                    range: trendRange
                )
            }

            if metric == .network {
                Divider()
                TrendSection(title: "Upload", points: store.uploadTrend, color: Color(nsColor: .systemBlue))
                TrendSection(title: "Download", points: store.downloadTrend, color: Color(nsColor: .systemTeal))
            } else {
                Divider()
                if metric == .thermal {
                    TemperatureDetails(reading: store.snapshot.thermal)
                } else {
                    Text(detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var level: MetricLevel {
        switch metric {
        case .cpu: return store.snapshot.cpu.level
        case .memory: return store.snapshot.memory.level
        case .thermal: return store.snapshot.thermal.level
        case .network: return .normal
        }
    }

    private var primaryText: String {
        switch metric {
        case .cpu: return store.snapshot.cpu.primaryText
        case .memory: return store.snapshot.memory.primaryText
        case .thermal: return store.snapshot.thermal.primaryText
        case .network: return "\u{2191} \(store.snapshot.network.uploadText)   \u{2193} \(store.snapshot.network.downloadText)"
        }
    }

    private var primaryTrend: [TrendPoint] {
        switch metric {
        case .cpu: return store.cpuTrend
        case .memory: return store.memoryTrend
        case .thermal: return store.thermalTrend
        case .network: return []
        }
    }

    private var trendRange: ClosedRange<Double>? {
        switch metric {
        case .cpu, .memory: return 0...100
        case .thermal: return 20...100
        case .network: return nil
        }
    }

    private var detailText: String {
        switch metric {
        case .cpu: return "Utilization is sampled every 5 seconds."
        case .memory: return "Uses memory pressure events with a physical-memory estimate."
        case .thermal: return ""
        case .network: return ""
        }
    }
}

struct TemperatureDetails: View {
    let reading: ThermalReading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Thermal Pressure", value: reading.state.rawValue)
            LabeledContent(HardwareInfo.hottestSensorTitle, value: reading.hottestSoCText)
            LabeledContent("SSD Temperature", value: reading.ssdText)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

struct TrendSection: View {
    let title: String
    let points: [TrendPoint]
    let color: Color
    var range: ClosedRange<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            Sparkline(points: points, color: color, range: range)
                .frame(height: 72)
            if points.count < 2 {
                Text("Collecting data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Sparkline: View {
    let points: [TrendPoint]
    let color: Color
    let range: ClosedRange<Double>?

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let minimum = range?.lowerBound ?? values.min() ?? 0
            let maximum = range?.upperBound ?? values.max() ?? 1
            let span = max(maximum - minimum, 1)

            Path { path in
                guard !points.isEmpty else { return }
                for (index, point) in points.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
                    let normalized = (point.value - minimum) / span
                    let y = proxy.size.height * (1 - normalized)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .background(Color(nsColor: .separatorColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, onBack: @escaping () -> Void) {
        let controller = NSHostingController(rootView: SettingsView(settings: settings, onBack: onBack))
        let window = NSWindow(contentViewController: controller)
        window.title = "Mac Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 420, height: 310))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")
                .focusable(false)
                .focusEffectDisabled()
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Form {
                Picker("Menu bar", selection: $settings.displayMode) {
                    ForEach(MenuDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Show network speed", isOn: $settings.showNetwork)
                Section("Temperature data") {
                    LabeledContent("SoC source", value: "Apple Silicon PMU die sensors")
                    LabeledContent("Thermal pressure", value: "macOS system state")
                    Text("Unavailable values are not estimated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Sampling") {
                    LabeledContent("Network", value: "1 second")
                    LabeledContent("CPU and memory", value: "5 seconds")
                    LabeledContent("Temperature", value: "15 seconds")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 310)
    }
}
