import AppKit
import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System / 跟随系统"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var usesChinese: Bool {
        switch self {
        case .english: return false
        case .simplifiedChinese: return true
        case .system: return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
        }
    }

    func text(_ english: String, _ chinese: String) -> String { usesChinese ? chinese : english }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

enum LocalizedDisplayValue {
    static func make(_ value: String, language: AppLanguage) -> String {
        guard language.usesChinese else { return value }
        switch value {
        case "Unavailable": return "不可用"
        case "No swap used": return "未使用交换空间"
        case "Nominal": return "正常"
        case "Fair": return "轻微"
        case "Serious": return "严重"
        case "Critical": return "危急"
        default:
            if value.hasPrefix("Out of date · ") {
                return value.replacingOccurrences(of: "Out of date · ", with: "已过期 · ")
            }
            if value.hasPrefix("Last ") {
                return value.replacingOccurrences(of: "Last ", with: "最后有效值 ")
            }
            return value
        }
    }
}

@MainActor
final class PeerConfiguration: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var peerAddress: String {
        didSet { defaults.set(peerAddress, forKey: Keys.peerAddress) }
    }
    @Published var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published private(set) var pairingSecret: String
    @Published private(set) var secretError: String?

    let deviceID: String
    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "peer.enabled"
        static let peerAddress = "peer.address"
        static let deviceName = "peer.deviceName"
        static let deviceID = "peer.deviceID"
        static let language = "app.language"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Keys.enabled)
        peerAddress = defaults.string(forKey: Keys.peerAddress) ?? ""
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "Mac"
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system

        if let savedID = defaults.string(forKey: Keys.deviceID), UUID(uuidString: savedID) != nil {
            deviceID = savedID.lowercased()
        } else {
            let generated = UUID().uuidString.lowercased()
            deviceID = generated
            defaults.set(generated, forKey: Keys.deviceID)
        }

        if let savedSecret = PeerSecretStore.load(), (try? PeerSecurity.decodeSecret(savedSecret)) != nil {
            pairingSecret = savedSecret
            secretError = nil
        } else {
            do {
                let generated = try PeerSecurity.generateSecret().base64URLEncodedString
                try PeerSecretStore.save(generated)
                pairingSecret = generated
                secretError = nil
            } catch {
                pairingSecret = ""
                secretError = "Unable to save the pairing secret in Keychain."
            }
        }
    }

    @discardableResult
    func setPairingSecret(_ value: String) -> Bool {
        do {
            _ = try PeerSecurity.decodeSecret(value)
            try PeerSecretStore.save(value)
            pairingSecret = value
            secretError = nil
            return true
        } catch {
            secretError = "Pairing secret must be a 32-byte Base64URL value."
            return false
        }
    }

    func regenerateSecret() {
        do {
            let generated = try PeerSecurity.generateSecret().base64URLEncodedString
            try PeerSecretStore.save(generated)
            pairingSecret = generated
            secretError = nil
        } catch {
            secretError = "Unable to save the pairing secret in Keychain."
        }
    }

    func copySecret() {
        guard !pairingSecret.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingSecret, forType: .string)
    }

    func forgetPeer() {
        peerAddress = ""
        enabled = false
    }
}

enum PeerConnectionState: Equatable {
    case disabled
    case waitingForAddress
    case connecting
    case online
    case degraded
    case offline
    case incompatible

    func label(language: AppLanguage) -> String {
        switch self {
        case .disabled: return language.text("Disabled", "未启用")
        case .waitingForAddress: return language.text("Needs peer address", "需要对端地址")
        case .connecting: return language.text("Connecting", "正在连接")
        case .online: return language.text("Online", "在线")
        case .degraded: return language.text("Degraded", "状态异常")
        case .offline: return language.text("Offline", "离线")
        case .incompatible: return language.text("Incompatible", "协议不兼容")
        }
    }

    var color: NSColor {
        switch self {
        case .online: return .systemGreen
        case .degraded: return .systemOrange
        case .offline, .incompatible: return .systemRed
        case .disabled, .waitingForAddress, .connecting: return .tertiaryLabelColor
        }
    }
}

