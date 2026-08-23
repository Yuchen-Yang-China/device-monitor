import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onDetailDemand: (MetricKind?) -> Void
    @State private var selectedMetric: MetricKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let popoverWidth: CGFloat = 360
        static let contentWidth: CGFloat = 336
        static let overviewHeight: CGFloat = 276
        static let detailHeight: CGFloat = 376
        static let padding: CGFloat = 12
    }

    var body: some View {
        Group {
            if let selectedMetric {
                ScrollView(.vertical, showsIndicators: true) {
                    MetricDetailView(metric: selectedMetric, store: store) {
                        select(nil)
                    }
                    .padding(.bottom, 4)
                }
                .frame(width: Layout.contentWidth, height: Layout.detailHeight, alignment: .topLeading)
                .id(selectedMetric)
                .transition(detailTransition)
            } else {
                overview
                    .frame(width: Layout.contentWidth, height: Layout.overviewHeight, alignment: .topLeading)
                    .transition(overviewTransition)
            }
        }
        .frame(width: Layout.contentWidth, height: selectedMetric == nil ? Layout.overviewHeight : Layout.detailHeight, alignment: .topLeading)
        .padding(Layout.padding)
        .frame(
            width: Layout.popoverWidth,
            height: (selectedMetric == nil ? Layout.overviewHeight : Layout.detailHeight) + Layout.padding * 2,
            alignment: .topLeading
        )
        .background(VisualEffectBackground(material: .popover))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedMetric)
    }

    private var overviewTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .move(edge: .leading))
    }

    private var detailTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .move(edge: .trailing))
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
                ) { select(.cpu) }
                Divider()
                OverviewMetricRow(
                    kind: .memory,
                    value: store.snapshot.memory.primaryText,
                    state: store.snapshot.memory.level,
                    subtitle: "Memory pressure"
                ) { select(.memory) }
                Divider()
                OverviewMetricRow(
                    kind: .thermal,
                    value: store.snapshot.thermal.primaryText,
                    state: store.snapshot.thermal.level,
                    subtitle: "Average temperature sensors"
                ) { select(.thermal) }
            }

            Divider()

            Button { select(.network) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Network", systemImage: MetricKind.network.symbol)
                            .font(.headline)
                        if store.snapshot.network.isStale {
                            NetworkFreshnessLabel()
                        }
                        Spacer()
                    }
                    HStack {
                        LabeledContent("Upload", value: store.snapshot.network.overviewUploadText)
                        Spacer()
                        LabeledContent("Download", value: store.snapshot.network.overviewDownloadText)
                    }
                    .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardRowButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Network")
            .accessibilityValue(store.snapshot.network.accessibilitySummary)
            .accessibilityHint("Show detailed network metrics")

            HStack {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                .accessibilityHint("Open Mac Monitor settings")
                .help("Settings")
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Quit Mac Monitor")
            }
            .font(.subheadline)
        }
    }

    private func select(_ metric: MetricKind?) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            selectedMetric = metric
        }
        onDetailDemand(metric)
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
                    NumericMetricText(value: value)
                    StatusLabel(level: state)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title), \(subtitle)")
        .accessibilityValue("\(value), \(state.label)")
        .accessibilityHint("Show detailed \(kind.title) metrics")
    }
}

struct DashboardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DashboardRowButton(configuration: configuration)
    }
}

private struct DashboardRowButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(0.12)
                            : isHovering ? Color.primary.opacity(0.06) : .clear
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                guard isHovering != hovering else { return }
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }
            }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(level.label)
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
                .accessibilityLabel("Back")
                .accessibilityHint("Return to the system overview")
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back")
                Text(metric.title)
                    .font(.headline)
                Spacer()
                if metric != .network {
                    StatusLabel(level: level)
                }
            }

            detailContent
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch metric {
        case .cpu:
            CPUDetailContent(
                reading: store.snapshot.cpu,
                trend: store.cpuTrend,
                processes: store.snapshot.topCPUProcesses,
                processSampledAt: store.snapshot.processSampledAt
            )
        case .memory:
            MemoryDetailContent(
                reading: store.snapshot.memory,
                trend: store.memoryTrend,
                processes: store.snapshot.topMemoryProcesses,
                processSampledAt: store.snapshot.processSampledAt
            )
        case .thermal:
            ThermalDetailContent(reading: store.snapshot.thermal, trend: store.thermalTrend)
        case .network:
            NetworkDetailContent(reading: store.snapshot.network, uploadTrend: store.uploadTrend, downloadTrend: store.downloadTrend)
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
}

