import AppKit
import Combine
import Foundation
import SwiftUI

enum MetricLevel: Int, Comparable, CaseIterable {
    case normal
    case elevated
    case critical
    case sampling
    case unavailable
    case stale

    static func < (lhs: MetricLevel, rhs: MetricLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Attention"
        case .critical: return "Critical"
        case .sampling: return "Collecting"
        case .unavailable: return "Unavailable"
        case .stale: return "Out of date"
        }
    }

    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        case .sampling, .unavailable, .stale: return .tertiaryLabelColor
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: color)
    }

    var barFill: Int {
        switch self {
        case .normal: return 1
        case .elevated: return 2
        case .critical: return 3
        case .sampling, .unavailable, .stale: return 0
        }
    }
}

enum ThermalState: String {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
    case unavailable = "Unavailable"

    var level: MetricLevel {
        switch self {
        case .nominal: return .normal
        case .fair: return .elevated
        case .serious, .critical: return .critical
        case .unavailable: return .unavailable
        }
    }
}

struct CPUReading {
    var utilization: Double?
    var userPercent: Double?
    var systemPercent: Double?
    var idlePercent: Double?
    var loadAverage1: Double?
    var loadAverage5: Double?
    var loadAverage15: Double?
    var performanceCoreCount: Int
    var efficiencyCoreCount: Int
    var hasHybridCoreTopology: Bool
    var level: MetricLevel
    var capturedAt: Date?

    var primaryText: String {
        guard let utilization else { return "--" }
        return "\(Int(utilization.rounded()))%"
    }
}

struct MemoryReading {
    var usedBytes: UInt64?
    var totalBytes: UInt64
    var wiredBytes: UInt64?
    var compressedBytes: UInt64?
    var cachedBytes: UInt64?
    var swapUsedBytes: UInt64?
    var swapTotalBytes: UInt64?
    var level: MetricLevel
    var capturedAt: Date?

    var primaryText: String {
        guard let usedBytes else { return "--" }
        return "\(ByteFormatter.memory(usedBytes)) / \(ByteFormatter.memory(totalBytes))"
    }

    var usedRatio: Double? {
        guard let usedBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    var swapText: String {
        guard let swapUsedBytes, let swapTotalBytes else { return "Unavailable" }
        if swapUsedBytes == 0, swapTotalBytes == 0 {
            return "No swap used"
        }
        return "\(ByteFormatter.memory(swapUsedBytes)) / \(ByteFormatter.memory(swapTotalBytes))"
    }
}

struct ThermalReading {
    var state: ThermalState
    var socCelsius: Double?
    var hottestSoCCelsius: Double?
    var ssdCelsius: Double?
    var capturedAt: Date?

    var primaryText: String {
        guard let socCelsius else { return "Unavailable" }
        return TemperatureFormatter.celsius(socCelsius)
    }

    var hottestSoCText: String {
        guard let hottestSoCCelsius else { return "Unavailable" }
        return TemperatureFormatter.celsius(hottestSoCCelsius)
    }

    var ssdText: String {
        guard let ssdCelsius else { return "Unavailable" }
        return TemperatureFormatter.celsius(ssdCelsius)
    }

    var level: MetricLevel {
        guard let socCelsius else { return .unavailable }

        let temperatureLevel: MetricLevel
        if socCelsius >= 90 {
            temperatureLevel = .critical
        } else if socCelsius >= 75 {
            temperatureLevel = .elevated
        } else {
            temperatureLevel = .normal
        }

        if state.level == .critical || temperatureLevel == .critical { return .critical }
        if state.level == .elevated || temperatureLevel == .elevated { return .elevated }
        return .normal
    }
}

struct NetworkReading {
    var uploadBytesPerSecond: Double?
    var downloadBytesPerSecond: Double?
    var sessionUploadBytes: UInt64
    var sessionDownloadBytes: UInt64
    var wifi: WiFiReading?

    var uploadShortText: String { ByteFormatter.rateShort(uploadBytesPerSecond) }
    var downloadShortText: String { ByteFormatter.rateShort(downloadBytesPerSecond) }
    var uploadText: String { ByteFormatter.rate(uploadBytesPerSecond) }
    var downloadText: String { ByteFormatter.rate(downloadBytesPerSecond) }
}

struct WiFiReading: Equatable {
    var ssid: String?
    var rssi: Int?
    var channel: Int?
    var capturedAt: Date?