@MainActor
final class PeerStatusStore: ObservableObject {
    @Published private(set) var state: PeerConnectionState = .disabled
    @Published private(set) var remote: PeerStatusPayload?
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var lastError: PeerProtocolError?
    @Published private(set) var localServerError: String?
    @Published private(set) var cpuTrend: [TrendPoint] = []
    @Published private(set) var memoryTrend: [TrendPoint] = []
    @Published private(set) var thermalTrend: [TrendPoint] = []
    @Published private(set) var gpuTrend: [TrendPoint] = []
    @Published private(set) var storageTrend: [TrendPoint] = []
    @Published private(set) var uploadTrend: [TrendPoint] = []
    @Published private(set) var downloadTrend: [TrendPoint] = []

    private var monitoringStartedAt: Date?
    private var lastAcceptedSequence: UInt64?
    private var lastStartedAt: String?
    private let historyDuration: TimeInterval = 5 * 60

    func setDisabled() {
        state = .disabled
        monitoringStartedAt = nil
        lastError = nil
        remote = nil
        lastReceivedAt = nil
        lastAcceptedSequence = nil
        lastStartedAt = nil
        clearTrends()
    }

    func setWaitingForAddress() {
        state = .waitingForAddress
        monitoringStartedAt = nil
        lastError = nil
        remote = nil
        lastReceivedAt = nil
        lastAcceptedSequence = nil
        lastStartedAt = nil
        clearTrends()
    }

    func beginConnecting(at date: Date = .now) {
        state = .connecting
        monitoringStartedAt = date
        lastError = nil
        remote = nil
        lastReceivedAt = nil
        lastAcceptedSequence = nil
        lastStartedAt = nil
        clearTrends()
    }

    func setLocalServerError(_ message: String?) {
        localServerError = message
    }

    func apply(_ payload: PeerStatusPayload, receivedAt: Date = .now) {
        lastReceivedAt = receivedAt
        monitoringStartedAt = monitoringStartedAt ?? receivedAt
        lastError = nil

        if let lastStartedAt, lastStartedAt != payload.device.startedAt {
            clearTrends()
            lastAcceptedSequence = nil
        }
        lastStartedAt = payload.device.startedAt

        if let lastAcceptedSequence, payload.sequence < lastAcceptedSequence {
            updateConnectionState(for: remote)
            return
        }
        let isNewSample = payload.sequence != lastAcceptedSequence
        remote = payload
        if isNewSample {
            lastAcceptedSequence = payload.sequence
            appendPayload(payload, at: receivedAt)
        }
        updateConnectionState(for: payload)
    }

    func applyFailure(_ error: PeerProtocolError, at date: Date = .now) {
        lastError = error
        if error == .incompatibleVersion {
            state = .incompatible
            return
        }
        if error == .invalidAddress || error == .invalidSecret {
            state = .offline
            return
        }
        let reference = lastReceivedAt ?? monitoringStartedAt ?? date
        if date.timeIntervalSince(reference) >= 15 { state = .offline }
    }

    private func updateConnectionState(for payload: PeerStatusPayload?) {
        guard let payload else {
            state = .connecting
            return
        }
        let states = [
            payload.metrics.cpu.state,
            payload.metrics.memory.state,
            payload.metrics.thermal.state,
            payload.metrics.network.state
        ]
        state = states.contains(.critical) || states.contains(.stale) ? .degraded : .online
    }

    private func appendPayload(_ payload: PeerStatusPayload, at date: Date) {
        if payload.metrics.cpu.state != .stale, let value = payload.metrics.cpu.utilizationPct {
            append(value, at: date, to: &cpuTrend)
        }
        if payload.metrics.memory.state != .stale, let value = payload.metrics.memory.usedPct {
            append(value, at: date, to: &memoryTrend)
        }
        if payload.metrics.thermal.state != .stale {
            if let value = payload.metrics.thermal.averageCelsius { append(value, at: date, to: &thermalTrend) }
            if let value = payload.metrics.thermal.gpuCelsius { append(value, at: date, to: &gpuTrend) }
            if let value = payload.metrics.thermal.effectiveStorageCelsius { append(value, at: date, to: &storageTrend) }
        }
        if payload.metrics.network.state != .stale {
            if let value = payload.metrics.network.uploadBytesPerSecond { append(value, at: date, to: &uploadTrend) }
            if let value = payload.metrics.network.downloadBytesPerSecond { append(value, at: date, to: &downloadTrend) }
        }
    }