struct CPUDetailContent: View {
    let reading: CPUReading
    let trend: [TrendPoint]
    let processes: [ProcessUsage]
    let processSampledAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: "Total utilization", color: reading.level.swiftUIColor)
            TrendSection(
                title: "Last 5 minutes",
                points: trend,
                color: reading.level.swiftUIColor,
                range: 0...100,
                stats: [
                    StatItem("Average", value: DisplayFormatter.percent(TrendMath.average(trend))),
                    StatItem("Peak", value: DisplayFormatter.percent(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: "CPU breakdown") {
                BreakdownRow(label: "User", value: DisplayFormatter.percent(reading.userPercent), color: .systemBlue)
                BreakdownRow(label: "System", value: DisplayFormatter.percent(reading.systemPercent), color: .systemOrange)
                BreakdownRow(label: "Idle", value: DisplayFormatter.percent(reading.idlePercent), color: .tertiaryLabelColor)
            }
            SectionBand(title: "Load average") {
                StatGrid(items: [
                    StatItem("5 min", value: DisplayFormatter.decimal(reading.loadAverage5)),
                    StatItem("15 min", value: DisplayFormatter.decimal(reading.loadAverage15))
                ])
            }
            SectionBand(title: "Hardware") {
                if reading.hasHybridCoreTopology {
                    StatGrid(items: [
                        StatItem("Performance cores", value: "\(reading.performanceCoreCount)"),
                        StatItem("Efficiency cores", value: "\(reading.efficiencyCoreCount)")
                    ])
                } else {
                    StatGrid(items: [
                        StatItem("Logical cores", value: "\(reading.performanceCoreCount)")
                    ])
                }
            }
            ProcessSection(
                title: "Top CPU processes",
                processes: processes,
                sampledAt: processSampledAt,
                mode: .cpu
            )
        }
    }
}

struct MemoryDetailContent: View {
    let reading: MemoryReading
    let trend: [TrendPoint]
    let processes: [ProcessUsage]
    let processSampledAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: "Memory pressure: \(reading.level.label)", color: reading.level.swiftUIColor)
            TrendSection(
                title: "Memory used · last 5 minutes",
                points: trend,
                color: reading.level.swiftUIColor,
                range: 0...100,
                stats: [
                    StatItem("Average", value: DisplayFormatter.percent(TrendMath.average(trend))),
                    StatItem("Peak", value: DisplayFormatter.percent(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: "Memory breakdown") {
                StatGrid(items: [
                    StatItem("Wired", value: ByteFormatter.memory(reading.wiredBytes)),
                    StatItem("Compressed", value: ByteFormatter.memory(reading.compressedBytes)),
                    StatItem("Cached", value: ByteFormatter.memory(reading.cachedBytes)),
                    StatItem("Swap", value: reading.swapText)
                ])
            }
            ProcessSection(
                title: "Top memory processes",
                processes: processes,
                sampledAt: processSampledAt,
                mode: .memory
            )
        }
    }
}

