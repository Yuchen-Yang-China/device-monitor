import Darwin
import CoreWLAN
import Foundation
import OSLog
import SensorBridge
import SystemConfiguration

// All mutable sampling state is confined to samplingQueue. UI updates are dispatched to the main actor.
final class SystemMonitor: @unchecked Sendable {
    private struct CPUTicks {
        let user: [UInt32]
        let system: [UInt32]
        let idle: [UInt32]
        let nice: [UInt32]

        var processorCount: Int { min(user.count, min(system.count, min(idle.count, nice.count))) }
    }

    private struct NetworkCounter {
        let received: UInt32
        let sent: UInt32
        let interface: String?
        let capturedAt: Date
    }

    private struct FailureState {
        var consecutive = 0
        var lastLoggedAt: Date?
        var firstFailedAt: Date?
        var isFailing = false
    }

    private static let logger = Logger(subsystem: "com.yangyuchen.devicemonitor", category: "sampling")
    private static let failureLogInterval: TimeInterval = 60

    private let store: MonitorStore
    private let samplingQueue = DispatchQueue(label: "com.yangyuchen.devicemonitor.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var samplingProfile: SamplingProfile
    private var lastNetworkSampleAt: Date?
    private var lastSystemSampleAt: Date?
    private var lastThermalSampleAt: Date?
    private var lastProcessSampleAt: Date?
    private var lastWiFiSampleAt: Date?
    private var previousCPUTicks: CPUTicks?
    private var previousNetworkCounter: NetworkCounter?
    private var previousSnapshot = SystemSnapshot.initial
    private var memoryPressureLevel: MetricLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isRunning = false
    private var forceSystemSample = false
    private var detailDemand: MetricKind?
    private var processRefreshRequested = false
    private var wifiRefreshRequested = false
    private let processSampler = ProcessSampler()
    private var sessionUploadBytes: UInt64 = 0
    private var sessionDownloadBytes: UInt64 = 0
    private var coreTopology: (performance: Int, efficiency: Int, isHybrid: Bool)?
    private var failureStates: [String: FailureState] = [:]
    private var lastSuccessAt: [String: Date] = [:]

    init(store: MonitorStore, profile: SamplingProfile = .balanced) {
        self.store = store
        self.samplingProfile = profile
    }

    func start() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.resetSamplingBaselines()
            self.installMemoryPressureObserver()
            self.sample()
            self.scheduleTimer()
        }
    }

    func stop() {
        samplingQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.memoryPressureSource?.cancel()
            self.memoryPressureSource = nil
            self.resetSamplingBaselines()
            self.publishCurrentSnapshot()
        }
    }

    func setDetailDemand(_ demand: MetricKind?) {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            let previousDemand = self.detailDemand
            self.detailDemand = demand
            if demand == nil {
                self.processRefreshRequested = false
                self.wifiRefreshRequested = false
                self.processSampler.reset()
                self.lastProcessSampleAt = nil
                self.previousSnapshot.topCPUProcesses = []
                self.previousSnapshot.topMemoryProcesses = []
                self.previousSnapshot.processSampledAt = nil
                self.previousSnapshot.network.wifi = nil
            }
            if demand == .cpu || demand == .memory {
                self.processRefreshRequested = true
                if previousDemand != demand {
                    self.processSampler.reset()
                    self.lastProcessSampleAt = nil
                    self.previousSnapshot.topCPUProcesses = []
                    self.previousSnapshot.topMemoryProcesses = []
                    self.previousSnapshot.processSampledAt = nil
                }
            }
            if demand == .network {
                self.wifiRefreshRequested = true
                if previousDemand != demand {
                    self.lastWiFiSampleAt = nil
                }
            } else {
                self.lastWiFiSampleAt = nil
                self.wifiRefreshRequested = false
                self.previousSnapshot.network.wifi = nil
            }
            // Demand changes can happen before the next timer tick. Publish
            // the cleared process/Wi-Fi state immediately so a reopened detail
            // view never renders the previous session's data.
            self.publishCurrentSnapshot()
        }
    }

    func setSamplingProfile(_ profile: SamplingProfile) {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.samplingProfile = profile
            if self.isRunning { self.scheduleTimer() }
        }
    }

    func resetNetworkTotals() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.sessionUploadBytes = 0
            self.sessionDownloadBytes = 0
            self.previousNetworkCounter = nil
            self.lastNetworkSampleAt = nil
            self.previousSnapshot.network.sessionUploadBytes = 0
            self.previousSnapshot.network.sessionDownloadBytes = 0
            self.publishCurrentSnapshot()
        }
    }

    private func resetSamplingBaselines() {
        previousCPUTicks = nil
        previousNetworkCounter = nil
        lastNetworkSampleAt = nil
        lastSystemSampleAt = nil
        lastThermalSampleAt = nil
        lastProcessSampleAt = nil
        lastWiFiSampleAt = nil
        processSampler.reset()
        failureStates.removeAll(keepingCapacity: true)
        lastSuccessAt.removeAll(keepingCapacity: true)
        memoryPressureLevel = .normal
        forceSystemSample = true
        var resetSnapshot = SystemSnapshot.initial
        resetSnapshot.network.sessionUploadBytes = sessionUploadBytes
        resetSnapshot.network.sessionDownloadBytes = sessionDownloadBytes
        previousSnapshot = resetSnapshot
    }

    private func publishCurrentSnapshot() {
        var snapshot = previousSnapshot
        snapshot.capturedAt = Date()
        previousSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.store.apply(snapshot)
        }
    }

    private func recordFailure(_ category: String, now: Date) {
        var state = failureStates[category, default: FailureState()]
        state.consecutive += 1
        let shouldLog = !state.isFailing ||
            state.lastLoggedAt == nil ||
            now.timeIntervalSince(state.lastLoggedAt!) >= Self.failureLogInterval
        state.isFailing = true
        state.firstFailedAt = state.firstFailedAt ?? now
        if shouldLog {
            if let lastSuccess = lastSuccessAt[category] {
                let age = max(0, now.timeIntervalSince(lastSuccess))
                Self.logger.warning(
                    "Sampling failure category=\(category, privacy: .public) consecutive=\(state.consecutive, privacy: .public) sinceLastSuccess=\(age, privacy: .public)s"
                )
            } else {
                Self.logger.warning(
                    "Sampling failure category=\(category, privacy: .public) consecutive=\(state.consecutive, privacy: .public)"
                )
            }
            state.lastLoggedAt = now
        }
        failureStates[category] = state
    }

    private func recordSuccess(_ category: String, now: Date) {
        guard let state = failureStates[category], state.isFailing else { return }
        let outage = state.firstFailedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        Self.logger.info(
            "Sampling recovered category=\(category, privacy: .public) after=\(state.consecutive, privacy: .public) outage=\(outage, privacy: .public)s"
        )
        failureStates[category] = FailureState()
        lastSuccessAt[category] = now
    }

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        let interval = max(1, samplingProfile.networkInterval)
        let intervalMilliseconds = Int(interval * 1_000)
        let leewayMilliseconds = Int(max(250, min(1_000, interval * 500)))
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds),
            leeway: .milliseconds(leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    private func installMemoryPressureObserver() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: samplingQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let level: MetricLevel
            if source.data.contains(.critical) {
                level = .critical
            } else if source.data.contains(.warning) {
                level = .elevated
            } else {
                level = .normal
            }
            self.memoryPressureLevel = level
            // Pressure events should be visible immediately even in the
            // low-power profile, whose normal system cadence is 10 seconds.
            self.forceSystemSample = true
            self.sample()
        }
        memoryPressureSource = source
        source.resume()
    }

    private func sample() {
        guard isRunning else { return }
        let now = Date()
        var snapshot = previousSnapshot
        snapshot.capturedAt = now

        let shouldSampleSystem = forceSystemSample || lastSystemSampleAt == nil || now.timeIntervalSince(lastSystemSampleAt!) >= samplingProfile.systemInterval
        let shouldSampleThermal = lastThermalSampleAt == nil || now.timeIntervalSince(lastThermalSampleAt!) >= samplingProfile.thermalInterval
        let shouldSampleNetwork = lastNetworkSampleAt == nil || now.timeIntervalSince(lastNetworkSampleAt!) >= samplingProfile.networkInterval
        forceSystemSample = false

        if shouldSampleSystem {
            snapshot.cpu = readCPU(now: now)
            snapshot.memory = readMemory(now: now)
            lastSystemSampleAt = now
        }

        if shouldSampleThermal {
            snapshot.thermal = readThermal(now: now)
            lastThermalSampleAt = now
        }

        if (detailDemand == .cpu || detailDemand == .memory) &&
            (processRefreshRequested || lastProcessSampleAt == nil || now.timeIntervalSince(lastProcessSampleAt!) >= samplingProfile.processInterval) {
            let hadBaseline = processSampler.hasBaseline
            let processUsage = processSampler.sample(at: now)
            if hadBaseline {
                snapshot.topCPUProcesses = processUsage.cpu
                snapshot.topMemoryProcesses = processUsage.memory
                snapshot.processSampledAt = now
                lastProcessSampleAt = now
            } else {
                snapshot.topCPUProcesses = []
                snapshot.topMemoryProcesses = []
                snapshot.processSampledAt = nil
                // Take the second observation on the next regular tick.
                lastProcessSampleAt = nil
            }
            processRefreshRequested = false
        }

        if shouldSampleNetwork {
            snapshot.network = readNetwork(now: now)
            lastNetworkSampleAt = now
        }
        // A timer tick can legitimately produce no new data (for example,
        // while the network counter is stale). Keep the timestamp local to
        // the sampler but avoid waking SwiftUI unless a metric changed.
        var comparableSnapshot = snapshot
        comparableSnapshot.capturedAt = previousSnapshot.capturedAt
        let hasMeaningfulChange = comparableSnapshot != previousSnapshot
        previousSnapshot = snapshot
        guard hasMeaningfulChange else { return }

        DispatchQueue.main.async { [weak self] in
            self?.store.apply(snapshot)
        }
    }

    private func readCPU(now: Date) -> CPUReading {
        guard let ticks = readCPUTicks() else {
            recordFailure("cpu", now: now)
            return CPUReading(
                utilization: previousSnapshot.cpu.utilization,
                userPercent: previousSnapshot.cpu.userPercent,
                systemPercent: previousSnapshot.cpu.systemPercent,
                idlePercent: previousSnapshot.cpu.idlePercent,
                loadAverage1: previousSnapshot.cpu.loadAverage1,
                loadAverage5: previousSnapshot.cpu.loadAverage5,
                loadAverage15: previousSnapshot.cpu.loadAverage15,
                performanceCoreCount: previousSnapshot.cpu.performanceCoreCount,
                efficiencyCoreCount: previousSnapshot.cpu.efficiencyCoreCount,
                hasHybridCoreTopology: previousSnapshot.cpu.hasHybridCoreTopology,
                level: .stale,
                capturedAt: previousSnapshot.cpu.capturedAt
            )
        }
        recordSuccess("cpu", now: now)
        defer { previousCPUTicks = ticks }

        let loads = readLoadAverages()
        let topology = coreTopology ?? readCoreTopology()
        coreTopology = topology

        guard let previous = previousCPUTicks else {
            return CPUReading(
                utilization: nil,
                userPercent: nil,
                systemPercent: nil,
                idlePercent: nil,
                loadAverage1: loads.0,
                loadAverage5: loads.1,
                loadAverage15: loads.2,
                performanceCoreCount: topology.performance,
                efficiencyCoreCount: topology.efficiency,
                hasHybridCoreTopology: topology.isHybrid,
                level: .sampling,
                capturedAt: nil
            )
        }

        guard ticks.processorCount == previous.processorCount else {
            recordFailure("cpu-shape", now: now)
            return CPUReading(
                utilization: nil,
                userPercent: nil,
                systemPercent: nil,
                idlePercent: nil,
                loadAverage1: loads.0,
                loadAverage5: loads.1,
                loadAverage15: loads.2,
                performanceCoreCount: topology.performance,
                efficiencyCoreCount: topology.efficiency,
                hasHybridCoreTopology: topology.isHybrid,
                level: .sampling,
                capturedAt: nil
            )
        }
        recordSuccess("cpu-shape", now: now)

        let totalDelta = delta(ticks.user, previous.user) + delta(ticks.system, previous.system) +
            delta(ticks.idle, previous.idle) + delta(ticks.nice, previous.nice)
        let idleDelta = delta(ticks.idle, previous.idle)
        guard totalDelta > 0 else {
            return CPUReading(
                utilization: previousSnapshot.cpu.utilization,
                userPercent: previousSnapshot.cpu.userPercent,
                systemPercent: previousSnapshot.cpu.systemPercent,
                idlePercent: previousSnapshot.cpu.idlePercent,
                loadAverage1: loads.0,
                loadAverage5: loads.1,
                loadAverage15: loads.2,
                performanceCoreCount: topology.performance,
                efficiencyCoreCount: topology.efficiency,
                hasHybridCoreTopology: topology.isHybrid,
                level: .stale,
                capturedAt: previousSnapshot.cpu.capturedAt
            )
        }

        let userDelta = delta(ticks.user, previous.user)
        let systemDelta = delta(ticks.system, previous.system)
        let niceDelta = delta(ticks.nice, previous.nice)
        let userPercent = min(100, max(0, Double(userDelta + niceDelta) / Double(totalDelta) * 100))
        let systemPercent = min(100, max(0, Double(systemDelta) / Double(totalDelta) * 100))
        let idlePercent = min(100, max(0, Double(idleDelta) / Double(totalDelta) * 100))
        let utilization = min(100, max(0, 100 - idlePercent))
        let level: MetricLevel
        if utilization >= 90 {
            level = .critical
        } else if utilization >= 65 {
            level = .elevated
        } else {
            level = .normal
        }
        return CPUReading(
            utilization: utilization,
            userPercent: userPercent,
            systemPercent: systemPercent,
            idlePercent: idlePercent,
            loadAverage1: loads.0,
            loadAverage5: loads.1,
            loadAverage15: loads.2,
            performanceCoreCount: topology.performance,
            efficiencyCoreCount: topology.efficiency,
            hasHybridCoreTopology: topology.isHybrid,
            level: level,
            capturedAt: now
        )
    }

    private func delta(_ current: [UInt32], _ previous: [UInt32]) -> UInt64 {
        guard current.count == previous.count else { return 0 }
        // Each Mach CPU state counter is a 32-bit unsigned tick value. The
        // wrapping subtraction handles a per-core rollover without converting
        // a sign-extended Int32 into UInt64 (which would trap).
        return zip(current, previous).reduce(into: UInt64(0)) { result, pair in
            result &+= UInt64(pair.0 &- pair.1)
        }
    }

    private func readLoadAverages() -> (Double?, Double?, Double?) {
        var loads = [Double](repeating: 0, count: 3)
        let count = loads.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 3)
        }
        guard count == 3 else { return (nil, nil, nil) }
        return (loads[0], loads[1], loads[2])
    }

    private func readCoreTopology() -> (performance: Int, efficiency: Int, isHybrid: Bool) {
        let performance = sysctlInt(named: "hw.perflevel0.logicalcpu") ?? 0
        let efficiency = sysctlInt(named: "hw.perflevel1.logicalcpu") ?? 0
        if performance + efficiency > 0 {
            return (performance, efficiency, true)
        }
        return (ProcessInfo.processInfo.activeProcessorCount, 0, false)
    }

    private func sysctlInt(named name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        return result == 0 ? Int(value) : nil
    }

    private func readCPUTicks() -> CPUTicks? {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            let size = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)), size)
        }

        var user = [UInt32]()
        var system = [UInt32]()
        var idle = [UInt32]()
        var nice = [UInt32]()
        user.reserveCapacity(Int(processorCount))
        system.reserveCapacity(Int(processorCount))
        idle.reserveCapacity(Int(processorCount))
        nice.reserveCapacity(Int(processorCount))
        let stride = Int(CPU_STATE_MAX)
        guard processorInfoCount >= mach_msg_type_number_t(Int(processorCount) * stride) else {
            return nil
        }

        for index in 0..<Int(processorCount) {
            let offset = index * stride
            user.append(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_USER)]))
            system.append(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_SYSTEM)]))
            idle.append(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_IDLE)]))
            nice.append(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_NICE)]))
        }
        return CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    private func readMemory(now: Date) -> MemoryReading {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            recordFailure("memory", now: now)
            return MemoryReading(
                usedBytes: previousSnapshot.memory.usedBytes,
                totalBytes: ProcessInfo.processInfo.physicalMemory,
                wiredBytes: previousSnapshot.memory.wiredBytes,
                compressedBytes: previousSnapshot.memory.compressedBytes,
                cachedBytes: previousSnapshot.memory.cachedBytes,
                swapUsedBytes: previousSnapshot.memory.swapUsedBytes,
                swapTotalBytes: previousSnapshot.memory.swapTotalBytes,
                level: .stale,
                capturedAt: previousSnapshot.memory.capturedAt
            )
        }
        recordSuccess("memory", now: now)

        let pageSize = UInt64(getpagesize())
        let usedPages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * pageSize
        let wiredBytes = UInt64(statistics.wire_count) * pageSize
        let compressedBytes = UInt64(statistics.compressor_page_count) * pageSize
        let cachedBytes = UInt64(statistics.external_page_count) * pageSize
        let swap = readSwapUsage()
        if swap.used == nil || swap.total == nil {
            recordFailure("memory-swap", now: now)
        } else {
            recordSuccess("memory-swap", now: now)
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let ratio = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0

        let ratioLevel: MetricLevel
        if ratio >= 0.90 {
            ratioLevel = .critical
        } else if ratio >= 0.75 {
            ratioLevel = .elevated
        } else {
            ratioLevel = .normal
        }
        let level: MetricLevel
        switch (memoryPressureLevel, ratioLevel) {
        case (.critical, _), (_, .critical): level = .critical
        case (.elevated, _), (_, .elevated): level = .elevated
        default: level = .normal
        }

        return MemoryReading(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            level: level,
            capturedAt: now
        )
    }

    private func readSwapUsage() -> (used: UInt64?, total: UInt64?) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (nil, nil) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func readThermal(now: Date) -> ThermalReading {
        let state: ThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = .nominal
        case .fair: state = .fair
        case .serious: state = .serious
        case .critical: state = .critical
        @unknown default: state = .unavailable
        }

        var sensors = MMTemperatureSnapshot()
        let sensorQuerySucceeded = MMReadTemperatures(&sensors) != 0
        let hasSensors = sensors.soc_sensor_count > 0 || sensors.ssd_sensor_count > 0
        if sensorQuerySucceeded && hasSensors {
            recordSuccess("thermal-sensors", now: now)
        } else {
            recordFailure("thermal-sensors", now: now)
        }
        let socCelsius = sensorQuerySucceeded && sensors.soc_sensor_count > 0 && sensors.soc_average_celsius.isFinite
            ? sensors.soc_average_celsius
            : nil
        let hottestSoCCelsius = sensorQuerySucceeded && sensors.soc_sensor_count > 0 && sensors.soc_maximum_celsius.isFinite
            ? sensors.soc_maximum_celsius
            : nil
        let ssdCelsius = sensorQuerySucceeded && sensors.ssd_sensor_count > 0 && sensors.ssd_average_celsius.isFinite
            ? sensors.ssd_average_celsius
            : nil
        return ThermalReading(
            state: state,
            socCelsius: socCelsius,
            hottestSoCCelsius: hottestSoCCelsius,
            ssdCelsius: ssdCelsius,
            capturedAt: now
        )
    }

    private func readNetwork(now: Date) -> NetworkReading {
        let wifi: WiFiReading?
        if detailDemand == .network &&
            (wifiRefreshRequested || lastWiFiSampleAt == nil || now.timeIntervalSince(lastWiFiSampleAt!) >= samplingProfile.wifiInterval) {
            let refreshedWiFi = readWiFi(now: now)
            // A failed/ disconnected interface must not leave an old RSSI or
            // channel on screen. The next eligible attempt will repopulate it.
            if let refreshedWiFi, refreshedWiFi.isAvailable {
                wifi = refreshedWiFi
                recordSuccess("wifi", now: now)
            } else {
                wifi = nil
                recordFailure("wifi", now: now)
            }
            // Record failed attempts too. Otherwise a missing interface or a
            // denied CoreWLAN query is retried on every network tick.
            lastWiFiSampleAt = now
            wifiRefreshRequested = false
        } else {
            wifi = previousSnapshot.network.wifi
        }

        guard let counter = readNetworkCounter(now: now) else {
            recordFailure("network-read", now: now)
            previousNetworkCounter = nil
            return NetworkReading(
                uploadBytesPerSecond: previousSnapshot.network.uploadBytesPerSecond,
                downloadBytesPerSecond: previousSnapshot.network.downloadBytesPerSecond,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi,
                capturedAt: previousSnapshot.network.capturedAt,
                isStale: true
            )
        }
        recordSuccess("network-read", now: now)
        defer { previousNetworkCounter = counter }

        guard let previous = previousNetworkCounter, counter.interface != nil else {
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi,
                capturedAt: nil,
                isStale: false
            )
        }

        let elapsed = now.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0, previous.interface == counter.interface else {
            recordFailure("network-delta", now: now)
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi,
                capturedAt: nil,
                isStale: false
            )
        }

        // if_data exposes 32-bit byte counters. Wrapping subtraction preserves
        // traffic across the 4 GiB rollover instead of turning it into a
        // misleading zero-rate sample. A conservative physical-rate ceiling
        // rejects an interface reset that would otherwise look like a huge
        // wrapped transfer; the current counter becomes the new baseline.
        guard !networkCounterLooksReset(current: counter, previous: previous) else {
            recordFailure("network-delta", now: now)
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi,
                capturedAt: nil,
                isStale: false
            )
        }
        guard
            let sentDelta = boundedNetworkDelta(current: counter.sent, previous: previous.sent, elapsed: elapsed),
            let receivedDelta = boundedNetworkDelta(current: counter.received, previous: previous.received, elapsed: elapsed)
        else {
            recordFailure("network-delta", now: now)
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi,
                capturedAt: nil,
                isStale: false
            )
        }
        recordSuccess("network-delta", now: now)
        sessionUploadBytes &+= sentDelta
        sessionDownloadBytes &+= receivedDelta
        return NetworkReading(
            uploadBytesPerSecond: Double(sentDelta) / elapsed,
            downloadBytesPerSecond: Double(receivedDelta) / elapsed,
            sessionUploadBytes: sessionUploadBytes,
            sessionDownloadBytes: sessionDownloadBytes,
            wifi: wifi,
            capturedAt: now,
            isStale: false
        )
    }

    private func boundedNetworkDelta(current: UInt32, previous: UInt32, elapsed: TimeInterval) -> UInt64? {
        let delta = UInt64(current &- previous)
        // 2 GiB/s is above the throughput of supported consumer interfaces,
        // while still allowing a single 32-bit rollover between low-power
        // samples. Multiple rollovers cannot be recovered from if_data alone.
        let maximumBytes = 2.0 * 1024.0 * 1024.0 * 1024.0 * elapsed
        guard maximumBytes.isFinite, Double(delta) <= maximumBytes else { return nil }
        return delta
    }

    private func networkCounterLooksReset(current: NetworkCounter, previous: NetworkCounter) -> Bool {
        let nearZero = UInt32(256 * 1024 * 1024)
        let nearRollover = UInt32.max - nearZero
        func looksReset(_ now: UInt32, _ old: UInt32) -> Bool {
            now < old && now < nearZero && old < nearRollover
        }
        // A driver/interface reset normally drops both byte counters to a
        // small value. A genuine rollover drops from the end of UInt32, so it
        // remains distinguishable without discarding ordinary wrap traffic.
        return looksReset(current.sent, previous.sent) || looksReset(current.received, previous.received)
    }

    private func readWiFi(now: Date) -> WiFiReading? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = interface.rssiValue()
        return WiFiReading(
            // SSID access can require Location Services authorization. The UI
            // exposes signal and channel only, so avoid an unnecessary prompt.
            ssid: nil,
            // CoreWLAN reports zero when no association is available; treat it
            // as missing rather than displaying a plausible-looking signal.
            rssi: rssi == 0 ? nil : rssi,
            channel: interface.wlanChannel()?.channelNumber,
            capturedAt: now
        )
    }

    private func readNetworkCounter(now: Date) -> NetworkCounter? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        let primaryInterface = currentPrimaryPhysicalInterface()
        var fallback: NetworkCounter?
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }

            guard
                let namePointer = interface.ifa_name,
                let data = interface.ifa_data,
                let address = interface.ifa_addr,
                address.pointee.sa_family == sa_family_t(AF_LINK)
            else { continue }
            let name = String(cString: namePointer)
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            guard isUp, name.hasPrefix("en") else { continue }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let counter = NetworkCounter(
                received: UInt32(truncatingIfNeeded: stats.ifi_ibytes),
                sent: UInt32(truncatingIfNeeded: stats.ifi_obytes),
                interface: name,
                capturedAt: now
            )
            if name == primaryInterface {
                return counter
            }
            if fallback == nil {
                fallback = counter
            }
        }

        return fallback
    }

    private func currentPrimaryPhysicalInterface() -> String? {
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any] else { continue }
            guard let interface = value["PrimaryInterface"] as? String, interface.hasPrefix("en") else { continue }
            return interface
        }
        return nil
    }

}
