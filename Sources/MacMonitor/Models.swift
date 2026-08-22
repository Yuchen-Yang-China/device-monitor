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

    var uploadShortText: String { ByteFormatter.rateShort(uploadBytesPerSecond) }
    var downloadShortText: String { ByteFormatter.rateShort(downloadBytesPerSecond) }
    var uploadText: String { ByteFormatter.rate(uploadBytesPerSecond) }
    var downloadText: String { ByteFormatter.rate(downloadBytesPerSecond) }
}

struct SystemSnapshot {
    var capturedAt: Date
    var cpu: CPUReading
    var memory: MemoryReading
    var thermal: ThermalReading
    var network: NetworkReading

    static let initial = SystemSnapshot(
        capturedAt: .now,
        cpu: CPUReading(utilization: nil, level: .sampling, capturedAt: nil),
        memory: MemoryReading(usedBytes: nil, totalBytes: ProcessInfo.processInfo.physicalMemory, level: .sampling, capturedAt: nil),
        thermal: ThermalReading(state: .unavailable, socCelsius: nil, hottestSoCCelsius: nil, ssdCelsius: nil, capturedAt: nil),
        network: NetworkReading(uploadBytesPerSecond: nil, downloadBytesPerSecond: nil)
    )
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
    #else
    static let temperatureTitle = "CPU Temperature"
    static let hottestSensorTitle = "Hottest CPU sensor"
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

    private enum Keys {
        static let displayMode = "menuDisplayMode"
        static let showNetwork = "showNetwork"
    }

    init() {
        let savedMode = UserDefaults.standard.string(forKey: Keys.displayMode)
        displayMode = MenuDisplayMode(rawValue: savedMode ?? "") ?? .full
        showNetwork = UserDefaults.standard.object(forKey: Keys.showNetwork) as? Bool ?? true
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

    static func rateShort(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "--" }
        if bytesPerSecond < 1_000 { return "0" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.1fK", bytesPerSecond / 1_000) }
        if bytesPerSecond < 1_000_000_000 { return String(format: "%.1fM", bytesPerSecond / 1_000_000) }
        return String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "Unavailable" }
        return "\(rateShort(bytesPerSecond))B/s"
    }
}

enum TemperatureFormatter {
    static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded())) C"
    }
}
