import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var peerConfiguration: PeerConfiguration
    @ObservedObject var peerStore: PeerStatusStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onDetailDemand: (MetricKind?) -> Void
    let onPeerDetailDemand: (Bool) -> Void
    @State private var selectedMetric: MetricKind?
    @State private var isShowingPeerDetail = false
    @State private var selectedPeerMetric: MetricKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isInDetail: Bool { selectedMetric != nil || isShowingPeerDetail }

    private enum Layout {
        static let popoverWidth: CGFloat = 360
        static let contentWidth: CGFloat = 336
        static let overviewHeight: CGFloat = 358
        static let detailHeight: CGFloat = 376
        static let padding: CGFloat = 12
    }

    var body: some View {
        Group {
            if isShowingPeerDetail {
                ScrollView(.vertical, showsIndicators: false) {
                    PeerDetailView(
                        store: peerStore,
                        configuration: peerConfiguration,
                        selectedMetric: selectedPeerMetric,
                        onSelectMetric: selectPeerMetric,
                        onBack: {
                            if selectedPeerMetric == nil {
                                selectPeer(false)
                            } else {
                                selectPeerMetric(nil)
                            }
                        }
                    )
                    .padding(.bottom, 4)
                }
                .frame(width: Layout.contentWidth, height: Layout.detailHeight, alignment: .topLeading)
                .id(selectedPeerMetric?.rawValue ?? "peer-overview")
                .transition(detailTransition)
            } else if let selectedMetric {
                ScrollView(.vertical, showsIndicators: false) {
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
        .frame(width: Layout.contentWidth, height: isInDetail ? Layout.detailHeight : Layout.overviewHeight, alignment: .topLeading)
        .padding(Layout.padding)
        .frame(
            width: Layout.popoverWidth,
            height: (isInDetail ? Layout.detailHeight : Layout.overviewHeight) + Layout.padding * 2,
            alignment: .topLeading
        )
        .background(VisualEffectBackground(material: .popover))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedMetric)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isShowingPeerDetail)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedPeerMetric)
        .environment(\.appLanguage, peerConfiguration.language)
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
                Text(peerConfiguration.language.text("System", "系统"))
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
                    subtitle: peerConfiguration.language.text("Processor utilization", "处理器使用率")
                ) { select(.cpu) }
                Divider()
                OverviewMetricRow(
                    kind: .memory,
                    value: store.snapshot.memory.primaryText,
                    state: store.snapshot.memory.level,
                    subtitle: peerConfiguration.language.text("Memory pressure", "内存压力")
                ) { select(.memory) }
                Divider()
                OverviewMetricRow(
                    kind: .thermal,
                    value: store.snapshot.thermal.primaryText,
                    state: store.snapshot.thermal.level,
                    subtitle: peerConfiguration.language.text("Average temperature sensors", "平均传感器温度")
                ) { select(.thermal) }
            }

            Divider()

            Button { select(.network) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(peerConfiguration.language.text("Network", "网络"), systemImage: MetricKind.network.symbol)
                            .font(.headline)
                        if store.snapshot.network.isStale {
                            NetworkFreshnessLabel()
                        }
                        Spacer()
                    }
                    HStack {
                        LabeledContent(
                            peerConfiguration.language.text("Upload", "上传"),
                            value: LocalizedDisplayValue.make(store.snapshot.network.overviewUploadText, language: peerConfiguration.language)
                        )
                        Spacer()
                        LabeledContent(
                            peerConfiguration.language.text("Download", "下载"),
                            value: LocalizedDisplayValue.make(store.snapshot.network.overviewDownloadText, language: peerConfiguration.language)
                        )
                    }
                    .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardRowButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(peerConfiguration.language.text("Network", "网络"))
            .accessibilityValue(store.snapshot.network.accessibilitySummary)
            .accessibilityHint(peerConfiguration.language.text("Show detailed network metrics", "显示网络详细指标"))

            Divider()

            PeerOverviewRow(
                configuration: peerConfiguration,
                store: peerStore,
                openDetail: { selectPeer(true) },
                openSettings: onOpenSettings
            )

            HStack {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(peerConfiguration.language.text("Settings", "设置"))
                .accessibilityHint(peerConfiguration.language.text("Open Device Monitor settings", "打开 Device Monitor 设置"))
                .help(peerConfiguration.language.text("Settings", "设置"))
                Spacer()
                Button(peerConfiguration.language.text("Quit", "退出"), action: onQuit)
                    .buttonStyle(.borderless)
                    .accessibilityHint(peerConfiguration.language.text("Quit Device Monitor", "退出 Device Monitor"))
            }
            .font(.subheadline)
        }
    }

    private func select(_ metric: MetricKind?) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            selectedMetric = metric
            isShowingPeerDetail = false
            selectedPeerMetric = nil
        }
        onPeerDetailDemand(false)
        onDetailDemand(metric)
    }

    private func selectPeer(_ show: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            selectedMetric = nil
            isShowingPeerDetail = show
            selectedPeerMetric = nil
        }
        onDetailDemand(nil)
        onPeerDetailDemand(show)
    }

    private func selectPeerMetric(_ metric: MetricKind?) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            selectedPeerMetric = metric
        }
        onDetailDemand(nil)
        onPeerDetailDemand(true)
    }
}