struct ThermalDetailContent: View {
    let reading: ThermalReading
    let trend: [TrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: "Average \(HardwareInfo.temperatureTitle)", color: reading.level.swiftUIColor)
            TrendSection(
                title: "\(HardwareInfo.temperatureTitle) · last 5 minutes",
                points: trend,
                color: reading.level.swiftUIColor,
                range: 20...100,
                stats: [
                    StatItem("Minimum", value: TemperatureFormatter.celsius(TrendMath.minimum(trend))),
                    StatItem("Average", value: TemperatureFormatter.celsius(TrendMath.average(trend))),
                    StatItem("Maximum", value: TemperatureFormatter.celsius(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: "System state") {
                StatGrid(items: [
                    StatItem("Thermal pressure", value: reading.state.rawValue),
                    StatItem(HardwareInfo.hottestSensorTitle, value: reading.hottestSoCText),
                    StatItem("SSD temperature", value: reading.ssdText)
                ])
            }
        }
    }
}

struct NetworkDetailContent: View {
    let reading: NetworkReading
    let uploadTrend: [TrendPoint]
    let downloadTrend: [TrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if reading.isStale {
                NetworkFreshnessLabel()
            }
            HStack(spacing: 18) {
                DirectionHero(
                    symbol: "arrow.up",
                    value: reading.isStale ? "Out of date" : reading.uploadText,
                    secondaryValue: reading.uploadLastKnownText,
                    color: reading.isStale ? .secondaryLabelColor : .systemBlue
                )
                DirectionHero(
                    symbol: "arrow.down",
                    value: reading.isStale ? "Out of date" : reading.downloadText,
                    secondaryValue: reading.downloadLastKnownText,
                    color: reading.isStale ? .secondaryLabelColor : .systemTeal
                )
            }
            TrendSection(
                title: "Upload · last 5 minutes",
                points: uploadTrend,
                color: Color(nsColor: .systemBlue),
                stats: networkStats(points: uploadTrend, sessionBytes: reading.sessionUploadBytes)
            )
            TrendSection(
                title: "Download · last 5 minutes",
                points: downloadTrend,
                color: Color(nsColor: .systemTeal),
                stats: networkStats(points: downloadTrend, sessionBytes: reading.sessionDownloadBytes)
            )
            Divider()
            SectionBand(title: "Wi-Fi") {
                if let wifi = reading.wifi, wifi.isAvailable {
                    StatGrid(items: [
                        StatItem("Signal", value: wifi.rssi.map { "\($0) dBm" } ?? "Unavailable"),
                        StatItem("Channel", value: wifi.channel.map(String.init) ?? "Unavailable")
                    ])
                } else {
                    UnavailableText(text: "Wi-Fi details are unavailable or the current connection is not Wi-Fi.")
                }
            }
        }
    }

    private func networkStats(points: [TrendPoint], sessionBytes: UInt64) -> [StatItem] {
        [
            StatItem("Average", value: ByteFormatter.rate(TrendMath.average(points))),
            StatItem("Peak", value: ByteFormatter.rate(TrendMath.peak(points))),
            StatItem("5 min total", value: ByteFormatter.transfer(TrendMath.cumulativeBytes(points))),
            StatItem("Session total", value: ByteFormatter.transfer(sessionBytes))
        ]
    }
}

struct DetailHero: View {
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            NumericMetricText(
                value: value,
                font: .system(size: 28, weight: .semibold, design: .rounded),
                color: color
            )
            .accessibilityLabel(caption)
            .accessibilityValue(value)
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct DirectionHero: View {
    let symbol: String
    let value: String
    var secondaryValue: String? = nil
    let color: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: color))
            NumericMetricText(
                value: value,
                font: .system(size: 20, weight: .semibold, design: .rounded),
                color: Color(nsColor: color)
            )
                .accessibilityLabel(symbol == "arrow.up" ? "Upload" : "Download")
                .accessibilityValue(secondaryValue.map { "\(value), last known \($0)" } ?? value)
            if let secondaryValue {
                Text("Last known \(secondaryValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NetworkFreshnessLabel: View {
    var body: some View {
        Label("Out of date", systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Network status")
            .accessibilityValue("Out of date")
    }
}

private extension NetworkReading {
    var uploadLastKnownText: String? {
        guard isStale, uploadBytesPerSecond != nil else { return nil }
        return uploadText
    }

    var downloadLastKnownText: String? {
        guard isStale, downloadBytesPerSecond != nil else { return nil }
        return downloadText
    }

    var overviewUploadText: String {
        staleDisplay(for: uploadText)
    }

    var overviewDownloadText: String {
        staleDisplay(for: downloadText)
    }

    var accessibilitySummary: String {
        let status: String
        if isStale {
            status = "Out of date"
        } else if uploadBytesPerSecond == nil, downloadBytesPerSecond == nil {
            status = "Unavailable"
        } else {
            status = "Current"
        }
        return "Network status \(status). Upload \(overviewUploadText), Download \(overviewDownloadText)"
    }

    private func staleDisplay(for value: String) -> String {
        guard isStale else { return value }
        guard value != "Unavailable", value != "--B/s" else { return "Unavailable" }
        return "Last \(value)"
    }
}

struct SectionBand<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.body.weight(.semibold))
            content()
        }
    }
}