    var isAvailable: Bool { ssid != nil || rssi != nil || channel != nil }
}

struct ProcessUsage: Identifiable, Equatable {
    let id: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64

    var cpuText: String { String(format: "%.1f%%", cpuPercent) }
    var memoryText: String { ByteFormatter.memory(memoryBytes) }
}

struct SystemSnapshot {
    var capturedAt: Date
    var cpu: CPUReading
    var memory: MemoryReading
    var thermal: ThermalReading
    var network: NetworkReading

    static let initial = SystemSnapshot(
        capturedAt: .now,
        cpu: CPUReading(
            utilization: nil,
            userPercent: nil,
            systemPercent: nil,
            idlePercent: nil,
            loadAverage1: nil,
            loadAverage5: nil,
            loadAverage15: nil,
            performanceCoreCount: 0,
            efficiencyCoreCount: 0,
            hasHybridCoreTopology: false,
            level: .sampling,
            capturedAt: nil
        ),
        memory: MemoryReading(
            usedBytes: nil,
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            wiredBytes: nil,
            compressedBytes: nil,
            cachedBytes: nil,
            swapUsedBytes: nil,
            swapTotalBytes: nil,
            level: .sampling,
            capturedAt: nil
        ),
        thermal: ThermalReading(
            state: .unavailable,
            socCelsius: nil,
            hottestSoCCelsius: nil,
            ssdCelsius: nil,
            capturedAt: nil
        ),
        network: NetworkReading(
            uploadBytesPerSecond: nil,
            downloadBytesPerSecond: nil,
            sessionUploadBytes: 0,
            sessionDownloadBytes: 0,
            wifi: nil
        ),
        topCPUProcesses: [],
        topMemoryProcesses: [],
        processSampledAt: nil
    )

    var topCPUProcesses: [ProcessUsage]
    var topMemoryProcesses: [ProcessUsage]
    var processSampledAt: Date?
}

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

enum MetricKind: String, Identifiable, CaseIterable {
    case cpu
    case memory
    case thermal
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .thermal: return HardwareInfo.temperatureTitle
        case .network: return "Network"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .thermal: return "thermometer.medium"
        case .network: return "arrow.up.arrow.down"
        }
    }

}

enum HardwareInfo {
#if arch(arm64)
    static let temperatureTitle = "SoC Temperature"
    static let hottestSensorTitle = "Hottest SoC sensor"
    static let temperatureSource = "Apple Silicon PMU die sensors"
#else
    static let temperatureTitle = "CPU Temperature"
    static let hottestSensorTitle = "Hottest CPU sensor"
    static let temperatureSource = "Available CPU sensors"
#endif
}

enum MenuDisplayMode: String, CaseIterable, Identifiable {
    case full
    case compact
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .minimal: return "Minimal"
        }
    }

    var detail: String {
        switch self {
        case .full: return "Wider status item with spaced network rates"
        case .compact: return "Tighter status item with right-shifted rates"
        case .minimal: return "Pressure bars only"
        }
    }
}