private struct OverviewMetricRow: View {
    let kind: MetricKind
    let value: String
    let state: MetricLevel
    let subtitle: String
    let action: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .frame(width: 16)
                    .foregroundStyle(state.swiftUIColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title(language: language))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    NumericMetricText(value: LocalizedDisplayValue.make(value, language: language))
                    StatusLabel(level: state)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title(language: language)), \(subtitle)")
        .accessibilityValue("\(value), \(state.label(language: language))")
        .accessibilityHint(language.text("Show detailed metrics", "显示详细指标"))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(level.swiftUIColor)
                .frame(width: 6, height: 6)
            Text(level.label(language: language))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("Status", "状态"))
        .accessibilityValue(level.label(language: language))
    }
}

struct MetricDetailView: View {
    let metric: MetricKind
    @ObservedObject var store: MonitorStore
    let onBack: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(language.text("Back", "返回"))
                .accessibilityHint(language.text("Return to the system overview", "返回系统总览"))
                .keyboardShortcut(.escape, modifiers: [])
                .help(language.text("Back", "返回"))
                Text(metric.title(language: language))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: language.text("Total utilization", "总使用率"), color: reading.level.swiftUIColor)
            TrendSection(
                title: language.text("Last 5 minutes", "最近 5 分钟"),
                points: trend,
                color: reading.level.swiftUIColor,
                range: 0...100,
                stats: [
                    StatItem(language.text("Average", "平均"), value: DisplayFormatter.percent(TrendMath.average(trend))),
                    StatItem(language.text("Peak", "峰值"), value: DisplayFormatter.percent(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: language.text("CPU breakdown", "CPU 构成")) {
                BreakdownRow(label: language.text("User", "用户"), value: DisplayFormatter.percent(reading.userPercent), color: .systemBlue)
                BreakdownRow(label: language.text("System", "系统"), value: DisplayFormatter.percent(reading.systemPercent), color: .systemOrange)
                BreakdownRow(label: language.text("Idle", "空闲"), value: DisplayFormatter.percent(reading.idlePercent), color: .tertiaryLabelColor)
            }
            SectionBand(title: language.text("Load average", "平均负载")) {
                StatGrid(items: [
                    StatItem(language.text("5 min", "5 分钟"), value: DisplayFormatter.decimal(reading.loadAverage5)),
                    StatItem(language.text("15 min", "15 分钟"), value: DisplayFormatter.decimal(reading.loadAverage15))
                ])
            }
            SectionBand(title: language.text("Hardware", "硬件")) {
                if reading.hasHybridCoreTopology {
                    StatGrid(items: [
                        StatItem(language.text("Performance cores", "性能核心"), value: "\(reading.performanceCoreCount)"),
                        StatItem(language.text("Efficiency cores", "能效核心"), value: "\(reading.efficiencyCoreCount)")
                    ])
                } else {
                    StatGrid(items: [
                        StatItem(language.text("Logical cores", "逻辑核心"), value: "\(reading.performanceCoreCount)")
                    ])
                }
            }
            ProcessSection(
                title: language.text("Top CPU processes", "CPU 占用最高的进程"),
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: language.text("Memory pressure: \(reading.level.label)", "内存压力：\(reading.level.label(language: language))"), color: reading.level.swiftUIColor)
            TrendSection(
                title: language.text("Memory used · last 5 minutes", "内存使用 · 最近 5 分钟"),
                points: trend,
                color: reading.level.swiftUIColor,
                range: 0...100,
                stats: [
                    StatItem(language.text("Average", "平均"), value: DisplayFormatter.percent(TrendMath.average(trend))),
                    StatItem(language.text("Peak", "峰值"), value: DisplayFormatter.percent(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: language.text("Memory breakdown", "内存构成")) {
                StatGrid(items: [
                    StatItem(language.text("Wired", "联动内存"), value: ByteFormatter.memory(reading.wiredBytes)),
                    StatItem(language.text("Compressed", "压缩内存"), value: ByteFormatter.memory(reading.compressedBytes)),
                    StatItem(language.text("Cached", "缓存"), value: ByteFormatter.memory(reading.cachedBytes)),
                    StatItem(language.text("Swap", "交换空间"), value: reading.swapText)
                ])
            }
            ProcessSection(
                title: language.text("Top memory processes", "内存占用最高的进程"),
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHero(value: reading.primaryText, caption: language.text("Average \(HardwareInfo.temperatureTitle)", "平均 SoC 温度"), color: reading.level.swiftUIColor)
            TrendSection(
                title: language.text("\(HardwareInfo.temperatureTitle) · last 5 minutes", "SoC 温度 · 最近 5 分钟"),
                points: trend,
                color: reading.level.swiftUIColor,
                range: 20...100,
                stats: [
                    StatItem(language.text("Minimum", "最低"), value: TemperatureFormatter.celsius(TrendMath.minimum(trend))),
                    StatItem(language.text("Average", "平均"), value: TemperatureFormatter.celsius(TrendMath.average(trend))),
                    StatItem(language.text("Maximum", "最高"), value: TemperatureFormatter.celsius(TrendMath.peak(trend)))
                ]
            )
            Divider()
            SectionBand(title: language.text("System state", "系统状态")) {
                StatGrid(items: [
                    StatItem(language.text("Thermal pressure", "热压力"), value: reading.state.rawValue),
                    StatItem(language.text(HardwareInfo.hottestSensorTitle, "最热 SoC 传感器"), value: reading.hottestSoCText),
                    StatItem(language.text("SSD temperature", "SSD 温度"), value: reading.ssdText)
                ])
            }
        }
    }
}

struct NetworkDetailContent: View {
    let reading: NetworkReading
    let uploadTrend: [TrendPoint]
    let downloadTrend: [TrendPoint]
    @Environment(\.appLanguage) private var language

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
                title: language.text("Upload · last 5 minutes", "上传 · 最近 5 分钟"),
                points: uploadTrend,
                color: Color(nsColor: .systemBlue),
                stats: networkStats(points: uploadTrend, sessionBytes: reading.sessionUploadBytes)
            )
            TrendSection(
                title: language.text("Download · last 5 minutes", "下载 · 最近 5 分钟"),
                points: downloadTrend,
                color: Color(nsColor: .systemTeal),
                stats: networkStats(points: downloadTrend, sessionBytes: reading.sessionDownloadBytes)
            )
            Divider()
            SectionBand(title: "Wi-Fi") {
                if let wifi = reading.wifi, wifi.isAvailable {
                    StatGrid(items: [
                        StatItem(language.text("Signal", "信号"), value: wifi.rssi.map { "\($0) dBm" } ?? language.text("Unavailable", "不可用")),
                        StatItem(language.text("Channel", "信道"), value: wifi.channel.map(String.init) ?? language.text("Unavailable", "不可用"))
                    ])
                } else {
                    UnavailableText(text: language.text("Wi-Fi details are unavailable or the current connection is not Wi-Fi.", "Wi-Fi 详情不可用，或当前连接不是 Wi-Fi。"))
                }
            }
        }
    }

    private func networkStats(points: [TrendPoint], sessionBytes: UInt64) -> [StatItem] {
        [
            StatItem(language.text("Average", "平均"), value: ByteFormatter.rate(TrendMath.average(points))),
            StatItem(language.text("Peak", "峰值"), value: ByteFormatter.rate(TrendMath.peak(points))),
            StatItem(language.text("5 min total", "5 分钟流量"), value: ByteFormatter.transfer(TrendMath.cumulativeBytes(points))),
            StatItem(language.text("Session total", "本次运行累计"), value: ByteFormatter.transfer(sessionBytes))
        ]
    }
}

private struct PeerOverviewRow: View {
    @ObservedObject var configuration: PeerConfiguration
    @ObservedObject var store: PeerStatusStore
    let openDetail: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Button(action: configuration.enabled ? openDetail : openSettings) {
            HStack(spacing: 10) {
                Image(systemName: store.remote?.device.platform == "windows" ? "desktopcomputer" : "laptopcomputer")
                    .frame(width: 16)
                    .foregroundStyle(Color(nsColor: store.state.color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.remote?.device.name ?? configuration.language.text("Other device", "另一台设备"))
                        .lineLimit(1)
                    Text(configuration.enabled ? summary : configuration.language.text("Peer monitoring is off", "设备互联未开启"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: store.state.color))
                            .frame(width: 6, height: 6)
                        Text(store.state.label(language: configuration.language))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Image(systemName: configuration.enabled ? "chevron.right" : "gearshape")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(configuration.language.text("Other device", "另一台设备"))
        .accessibilityValue(store.state.label(language: configuration.language))
    }

    private var summary: String {
        guard let remote = store.remote else {
            return configuration.language.text("Waiting for a valid status", "等待有效状态")
        }
        let cpu = DisplayFormatter.percent(remote.metrics.cpu.utilizationPct)
        let memory = DisplayFormatter.percent(remote.metrics.memory.usedPct)
        return configuration.language.text("CPU \(cpu) · Memory \(memory)", "CPU \(cpu) · 内存 \(memory)")
    }
}

private struct PeerDetailView: View {
    @ObservedObject var store: PeerStatusStore
    @ObservedObject var configuration: PeerConfiguration
    let selectedMetric: MetricKind?
    let onSelectMetric: (MetricKind?) -> Void
    let onBack: () -> Void

    var body: some View {
        Group {
            if let remote = store.remote, let selectedMetric {
                PeerMetricDetailView(
                    metric: selectedMetric,
                    remote: remote,
                    store: store,
                    configuration: configuration,
                    onBack: onBack
                )
            } else {
                overview
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(configuration.language.text("Back", "返回"))
                Text(store.remote?.device.name ?? configuration.language.text("Other device", "另一台设备"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(nsColor: store.state.color))
                        .frame(width: 6, height: 6)
                    Text(store.state.label(language: configuration.language))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let remote = store.remote {
                HStack {
                    Text(remote.device.platform == "windows" ? "Windows" : "macOS")
                    Text("·")
                    Text(configuration.language.text("App \(remote.device.appVersion)", "应用 \(remote.device.appVersion)"))
                    Spacer()
                    if let lastReceivedAt = store.lastReceivedAt {
                        Text(lastReceivedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    PeerOverviewMetricRow(
                        kind: .cpu,
                        title: "CPU",
                        value: DisplayFormatter.percent(remote.metrics.cpu.utilizationPct),
                        state: remote.metrics.cpu.state.metricLevel,
                        subtitle: configuration.language.text("Processor utilization", "处理器使用率")
                    ) { onSelectMetric(.cpu) }
                    Divider()
                    PeerOverviewMetricRow(
                        kind: .memory,
                        title: configuration.language.text("Memory", "内存"),
                        value: memorySummary(remote.metrics.memory),
                        state: remote.metrics.memory.state.metricLevel,
                        subtitle: configuration.language.text("Memory utilization", "内存使用率")
                    ) { onSelectMetric(.memory) }
                    Divider()
                    PeerOverviewMetricRow(
                        kind: .thermal,
                        title: temperatureTitle(for: remote),
                        value: TemperatureFormatter.celsius(remote.metrics.thermal.averageCelsius),
                        state: remote.metrics.thermal.state.metricLevel,
                        subtitle: temperatureSubtitle(for: remote)
                    ) { onSelectMetric(.thermal) }
                }

                Divider()

                Button { onSelectMetric(.network) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(configuration.language.text("Network", "网络"), systemImage: MetricKind.network.symbol)
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        HStack {
                            LabeledContent(
                                configuration.language.text("Upload", "上传"),
                                value: LocalizedDisplayValue.make(ByteFormatter.rate(remote.metrics.network.uploadBytesPerSecond), language: configuration.language)
                            )
                            Spacer()
                            LabeledContent(
                                configuration.language.text("Download", "下载"),
                                value: LocalizedDisplayValue.make(ByteFormatter.rate(remote.metrics.network.downloadBytesPerSecond), language: configuration.language)
                            )
                        }
                        .font(.subheadline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DashboardRowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(configuration.language.text("Network", "网络"))
                .accessibilityHint(configuration.language.text("Show detailed peer network metrics", "显示对端网络详细指标"))
            } else {
                UnavailableText(text: emptyStateText)
            }
        }
    }

    private var emptyStateText: String {
        switch store.state {
        case .waitingForAddress:
            return configuration.language.text("Add the peer address in Settings.", "请先在设置中填写对端地址。")
        case .incompatible:
            return configuration.language.text("The other device uses an incompatible protocol version.", "另一台设备使用了不兼容的协议版本。")
        default:
            return configuration.language.text("Waiting for the other device. Check its address, secret, and network.", "正在等待另一台设备，请检查地址、密钥和网络。")
        }
    }

    private func memorySummary(_ memory: PeerStatusPayload.Memory) -> String {
        guard let used = memory.usedBytes, let total = memory.totalBytes else {
            return DisplayFormatter.percent(memory.usedPct)
        }
        return "\(ByteFormatter.memory(used)) / \(ByteFormatter.memory(total))"
    }

    private func temperatureTitle(for remote: PeerStatusPayload) -> String {
        remote.device.platform == "windows"
            ? configuration.language.text("Temperatures", "温度")
            : configuration.language.text("SoC Temperature", "SoC 温度")
    }

    private func temperatureSubtitle(for remote: PeerStatusPayload) -> String {
        remote.device.platform == "windows"
            ? configuration.language.text("CPU, GPU and SSD sensors", "CPU、GPU 与 SSD 传感器")
            : configuration.language.text("Average SoC sensors", "平均 SoC 传感器温度")
    }
}

private struct PeerOverviewMetricRow: View {
    let kind: MetricKind
    let title: String
    let value: String
    let state: MetricLevel
    let subtitle: String
    let action: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .frame(width: 16)
                    .foregroundStyle(state.swiftUIColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    NumericMetricText(value: LocalizedDisplayValue.make(value, language: language))
                    HStack(spacing: 7) {
                        StatusLabel(level: state)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue("\(value), \(state.label(language: language))")
        .accessibilityHint(language.text("Show detailed peer metrics", "显示对端详细指标"))
    }
}

private struct PeerMetricDetailView: View {
    let metric: MetricKind
    let remote: PeerStatusPayload
    @ObservedObject var store: PeerStatusStore
    @ObservedObject var configuration: PeerConfiguration
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(configuration.language.text("Back", "返回"))
                    .accessibilityHint(configuration.language.text("Return to the peer overview", "返回对端设备总览"))
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusLabel(level: level)
            }

            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch metric {
        case .cpu:
            peerCPUContent
        case .memory:
            peerMemoryContent
        case .thermal:
            peerThermalContent
        case .network:
            peerNetworkContent
        }
    }

    private var peerCPUContent: some View {
        let reading = remote.metrics.cpu
        return VStack(alignment: .leading, spacing: 12) {
            DetailHero(
                value: DisplayFormatter.percent(reading.utilizationPct),
                caption: configuration.language.text("Total utilization", "总使用率"),
                color: reading.state.metricLevel.swiftUIColor
            )
            TrendSection(
                title: configuration.language.text("Last 5 minutes", "最近 5 分钟"),
                points: store.cpuTrend,
                color: reading.state.metricLevel.swiftUIColor,
                range: 0...100,
                stats: percentStats(store.cpuTrend)
            )
            Divider()
            SectionBand(title: configuration.language.text("CPU breakdown", "CPU 构成")) {
                StatGrid(items: [
                    StatItem(configuration.language.text("User", "用户"), value: DisplayFormatter.percent(reading.userPct)),
                    StatItem(configuration.language.text("System", "系统"), value: DisplayFormatter.percent(reading.systemPct)),
                    StatItem(configuration.language.text("Idle", "空闲"), value: DisplayFormatter.percent(reading.idlePct))
                ])
            }
            SectionBand(title: configuration.language.text("Load average", "平均负载")) {
                StatGrid(items: [
                    StatItem(configuration.language.text("1 min", "1 分钟"), value: DisplayFormatter.decimal(reading.loadAverage1)),
                    StatItem(configuration.language.text("5 min", "5 分钟"), value: DisplayFormatter.decimal(reading.loadAverage5)),
                    StatItem(configuration.language.text("15 min", "15 分钟"), value: DisplayFormatter.decimal(reading.loadAverage15))
                ])
            }
            SectionBand(title: configuration.language.text("Hardware", "硬件")) {
                StatGrid(items: [
                    StatItem(configuration.language.text("Performance / logical cores", "性能／逻辑核心"), value: "\(reading.performanceCores)"),
                    StatItem(configuration.language.text("Efficiency cores", "能效核心"), value: "\(reading.efficiencyCores)")
                ])
            }
        }
    }

    private var peerMemoryContent: some View {
        let reading = remote.metrics.memory
        return VStack(alignment: .leading, spacing: 12) {
            DetailHero(
                value: DisplayFormatter.percent(reading.usedPct),
                caption: configuration.language.text("Memory used", "内存使用率"),
                color: reading.state.metricLevel.swiftUIColor
            )
            TrendSection(
                title: configuration.language.text("Memory used · last 5 minutes", "内存使用 · 最近 5 分钟"),
                points: store.memoryTrend,
                color: reading.state.metricLevel.swiftUIColor,
                range: 0...100,
                stats: percentStats(store.memoryTrend)
            )
            Divider()
            SectionBand(title: configuration.language.text("Memory breakdown", "内存构成")) {
                StatGrid(items: [
                    StatItem(configuration.language.text("Used", "已使用"), value: ByteFormatter.memory(reading.usedBytes)),
                    StatItem(configuration.language.text("Total", "总计"), value: ByteFormatter.memory(reading.totalBytes)),
                    StatItem(configuration.language.text("Wired", "联动内存"), value: ByteFormatter.memory(reading.wiredBytes)),
                    StatItem(configuration.language.text("Compressed", "压缩内存"), value: ByteFormatter.memory(reading.compressedBytes)),
                    StatItem(configuration.language.text("Cached", "缓存"), value: ByteFormatter.memory(reading.cachedBytes)),
                    StatItem(configuration.language.text("Swap used", "已用交换空间"), value: ByteFormatter.memory(reading.swapUsedBytes))
                ])
            }
        }
    }

    private var peerThermalContent: some View {
        let reading = remote.metrics.thermal
        return VStack(alignment: .leading, spacing: 12) {
            DetailHero(
                value: TemperatureFormatter.celsius(reading.averageCelsius),
                caption: remote.device.platform == "windows"
                    ? configuration.language.text("Average CPU temperature", "CPU 平均温度")
                    : configuration.language.text("Average SoC temperature", "平均 SoC 温度"),
                color: reading.state.metricLevel.swiftUIColor
            )
            if !store.thermalTrend.isEmpty {
                TrendSection(
                    title: remote.device.platform == "windows"
                        ? configuration.language.text("CPU temperature · last 5 minutes", "CPU 温度 · 最近 5 分钟")
                        : configuration.language.text("SoC temperature · last 5 minutes", "SoC 温度 · 最近 5 分钟"),
                    points: store.thermalTrend,
                    color: reading.state.metricLevel.swiftUIColor,
                    range: 20...110,
                    stats: temperatureStats(store.thermalTrend)
                )
            }
            if !store.gpuTrend.isEmpty {
                TrendSection(
                    title: configuration.language.text("GPU temperature · last 5 minutes", "GPU 温度 · 最近 5 分钟"),
                    points: store.gpuTrend,
                    color: .purple,
                    range: 20...110,
                    stats: temperatureStats(store.gpuTrend)
                )
            }
            if !store.storageTrend.isEmpty {
                TrendSection(
                    title: configuration.language.text("SSD temperature · last 5 minutes", "SSD 温度 · 最近 5 分钟"),
                    points: store.storageTrend,
                    color: .orange,
                    range: 20...110,
                    stats: temperatureStats(store.storageTrend)
                )
            }
            Divider()
            SectionBand(title: configuration.language.text("Current sensors", "当前传感器")) {
                StatGrid(items: [
                    StatItem(remote.device.platform == "windows" ? "CPU" : "SoC", value: TemperatureFormatter.celsius(reading.averageCelsius)),
                    StatItem(configuration.language.text("Hottest", "最高"), value: TemperatureFormatter.celsius(reading.hottestCelsius)),
                    StatItem("GPU", value: TemperatureFormatter.celsius(reading.gpuCelsius)),
                    StatItem("SSD", value: TemperatureFormatter.celsius(reading.effectiveStorageCelsius))
                ])
            }
        }
    }

    private var peerNetworkContent: some View {
        let reading = remote.metrics.network
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                DirectionHero(symbol: "arrow.up", value: ByteFormatter.rate(reading.uploadBytesPerSecond), color: .systemBlue)
                DirectionHero(symbol: "arrow.down", value: ByteFormatter.rate(reading.downloadBytesPerSecond), color: .systemTeal)
            }
            TrendSection(
                title: configuration.language.text("Upload · last 5 minutes", "上传 · 最近 5 分钟"),
                points: store.uploadTrend,
                color: Color(nsColor: .systemBlue),
                stats: networkStats(store.uploadTrend, sessionBytes: reading.sessionUploadBytes)
            )
            TrendSection(
                title: configuration.language.text("Download · last 5 minutes", "下载 · 最近 5 分钟"),
                points: store.downloadTrend,
                color: Color(nsColor: .systemTeal),
                stats: networkStats(store.downloadTrend, sessionBytes: reading.sessionDownloadBytes)
            )
        }
    }

    private var title: String {
        switch metric {
        case .cpu: return "CPU"
        case .memory: return configuration.language.text("Memory", "内存")
        case .thermal:
            return remote.device.platform == "windows"
                ? configuration.language.text("Temperatures", "温度")
                : configuration.language.text("SoC Temperature", "SoC 温度")
        case .network: return configuration.language.text("Network", "网络")
        }
    }

    private var level: MetricLevel {
        switch metric {
        case .cpu: return remote.metrics.cpu.state.metricLevel
        case .memory: return remote.metrics.memory.state.metricLevel
        case .thermal: return remote.metrics.thermal.state.metricLevel
        case .network: return remote.metrics.network.state.metricLevel
        }
    }

    private func percentStats(_ points: [TrendPoint]) -> [StatItem] {
        [
            StatItem(configuration.language.text("Average", "平均"), value: DisplayFormatter.percent(TrendMath.average(points))),
            StatItem(configuration.language.text("Peak", "峰值"), value: DisplayFormatter.percent(TrendMath.peak(points)))
        ]
    }

    private func temperatureStats(_ points: [TrendPoint]) -> [StatItem] {
        [
            StatItem(configuration.language.text("Minimum", "最低"), value: TemperatureFormatter.celsius(TrendMath.minimum(points))),
            StatItem(configuration.language.text("Average", "平均"), value: TemperatureFormatter.celsius(TrendMath.average(points))),
            StatItem(configuration.language.text("Maximum", "最高"), value: TemperatureFormatter.celsius(TrendMath.peak(points)))
        ]
    }

    private func networkStats(_ points: [TrendPoint], sessionBytes: UInt64) -> [StatItem] {
        [
            StatItem(configuration.language.text("Average", "平均"), value: ByteFormatter.rate(TrendMath.average(points))),
            StatItem(configuration.language.text("Peak", "峰值"), value: ByteFormatter.rate(TrendMath.peak(points))),
            StatItem(configuration.language.text("5 min total", "5 分钟流量"), value: ByteFormatter.transfer(TrendMath.cumulativeBytes(points))),
            StatItem(configuration.language.text("Session total", "本次运行累计"), value: ByteFormatter.transfer(sessionBytes))
        ]
    }
}

struct DetailHero: View {
    let value: String
    let caption: String
    let color: Color
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            NumericMetricText(
                value: LocalizedDisplayValue.make(value, language: language),
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: color))
            NumericMetricText(
                value: LocalizedDisplayValue.make(value, language: language),
                font: .system(size: 20, weight: .semibold, design: .rounded),
                color: Color(nsColor: color)
            )
                .accessibilityLabel(symbol == "arrow.up" ? language.text("Upload", "上传") : language.text("Download", "下载"))
                .accessibilityValue(secondaryValue.map { language.text("\(value), last known \($0)", "\(value)，最后有效值 \($0)") } ?? value)
            if let secondaryValue {
                Text(language.text("Last known \(secondaryValue)", "最后有效值 \(secondaryValue)"))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        Label(language.text("Out of date", "已过期"), systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(language.text("Network status", "网络状态"))
            .accessibilityValue(language.text("Out of date", "已过期"))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(LocalizedDisplayValue.make(item.value, language: language))
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.label)
                .accessibilityValue(LocalizedDisplayValue.make(item.value, language: language))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        SectionBand(title: title) {
            if processes.isEmpty, sampledAt == nil {
                UnavailableText(text: language.text("Collecting process data", "正在采集进程数据"))
            } else if processes.isEmpty {
                UnavailableText(text: language.text("Process data unavailable", "进程数据不可用"))
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
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.body.weight(.semibold))
            Sparkline(points: points, color: color, range: range)
                .frame(height: 60)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(points.isEmpty ? language.text("Collecting data", "正在采集数据") : language.text("\(points.count) samples", "\(points.count) 个样本"))
            if !stats.isEmpty {
                StatGrid(items: stats)
            }
            if points.count < 2 {
                Text(language.text("Collecting data", "正在采集数据"))
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
    init(
        settings: AppSettings,
        peerConfiguration: PeerConfiguration,
        peerStatusStore: PeerStatusStore,
        onResetNetworkTotals: @escaping () -> Void,
        onTestPeer: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        let controller = NSHostingController(rootView: SettingsView(
            settings: settings,
            peerConfiguration: peerConfiguration,
            peerStatusStore: peerStatusStore,
            onResetNetworkTotals: onResetNetworkTotals,
            onTestPeer: onTestPeer,
            onBack: onBack
        ))
        let window = NSWindow(contentViewController: controller)
        window.title = "Device Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 650))
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
    @ObservedObject var peerConfiguration: PeerConfiguration
    @ObservedObject var peerStatusStore: PeerStatusStore
    let onResetNetworkTotals: () -> Void
    let onTestPeer: () -> Void
    let onBack: () -> Void
    @State private var secretDraft = ""
    @State private var showsRegenerateConfirmation = false

    private var language: AppLanguage { peerConfiguration.language }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(language.text("Back", "返回"))
                .accessibilityHint(language.text("Return to the monitor overview", "返回监控总览"))
                .keyboardShortcut(.escape, modifiers: [])
                .help(language.text("Back", "返回"))
                Text(language.text("Settings", "设置"))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Form {
                Picker(language.text("Language", "语言"), selection: $peerConfiguration.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker(language.text("Menu bar", "菜单栏"), selection: $settings.displayMode) {
                    ForEach(MenuDisplayMode.allCases) { mode in
                        Text(mode.title(language: language)).tag(mode)
                    }
                }
                Text(settings.displayMode.detail(language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(language.text("Show network speed", "显示网络速度"), isOn: $settings.showNetwork)
                Picker(language.text("Sampling profile", "采样档位"), selection: $settings.samplingProfile) {
                    ForEach(SamplingProfile.allCases) { profile in
                        Text(profile.title(language: language)).tag(profile)
                    }
                }
                Text(settings.samplingProfile.detail(language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Section(language.text("Temperature data", "温度数据")) {
                    LabeledContent(language.text("Temperature source", "温度来源"), value: HardwareInfo.temperatureSource)
                    LabeledContent(language.text("Thermal pressure", "热压力"), value: language.text("macOS system state", "macOS 系统状态"))
                    Text(language.text("Unavailable values are not estimated.", "无法读取的数值不会被估算。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(language.text("Sampling", "采样")) {
                    LabeledContent(language.text("Current profile", "当前档位"), value: settings.samplingProfile.title(language: language))
                    LabeledContent(language.text("Process data", "进程数据"), value: language.text("Only while CPU/Memory details are open", "仅在 CPU/内存详情打开时"))
                    LabeledContent(language.text("Wi-Fi data", "Wi-Fi 数据"), value: language.text("Only while Network details are open", "仅在网络详情打开时"))
                }
                Section(language.text("Devices", "设备互联")) {
                    Toggle(language.text("Enable peer monitoring", "启用设备互联"), isOn: $peerConfiguration.enabled)
                    TextField(language.text("This device name", "本机名称"), text: $peerConfiguration.deviceName)
                    LabeledContent("Device ID", value: peerConfiguration.deviceID)
                        .textSelection(.enabled)
                    LabeledContent(language.text("Listen port", "监听端口"), value: "48621/TCP")
                    TextField(language.text("Peer address (host:port)", "对端地址（主机:端口）"), text: $peerConfiguration.peerAddress)
                        .textContentType(.URL)
                    SecureField(language.text("Pairing secret", "配对密钥"), text: $secretDraft)
                        .textContentType(.password)
                    HStack {
                        Button(language.text("Apply secret", "应用密钥")) {
                            _ = peerConfiguration.setPairingSecret(secretDraft)
                        }
                        Button(language.text("Copy", "复制"), action: peerConfiguration.copySecret)
                        Button(language.text("Regenerate", "重新生成")) {
                            showsRegenerateConfirmation = true
                        }
                        Spacer()
                        Button(language.text("Test connection", "测试连接"), action: onTestPeer)
                    }
                    if let error = peerConfiguration.secretError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let serverError = peerStatusStore.localServerError {
                        Text(language.text("Listener error: \(serverError)", "监听错误：\(serverError)"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    LabeledContent(
                        language.text("Peer status", "对端状态"),
                        value: peerStatusStore.state.label(language: language)
                    )
                    Button(language.text("Forget peer", "忘记对端"), role: .destructive) {
                        peerConfiguration.forgetPeer()
                    }
                    Text(language.text(
                        "Use only on a trusted LAN or through an encrypted Tailscale/WireGuard network. Never forward port 48621 directly to the public internet.",
                        "仅用于可信局域网或 Tailscale/WireGuard 加密组网。不要把 48621 端口直接映射到公网。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section(language.text("Session data", "本次运行数据")) {
                    Button(language.text("Reset network session totals", "重置网络累计流量"), action: onResetNetworkTotals)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { secretDraft = peerConfiguration.pairingSecret }
        .onChange(of: peerConfiguration.pairingSecret) { _, value in secretDraft = value }
        .alert(
            language.text("Regenerate pairing secret?", "重新生成配对密钥？"),
            isPresented: $showsRegenerateConfirmation
        ) {
            Button(language.text("Cancel", "取消"), role: .cancel) {}
            Button(language.text("Regenerate", "重新生成"), role: .destructive) {
                peerConfiguration.regenerateSecret()
                secretDraft = peerConfiguration.pairingSecret
            }
        } message: {
            Text(language.text(
                "The other device will stop connecting until it is given the new secret.",
                "另一台设备在更新为新密钥之前将无法连接。"
            ))
        }
        .background(VisualEffectBackground(material: .windowBackground))
        .frame(width: 520, height: 650)
    }
}