    private func append(_ value: Double, at date: Date, to trend: inout [TrendPoint]) {
        guard value.isFinite else { return }
        trend.append(TrendPoint(date: date, value: value))
        let cutoff = date.addingTimeInterval(-historyDuration)
        trend.removeAll { $0.date < cutoff }
    }

    private func clearTrends() {
        cpuTrend.removeAll()
        memoryTrend.removeAll()
        thermalTrend.removeAll()
        gpuTrend.removeAll()
        storageTrend.removeAll()
        uploadTrend.removeAll()
        downloadTrend.removeAll()
    }
}

@MainActor
final class PeerCoordinator {
    let configuration: PeerConfiguration
    let statusStore: PeerStatusStore

    private let monitorStore: MonitorStore
    private let payloadBox = PeerPayloadBox()
    private let startedAt = Date()
    private var sequence: UInt64 = 1
    private var server: PeerHTTPServer?
    private var serverSecret: Data?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(monitorStore: MonitorStore, configuration: PeerConfiguration, statusStore: PeerStatusStore) {
        self.monitorStore = monitorStore
        self.configuration = configuration
        self.statusStore = statusStore
        publish(snapshot: monitorStore.snapshot)

        monitorStore.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.sequence &+= 1
                self.publish(snapshot: snapshot)
            }
            .store(in: &cancellables)

        configuration.$deviceName
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.sequence &+= 1
                self.publish(snapshot: self.monitorStore.snapshot)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            configuration.$enabled,
            configuration.$peerAddress,
            configuration.$pairingSecret
        )
        .dropFirst()
        .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.restartNetworking() }
        .store(in: &cancellables)
    }

    func start() {
        restartNetworking()
    }

    func stop() {
        server?.stop()
        server = nil
        serverSecret = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func testConnection() {
        restartNetworking()
    }

    private func publish(snapshot: SystemSnapshot) {
        let payload = PeerStatusPayload.make(
            snapshot: snapshot,
            sequence: sequence,
            deviceID: configuration.deviceID,
            deviceName: configuration.deviceName,
            startedAt: startedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(payload) { payloadBox.set(data) }
    }

    private func restartNetworking() {
        pollTask?.cancel()
        pollTask = nil
        statusStore.setLocalServerError(nil)

        guard configuration.enabled else {
            server?.stop()
            server = nil
            serverSecret = nil
            statusStore.setDisabled()
            return
        }
        guard let secret = try? PeerSecurity.decodeSecret(configuration.pairingSecret) else {
            statusStore.applyFailure(.invalidSecret)
            return
        }

        // Changing the peer address or pressing “Test connection” should only
        // restart outbound polling. Rebinding the inbound listener on every
        // configuration event races NWListener's asynchronous cancellation and
        // can fail with EADDRINUSE (NWError 48).
        if serverSecret != secret {
            server?.stop()
            server = nil
            serverSecret = nil
        }
        if server == nil {
            let newServer = PeerHTTPServer(secret: secret, payloadBox: payloadBox) { [weak self] error in
                Task { @MainActor [weak self] in self?.statusStore.setLocalServerError(error) }
            }
            do {
                try newServer.start()
                server = newServer
                serverSecret = secret
            } catch {
                statusStore.setLocalServerError(error.localizedDescription)
            }
        }

        guard !configuration.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusStore.setWaitingForAddress()
            return
        }
        statusStore.beginConnecting()
        guard let endpoint = try? PeerEndpoint.parse(configuration.peerAddress) else {
            statusStore.applyFailure(.invalidAddress)
            return
        }
        let deviceID = configuration.deviceID
        pollTask = Task { [weak self] in
            var failureCount = 0
            while !Task.isCancelled {
                do {
                    let payload = try await PeerHTTPClient.fetch(
                        endpoint: endpoint,
                        deviceID: deviceID,
                        secret: secret
                    )
                    guard !Task.isCancelled else { return }
                    self?.statusStore.apply(payload)
                    failureCount = 0
                } catch let error as PeerProtocolError {
                    guard !Task.isCancelled else { return }
                    self?.statusStore.applyFailure(error)
                    failureCount += 1
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.statusStore.applyFailure(.connectionFailed)
                    failureCount += 1
                }
                let delay: UInt64
                switch failureCount {
                case 0, 1: delay = 5
                case 2: delay = 10
                case 3: delay = 20
                default: delay = 30
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
}