enum SamplingProfile: String, CaseIterable, Identifiable {
    case balanced
    case lowPower
    case responsive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .lowPower: return "Low power"
        case .responsive: return "Responsive"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "Network 1s · system 5s · temperature 15s"
        case .lowPower: return "Network 2s · system 10s · temperature 30s"
        case .responsive: return "Network 1s · system 2s · temperature 10s"
        }
    }

    var networkInterval: TimeInterval {
        switch self {
        case .balanced, .responsive: return 1
        case .lowPower: return 2
        }
    }

    var systemInterval: TimeInterval {
        switch self {
        case .balanced: return 5
        case .lowPower: return 10
        case .responsive: return 2
        }
    }

    var thermalInterval: TimeInterval {
        switch self {
        case .balanced: return 15
        case .lowPower: return 30
        case .responsive: return 10
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.initial
    @Published private(set) var cpuTrend: [TrendPoint] = []
    @Published private(set) var memoryTrend: [TrendPoint] = []
    @Published private(set) var thermalTrend: [TrendPoint] = []
    @Published private(set) var uploadTrend: [TrendPoint] = []
    @Published private(set) var downloadTrend: [TrendPoint] = []

    private let historyDuration: TimeInterval = 5 * 60
    private var lastCPUTrendSample: Date?
    private var lastMemoryTrendSample: Date?
    private var lastThermalTrendSample: Date?

    func apply(_ newSnapshot: SystemSnapshot) {
        snapshot = newSnapshot
        let date = newSnapshot.capturedAt

        if let value = newSnapshot.cpu.utilization, newSnapshot.cpu.capturedAt != lastCPUTrendSample {
            append(TrendPoint(date: date, value: value), to: &cpuTrend)
            lastCPUTrendSample = newSnapshot.cpu.capturedAt
        }
        if let value = newSnapshot.memory.usedRatio, newSnapshot.memory.capturedAt != lastMemoryTrendSample {
            append(TrendPoint(date: date, value: value * 100), to: &memoryTrend)
            lastMemoryTrendSample = newSnapshot.memory.capturedAt
        }
        if let value = newSnapshot.thermal.socCelsius, newSnapshot.thermal.capturedAt != lastThermalTrendSample {
            append(TrendPoint(date: date, value: value), to: &thermalTrend)
            lastThermalTrendSample = newSnapshot.thermal.capturedAt
        }
        if let value = newSnapshot.network.uploadBytesPerSecond {
            append(TrendPoint(date: date, value: value), to: &uploadTrend)
        }
        if let value = newSnapshot.network.downloadBytesPerSecond {
            append(TrendPoint(date: date, value: value), to: &downloadTrend)
        }
    }

    private func append(_ point: TrendPoint, to trend: inout [TrendPoint]) {
        trend.append(point)
        let cutoff = point.date.addingTimeInterval(-historyDuration)
        trend.removeAll { $0.date < cutoff }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var displayMode: MenuDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }

    @Published var showNetwork: Bool {
        didSet { UserDefaults.standard.set(showNetwork, forKey: Keys.showNetwork) }
    }

    @Published var samplingProfile: SamplingProfile {
        didSet { UserDefaults.standard.set(samplingProfile.rawValue, forKey: Keys.samplingProfile) }
    }

    private enum Keys {
        static let displayMode = "menuDisplayMode"
        static let showNetwork = "showNetwork"
        static let samplingProfile = "samplingProfile"
    }

    init() {
        let savedMode = UserDefaults.standard.string(forKey: Keys.displayMode)
        displayMode = MenuDisplayMode(rawValue: savedMode ?? "") ?? .full
        showNetwork = UserDefaults.standard.object(forKey: Keys.showNetwork) as? Bool ?? true
        let savedProfile = UserDefaults.standard.string(forKey: Keys.samplingProfile)
        samplingProfile = SamplingProfile(rawValue: savedProfile ?? "") ?? .balanced
    }
}

enum ByteFormatter {
    static func memory(_ bytes: UInt64) -> String {
        let formatter = Foundation.ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unavailable" }
        return memory(bytes)
    }

    static func transfer(_ bytes: UInt64) -> String {
        let formatter = Foundation.ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func rateShort(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "--" }
        if bytesPerSecond < 1_000 { return "0" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.1fK", bytesPerSecond / 1_000) }
        if bytesPerSecond < 1_000_000_000 { return String(format: "%.1fM", bytesPerSecond / 1_000_000) }
        return String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
    }

    static func rateCompact(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "--" }
        if bytesPerSecond < 1_000 { return "0" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.0fK", bytesPerSecond / 1_000) }
        if bytesPerSecond < 1_000_000_000 { return String(format: "%.0fM", bytesPerSecond / 1_000_000) }
        return String(format: "%.0fG", bytesPerSecond / 1_000_000_000)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "Unavailable" }
        return "\(rateShort(bytesPerSecond))B/s"
    }
}

enum TrendMath {
    static func values(_ points: [TrendPoint]) -> [Double] {
        points.map(\.value)
    }

    static func average(_ points: [TrendPoint]) -> Double? {
        let values = values(points)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func peak(_ points: [TrendPoint]) -> Double? {
        values(points).max()
    }

    static func minimum(_ points: [TrendPoint]) -> Double? {
        values(points).min()
    }

    static func cumulativeBytes(_ points: [TrendPoint], now: Date = .now) -> UInt64 {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        for index in 0..<(points.count - 1) {
            let duration = max(0, min(10, points[index + 1].date.timeIntervalSince(points[index].date)))
            total += max(0, points[index].value) * duration
        }
        if let last = points.last {
            total += max(0, last.value) * max(0, min(2, now.timeIntervalSince(last.date)))
        }
        return UInt64(max(0, total).rounded())
    }
}

enum TemperatureFormatter {
    static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded()))\u{00B0}C"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return celsius(value)
    }
}

enum DisplayFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.0f%%", value)
    }

    static func decimal(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.2f", value)
    }
}