struct BreakdownRow: View {
    let label: String
    let value: String
    let color: NSColor

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// Keeps live numeric updates readable without animating every sampling tick.
/// The numeric transition remains native, but is throttled to one animation per
/// two seconds and is disabled when Reduce Motion is enabled.
private struct NumericMetricText: View {
    let value: String
    var font: Font = .body
    var color: Color = .primary
    var animationInterval: TimeInterval = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationRevision = 0
    @State private var lastAnimatedAt = Date.distantPast

    var body: some View {
        Text(value)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: animationRevision
            )
            .onChange(of: value, initial: false) { _, _ in
                guard !reduceMotion else { return }
                let now = Date()
                guard now.timeIntervalSince(lastAnimatedAt) >= animationInterval else { return }
                lastAnimatedAt = now
                animationRevision &+= 1
            }
    }
}

struct StatItem: Identifiable {
    /// Labels are stable within each stat grid, so they provide a deterministic
    /// identity across snapshot updates and avoid rebuilding every cell.
    let id: String
    let label: String
    let value: String

    init(_ label: String, value: String, id: String? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

struct StatGrid: View {
    let items: [StatItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.label)
                .accessibilityValue(item.value)
            }
        }
    }
}

struct ProcessSection: View {
    enum Mode { case cpu, memory }

    let title: String
    let processes: [ProcessUsage]
    let sampledAt: Date?
    let mode: Mode

    var body: some View {
        SectionBand(title: title) {
            if processes.isEmpty, sampledAt == nil {
                UnavailableText(text: "Collecting process data")
            } else if processes.isEmpty {
                UnavailableText(text: "Process data unavailable")
            } else {
                VStack(spacing: 7) {
                    ForEach(processes) { process in
                        HStack(spacing: 8) {
                            Text(process.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(mode == .cpu ? process.cpuText : process.memoryText)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(process.name)
                        .accessibilityValue(mode == .cpu ? process.cpuText : process.memoryText)
                    }
                }
            }
        }
    }
}

struct UnavailableText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct TrendSection: View {
    let title: String
    let points: [TrendPoint]
    let color: Color
    var range: ClosedRange<Double>? = nil
    var stats: [StatItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.body.weight(.semibold))
            Sparkline(points: points, color: color, range: range)
                .frame(height: 60)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(points.isEmpty ? "Collecting data" : "\(points.count) samples")
            if !stats.isEmpty {
                StatGrid(items: stats)
            }
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
                    let normalized = min(1, max(0, (point.value - minimum) / span))
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

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, onResetNetworkTotals: @escaping () -> Void, onBack: @escaping () -> Void) {
        let controller = NSHostingController(rootView: SettingsView(
            settings: settings,
            onResetNetworkTotals: onResetNetworkTotals,
            onBack: onBack
        ))
        let window = NSWindow(contentViewController: controller)
        window.title = "Mac Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 420, height: 380))
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onResetNetworkTotals: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back")
                .accessibilityHint("Return to the monitor overview")
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back")
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
                Text(settings.displayMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show network speed", isOn: $settings.showNetwork)
                Picker("Sampling profile", selection: $settings.samplingProfile) {
                    ForEach(SamplingProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                Text(settings.samplingProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Section("Temperature data") {
                    LabeledContent("Temperature source", value: HardwareInfo.temperatureSource)
                    LabeledContent("Thermal pressure", value: "macOS system state")
                    Text("Unavailable values are not estimated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Sampling") {
                    LabeledContent("Current profile", value: settings.samplingProfile.title)
                    LabeledContent("Process data", value: "Only while CPU/Memory details are open")
                    LabeledContent("Wi-Fi data", value: "Only while Network details are open")
                }
                Section("Session data") {
                    Button("Reset network session totals", action: onResetNetworkTotals)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(VisualEffectBackground(material: .windowBackground))
        .frame(width: 420, height: 380)
    }
}
