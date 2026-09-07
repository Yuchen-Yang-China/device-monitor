import Foundation

enum PeerMetricState: String, Codable, Sendable {
    case normal
    case elevated
    case critical
    case collecting
    case unavailable
    case stale

    init(_ level: MetricLevel) {
        switch level {
        case .normal: self = .normal
        case .elevated: self = .elevated
        case .critical: self = .critical
        case .sampling: self = .collecting
        case .unavailable: self = .unavailable
        case .stale: self = .stale
        }
    }

    var metricLevel: MetricLevel {
        switch self {
        case .normal: return .normal
        case .elevated: return .elevated
        case .critical: return .critical
        case .collecting: return .sampling
        case .unavailable: return .unavailable
        case .stale: return .stale
        }
    }
}

struct PeerStatusPayload: Codable, Equatable, Sendable {
    static let apiVersion = 1

    struct Device: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let platform: String
        let osVersion: String
        let appVersion: String
        let startedAt: String
    }

    struct Capabilities: Codable, Equatable, Sendable {
        let cpuBreakdown: Bool
        let loadAverage: Bool
        let hybridCoreTopology: Bool
        let memoryBreakdown: Bool
        let swap: Bool
        let temperatureSensors: Bool
        let osThermalState: Bool
        let wifiSignal: Bool
        /// Added compatibly to v1 after the Windows implementation exposed
        /// independent GPU and storage temperature sensors.
        let gpuTemperature: Bool?
        let storageTemperature: Bool?
        /// Compatibility alias accepted from early Windows builds.
        let ssdTemperature: Bool?
    }

    struct Metrics: Codable, Equatable, Sendable {
        let cpu: CPU
        let memory: Memory
        let thermal: Thermal
        let network: Network
    }

    struct CPU: Codable, Equatable, Sendable {
        let state: PeerMetricState
        let sampledAt: String?
        let utilizationPct: Double?
        let userPct: Double?
        let systemPct: Double?
        let idlePct: Double?
        let loadAverage1: Double?
        let loadAverage5: Double?
        let loadAverage15: Double?
        let performanceCores: Int
        let efficiencyCores: Int
        let hybridTopology: Bool

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case state, sampledAt, utilizationPct, userPct, systemPct, idlePct
            case loadAverage1, loadAverage5, loadAverage15
            case performanceCores, efficiencyCores, hybridTopology
        }

        init(
            state: PeerMetricState,
            sampledAt: String?,
            utilizationPct: Double?,
            userPct: Double?,
            systemPct: Double?,
            idlePct: Double?,
            loadAverage1: Double?,
            loadAverage5: Double?,
            loadAverage15: Double?,
            performanceCores: Int,
            efficiencyCores: Int,
            hybridTopology: Bool
        ) {
            self.state = state
            self.sampledAt = sampledAt
            self.utilizationPct = utilizationPct
            self.userPct = userPct
            self.systemPct = systemPct
            self.idlePct = idlePct
            self.loadAverage1 = loadAverage1
            self.loadAverage5 = loadAverage5
            self.loadAverage15 = loadAverage15
            self.performanceCores = performanceCores
            self.efficiencyCores = efficiencyCores
            self.hybridTopology = hybridTopology
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try container.requireAll(CodingKeys.allCases)
            state = try container.decode(PeerMetricState.self, forKey: .state)
            sampledAt = try container.decodeIfPresent(String.self, forKey: .sampledAt)
            utilizationPct = try container.decodeIfPresent(Double.self, forKey: .utilizationPct)
            userPct = try container.decodeIfPresent(Double.self, forKey: .userPct)
            systemPct = try container.decodeIfPresent(Double.self, forKey: .systemPct)
            idlePct = try container.decodeIfPresent(Double.self, forKey: .idlePct)
            loadAverage1 = try container.decodeIfPresent(Double.self, forKey: .loadAverage1)
            loadAverage5 = try container.decodeIfPresent(Double.self, forKey: .loadAverage5)
            loadAverage15 = try container.decodeIfPresent(Double.self, forKey: .loadAverage15)
            performanceCores = try container.decode(Int.self, forKey: .performanceCores)
            efficiencyCores = try container.decode(Int.self, forKey: .efficiencyCores)
            hybridTopology = try container.decode(Bool.self, forKey: .hybridTopology)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encodeOptional(sampledAt, forKey: .sampledAt)
            try container.encodeOptional(utilizationPct, forKey: .utilizationPct)
            try container.encodeOptional(userPct, forKey: .userPct)
            try container.encodeOptional(systemPct, forKey: .systemPct)
            try container.encodeOptional(idlePct, forKey: .idlePct)
            try container.encodeOptional(loadAverage1, forKey: .loadAverage1)
            try container.encodeOptional(loadAverage5, forKey: .loadAverage5)
            try container.encodeOptional(loadAverage15, forKey: .loadAverage15)
            try container.encode(performanceCores, forKey: .performanceCores)
            try container.encode(efficiencyCores, forKey: .efficiencyCores)
            try container.encode(hybridTopology, forKey: .hybridTopology)
        }
    }

    struct Memory: Codable, Equatable, Sendable {
        let state: PeerMetricState
        let sampledAt: String?
        let usedBytes: UInt64?
        let totalBytes: UInt64?
        let usedPct: Double?
        let wiredBytes: UInt64?
        let compressedBytes: UInt64?
        let cachedBytes: UInt64?
        let swapUsedBytes: UInt64?
        let swapTotalBytes: UInt64?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case state, sampledAt, usedBytes, totalBytes, usedPct, wiredBytes
            case compressedBytes, cachedBytes, swapUsedBytes, swapTotalBytes
        }

        init(
            state: PeerMetricState,
            sampledAt: String?,
            usedBytes: UInt64?,
            totalBytes: UInt64?,
            usedPct: Double?,
            wiredBytes: UInt64?,
            compressedBytes: UInt64?,
            cachedBytes: UInt64?,
            swapUsedBytes: UInt64?,
            swapTotalBytes: UInt64?
        ) {
            self.state = state
            self.sampledAt = sampledAt
            self.usedBytes = usedBytes
            self.totalBytes = totalBytes
            self.usedPct = usedPct
            self.wiredBytes = wiredBytes
            self.compressedBytes = compressedBytes
            self.cachedBytes = cachedBytes
            self.swapUsedBytes = swapUsedBytes
            self.swapTotalBytes = swapTotalBytes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try container.requireAll(CodingKeys.allCases)
            state = try container.decode(PeerMetricState.self, forKey: .state)
            sampledAt = try container.decodeIfPresent(String.self, forKey: .sampledAt)
            usedBytes = try container.decodeIfPresent(UInt64.self, forKey: .usedBytes)
            totalBytes = try container.decodeIfPresent(UInt64.self, forKey: .totalBytes)
            usedPct = try container.decodeIfPresent(Double.self, forKey: .usedPct)
            wiredBytes = try container.decodeIfPresent(UInt64.self, forKey: .wiredBytes)
            compressedBytes = try container.decodeIfPresent(UInt64.self, forKey: .compressedBytes)
            cachedBytes = try container.decodeIfPresent(UInt64.self, forKey: .cachedBytes)
            swapUsedBytes = try container.decodeIfPresent(UInt64.self, forKey: .swapUsedBytes)
            swapTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .swapTotalBytes)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encodeOptional(sampledAt, forKey: .sampledAt)
            try container.encodeOptional(usedBytes, forKey: .usedBytes)
            try container.encodeOptional(totalBytes, forKey: .totalBytes)
            try container.encodeOptional(usedPct, forKey: .usedPct)
            try container.encodeOptional(wiredBytes, forKey: .wiredBytes)
            try container.encodeOptional(compressedBytes, forKey: .compressedBytes)
            try container.encodeOptional(cachedBytes, forKey: .cachedBytes)
            try container.encodeOptional(swapUsedBytes, forKey: .swapUsedBytes)
            try container.encodeOptional(swapTotalBytes, forKey: .swapTotalBytes)
        }
    }

    struct Thermal: Codable, Equatable, Sendable {
        let state: PeerMetricState
        let sampledAt: String?
        let osState: String
        let averageCelsius: Double?
        let hottestCelsius: Double?
        let storageCelsius: Double?
        let gpuCelsius: Double?
        /// Compatibility alias accepted from early Windows builds. New
        /// senders use storageCelsius.
        let ssdCelsius: Double?

        var effectiveStorageCelsius: Double? { storageCelsius ?? ssdCelsius }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case state, sampledAt, osState, averageCelsius, hottestCelsius, storageCelsius
            case gpuCelsius, ssdCelsius
        }

        init(
            state: PeerMetricState,
            sampledAt: String?,
            osState: String,
            averageCelsius: Double?,
            hottestCelsius: Double?,
            storageCelsius: Double?,
            gpuCelsius: Double?,
            ssdCelsius: Double?
        ) {
            self.state = state
            self.sampledAt = sampledAt
            self.osState = osState
            self.averageCelsius = averageCelsius
            self.hottestCelsius = hottestCelsius
            self.storageCelsius = storageCelsius
            self.gpuCelsius = gpuCelsius
            self.ssdCelsius = ssdCelsius
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try container.requireAll([.state, .sampledAt, .osState, .averageCelsius, .hottestCelsius, .storageCelsius])
            state = try container.decode(PeerMetricState.self, forKey: .state)
            sampledAt = try container.decodeIfPresent(String.self, forKey: .sampledAt)
            osState = try container.decode(String.self, forKey: .osState)
            averageCelsius = try container.decodeIfPresent(Double.self, forKey: .averageCelsius)
            hottestCelsius = try container.decodeIfPresent(Double.self, forKey: .hottestCelsius)
            storageCelsius = try container.decodeIfPresent(Double.self, forKey: .storageCelsius)
            gpuCelsius = try container.decodeIfPresent(Double.self, forKey: .gpuCelsius)
            ssdCelsius = try container.decodeIfPresent(Double.self, forKey: .ssdCelsius)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encodeOptional(sampledAt, forKey: .sampledAt)
            try container.encode(osState, forKey: .osState)
            try container.encodeOptional(averageCelsius, forKey: .averageCelsius)
            try container.encodeOptional(hottestCelsius, forKey: .hottestCelsius)
            try container.encodeOptional(storageCelsius, forKey: .storageCelsius)
            if let gpuCelsius { try container.encode(gpuCelsius, forKey: .gpuCelsius) }
            if let ssdCelsius { try container.encode(ssdCelsius, forKey: .ssdCelsius) }
        }
    }

    struct Network: Codable, Equatable, Sendable {
        let state: PeerMetricState
        let sampledAt: String?
        let uploadBytesPerSecond: Double?
        let downloadBytesPerSecond: Double?
        let sessionUploadBytes: UInt64
        let sessionDownloadBytes: UInt64

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case state, sampledAt, uploadBytesPerSecond, downloadBytesPerSecond
            case sessionUploadBytes, sessionDownloadBytes
        }

        init(
            state: PeerMetricState,
            sampledAt: String?,
            uploadBytesPerSecond: Double?,
            downloadBytesPerSecond: Double?,
            sessionUploadBytes: UInt64,
            sessionDownloadBytes: UInt64
        ) {
            self.state = state
            self.sampledAt = sampledAt
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.sessionUploadBytes = sessionUploadBytes
            self.sessionDownloadBytes = sessionDownloadBytes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try container.requireAll(CodingKeys.allCases)
            state = try container.decode(PeerMetricState.self, forKey: .state)
            sampledAt = try container.decodeIfPresent(String.self, forKey: .sampledAt)
            uploadBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .uploadBytesPerSecond)
            downloadBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .downloadBytesPerSecond)
            sessionUploadBytes = try container.decode(UInt64.self, forKey: .sessionUploadBytes)
            sessionDownloadBytes = try container.decode(UInt64.self, forKey: .sessionDownloadBytes)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encodeOptional(sampledAt, forKey: .sampledAt)
            try container.encodeOptional(uploadBytesPerSecond, forKey: .uploadBytesPerSecond)
            try container.encodeOptional(downloadBytesPerSecond, forKey: .downloadBytesPerSecond)
            try container.encode(sessionUploadBytes, forKey: .sessionUploadBytes)
            try container.encode(sessionDownloadBytes, forKey: .sessionDownloadBytes)
        }
    }

    let apiVersion: Int
    let sequence: UInt64
    let capturedAt: String
    let device: Device
    let capabilities: Capabilities
    let metrics: Metrics

    static func make(
        snapshot: SystemSnapshot,
        sequence: UInt64,
        deviceID: String,
        deviceName: String,
        startedAt: Date
    ) -> PeerStatusPayload {
        let networkState: PeerMetricState
        if snapshot.network.isStale {
            networkState = .stale
        } else if snapshot.network.capturedAt == nil {
            networkState = .collecting
        } else {
            networkState = .normal
        }
        let hasTemperature = snapshot.thermal.socCelsius != nil ||
            snapshot.thermal.hottestSoCCelsius != nil ||
            snapshot.thermal.ssdCelsius != nil

        return PeerStatusPayload(
            apiVersion: apiVersion,
            sequence: sequence,
            capturedAt: PeerTimestamp.string(from: snapshot.capturedAt),
            device: Device(
                id: deviceID,
                name: String(deviceName.prefix(80)),
                platform: "macos",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                startedAt: PeerTimestamp.string(from: startedAt)
            ),
            capabilities: Capabilities(
                cpuBreakdown: true,
                loadAverage: true,
                hybridCoreTopology: snapshot.cpu.hasHybridCoreTopology,
                memoryBreakdown: true,
                swap: snapshot.memory.swapTotalBytes != nil,
                temperatureSensors: hasTemperature,
                osThermalState: snapshot.thermal.state != .unavailable,
                wifiSignal: true,
                gpuTemperature: false,
                storageTemperature: snapshot.thermal.ssdCelsius != nil,
                ssdTemperature: nil
            ),
            metrics: Metrics(
                cpu: CPU(
                    state: PeerMetricState(snapshot.cpu.level),
                    sampledAt: snapshot.cpu.capturedAt.map(PeerTimestamp.string),
                    utilizationPct: snapshot.cpu.utilization,
                    userPct: snapshot.cpu.userPercent,
                    systemPct: snapshot.cpu.systemPercent,
                    idlePct: snapshot.cpu.idlePercent,
                    loadAverage1: snapshot.cpu.loadAverage1,
                    loadAverage5: snapshot.cpu.loadAverage5,
                    loadAverage15: snapshot.cpu.loadAverage15,
                    performanceCores: snapshot.cpu.performanceCoreCount,
                    efficiencyCores: snapshot.cpu.efficiencyCoreCount,
                    hybridTopology: snapshot.cpu.hasHybridCoreTopology
                ),
                memory: Memory(
                    state: PeerMetricState(snapshot.memory.level),
                    sampledAt: snapshot.memory.capturedAt.map(PeerTimestamp.string),
                    usedBytes: snapshot.memory.usedBytes,
                    totalBytes: snapshot.memory.totalBytes,
                    usedPct: snapshot.memory.usedRatio.map { $0 * 100 },
                    wiredBytes: snapshot.memory.wiredBytes,
                    compressedBytes: snapshot.memory.compressedBytes,
                    cachedBytes: snapshot.memory.cachedBytes,
                    swapUsedBytes: snapshot.memory.swapUsedBytes,
                    swapTotalBytes: snapshot.memory.swapTotalBytes
                ),
                thermal: Thermal(
                    state: PeerMetricState(snapshot.thermal.level),
                    sampledAt: snapshot.thermal.capturedAt.map(PeerTimestamp.string),
                    osState: snapshot.thermal.state.rawValue.lowercased(),
                    averageCelsius: snapshot.thermal.socCelsius,
                    hottestCelsius: snapshot.thermal.hottestSoCCelsius,
                    storageCelsius: snapshot.thermal.ssdCelsius,
                    gpuCelsius: nil,
                    ssdCelsius: nil
                ),
                network: Network(
                    state: networkState,
                    sampledAt: snapshot.network.capturedAt.map(PeerTimestamp.string),
                    uploadBytesPerSecond: snapshot.network.uploadBytesPerSecond,
                    downloadBytesPerSecond: snapshot.network.downloadBytesPerSecond,
                    sessionUploadBytes: snapshot.network.sessionUploadBytes,
                    sessionDownloadBytes: snapshot.network.sessionDownloadBytes
                )
            )
        )
    }

    func validate() throws {
        guard apiVersion == Self.apiVersion else { throw PeerProtocolError.incompatibleVersion }
        guard UUID(uuidString: device.id)?.uuidString.lowercased() == device.id.lowercased() else {
            throw PeerProtocolError.invalidPayload
        }
        guard !device.name.isEmpty, device.name.count <= 80,
              device.platform == "macos" || device.platform == "windows",
              PeerTimestamp.date(from: capturedAt) != nil,
              PeerTimestamp.date(from: device.startedAt) != nil
        else { throw PeerProtocolError.invalidPayload }

        let percentages = [
            metrics.cpu.utilizationPct, metrics.cpu.userPct, metrics.cpu.systemPct,
            metrics.cpu.idlePct, metrics.memory.usedPct
        ]
        guard percentages.allSatisfy({ value in
            guard let value else { return true }
            return value.isFinite && value >= 0 && value <= 100
        }) else { throw PeerProtocolError.invalidPayload }

        let nonNegative = [
            metrics.cpu.loadAverage1, metrics.cpu.loadAverage5, metrics.cpu.loadAverage15,
            metrics.network.uploadBytesPerSecond, metrics.network.downloadBytesPerSecond
        ]
        guard nonNegative.allSatisfy({ value in
            guard let value else { return true }
            return value.isFinite && value >= 0
        }) else { throw PeerProtocolError.invalidPayload }

        let temperatures = [
            metrics.thermal.averageCelsius, metrics.thermal.hottestCelsius,
            metrics.thermal.storageCelsius, metrics.thermal.gpuCelsius,
            metrics.thermal.ssdCelsius
        ]
        guard temperatures.allSatisfy({ $0?.isFinite ?? true }) else {
            throw PeerProtocolError.invalidPayload
        }

        let sampleTimes = [
            metrics.cpu.sampledAt, metrics.memory.sampledAt,
            metrics.thermal.sampledAt, metrics.network.sampledAt
        ]
        guard sampleTimes.allSatisfy({ $0 == nil || PeerTimestamp.date(from: $0!) != nil }) else {
            throw PeerProtocolError.invalidPayload
        }
    }
}

enum PeerProtocolError: Error, Equatable {
    case invalidAddress
    case invalidSecret
    case invalidRequest
    case invalidResponse
    case invalidSignature
    case clockMismatch
    case replayedNonce
    case incompatibleVersion
    case invalidPayload
    case bodyTooLarge
    case connectionFailed
    case timeout
}

enum PeerTimestamp {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.isLenient = false
        guard let result = formatter.date(from: value), string(from: result) == value else { return nil }
        return result
    }
}

private extension KeyedDecodingContainer {
    func requireAll<S: Sequence>(_ keys: S) throws where S.Element == Key {
        for key in keys where !contains(key) {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: codingPath, debugDescription: "Missing required field \(key.stringValue)")
            )
        }
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
