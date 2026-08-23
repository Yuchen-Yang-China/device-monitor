import Darwin
import CoreWLAN
import Foundation
import SensorBridge
import SystemConfiguration

// All mutable sampling state is confined to samplingQueue. UI updates are dispatched to the main actor.
final class SystemMonitor: @unchecked Sendable {
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
    }

    private struct NetworkCounter {
        let received: UInt64
        let sent: UInt64
        let interface: String?
        let capturedAt: Date
    }

    private let store: MonitorStore
    private let samplingQueue = DispatchQueue(label: "com.macmonitor.sampling", qos: .utility)
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
    private var memoryPressureUntil: Date?
    private var memoryPressureLevel: MetricLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var detailDemand: MetricKind?
    private var processRefreshRequested = false
    private var wifiRefreshRequested = false
    private let processSampler = ProcessSampler()
    private var sessionUploadBytes: UInt64 = 0
    private var sessionDownloadBytes: UInt64 = 0
    private var coreTopology: (performance: Int, efficiency: Int, isHybrid: Bool)?

    init(store: MonitorStore, profile: SamplingProfile = .balanced) {
        self.store = store
        self.samplingProfile = profile
    }

    func start() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.installMemoryPressureObserver()
            self.sample()
            self.scheduleTimer()
        }
    }

    func stop() {
        samplingQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.memoryPressureSource?.cancel()
            self?.memoryPressureSource = nil
        }
    }

    func setDetailDemand(_ demand: MetricKind?) {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.detailDemand = demand
            if demand == nil {
                self.processRefreshRequested = false
                self.wifiRefreshRequested = false
            }
            if demand == .cpu || demand == .memory {
                self.processRefreshRequested = true
            }
            if demand == .network {
                self.wifiRefreshRequested = true
            }
        }
    }

    func setSamplingProfile(_ profile: SamplingProfile) {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.samplingProfile = profile
            self.scheduleTimer()
        }
    }

    func resetNetworkTotals() {
        samplingQueue.async { [weak self] in
            self?.sessionUploadBytes = 0
            self?.sessionDownloadBytes = 0
        }
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
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: samplingQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let level: MetricLevel = source.data.contains(.critical) ? .critical : .elevated
            self.memoryPressureLevel = level
            self.memoryPressureUntil = Date().addingTimeInterval(15)
        }
        memoryPressureSource = source
        source.resume()
    }

    private func sample() {
        let now = Date()
        var snapshot = previousSnapshot
        snapshot.capturedAt = now

        let shouldSampleSystem = lastSystemSampleAt == nil || now.timeIntervalSince(lastSystemSampleAt!) >= samplingProfile.systemInterval
        let shouldSampleThermal = lastThermalSampleAt == nil || now.timeIntervalSince(lastThermalSampleAt!) >= samplingProfile.thermalInterval
        let shouldSampleNetwork = lastNetworkSampleAt == nil || now.timeIntervalSince(lastNetworkSampleAt!) >= samplingProfile.networkInterval

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
            (processRefreshRequested || lastProcessSampleAt == nil || now.timeIntervalSince(lastProcessSampleAt!) >= 10) {
            let processUsage = processSampler.sample(at: now)
            snapshot.topCPUProcesses = processUsage.cpu
            snapshot.topMemoryProcesses = processUsage.memory
            snapshot.processSampledAt = now
            processRefreshRequested = false
            lastProcessSampleAt = now
        }

        if shouldSampleNetwork {
            snapshot.network = readNetwork(now: now)
            lastNetworkSampleAt = now
        }
        previousSnapshot = snapshot

        DispatchQueue.main.async { [weak self] in
            self?.store.apply(snapshot)
        }
    }

    private func readCPU(now: Date) -> CPUReading {
        guard let ticks = readCPUTicks() else {
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

        let totalDelta = ticks.total >= previous.total ? ticks.total - previous.total : 0
        let idleDelta = ticks.idle >= previous.idle ? ticks.idle - previous.idle : 0
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

        let userDelta = ticks.user >= previous.user ? ticks.user - previous.user : 0
        let systemDelta = ticks.system >= previous.system ? ticks.system - previous.system : 0
        let niceDelta = ticks.nice >= previous.nice ? ticks.nice - previous.nice : 0
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

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)

        for index in 0..<Int(processorCount) {
            let offset = index * stride
            user += UInt64(processorInfo[offset + Int(CPU_STATE_USER)])
            system += UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            nice += UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
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

        let pageSize = UInt64(getpagesize())
        let usedPages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * pageSize
        let wiredBytes = UInt64(statistics.wire_count) * pageSize
        let compressedBytes = UInt64(statistics.compressor_page_count) * pageSize
        let cachedBytes = UInt64(statistics.external_page_count) * pageSize
        let swap = readSwapUsage()
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let ratio = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0

        let level: MetricLevel
        if let until = memoryPressureUntil, until > now {
            level = memoryPressureLevel
        } else if ratio >= 0.90 {
            level = .critical
        } else if ratio >= 0.75 {
            level = .elevated
        } else {
            level = .normal
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
            (wifiRefreshRequested || lastWiFiSampleAt == nil || now.timeIntervalSince(lastWiFiSampleAt!) >= 30) {
            let refreshedWiFi = readWiFi(now: now)
            wifi = refreshedWiFi ?? previousSnapshot.network.wifi
            if refreshedWiFi != nil {
                lastWiFiSampleAt = now
            }
            wifiRefreshRequested = false
        } else {
            wifi = previousSnapshot.network.wifi
        }

        guard let counter = readNetworkCounter(now: now) else {
            return NetworkReading(
                uploadBytesPerSecond: previousSnapshot.network.uploadBytesPerSecond,
                downloadBytesPerSecond: previousSnapshot.network.downloadBytesPerSecond,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi
            )
        }
        defer { previousNetworkCounter = counter }

        guard let previous = previousNetworkCounter, counter.interface != nil else {
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi
            )
        }

        let elapsed = now.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0, previous.interface == counter.interface else {
            return NetworkReading(
                uploadBytesPerSecond: nil,
                downloadBytesPerSecond: nil,
                sessionUploadBytes: sessionUploadBytes,
                sessionDownloadBytes: sessionDownloadBytes,
                wifi: wifi
            )
        }

        let sentDelta = counter.sent >= previous.sent ? counter.sent - previous.sent : 0
        let receivedDelta = counter.received >= previous.received ? counter.received - previous.received : 0
        sessionUploadBytes += sentDelta
        sessionDownloadBytes += receivedDelta
        return NetworkReading(
            uploadBytesPerSecond: Double(sentDelta) / elapsed,
            downloadBytesPerSecond: Double(receivedDelta) / elapsed,
            sessionUploadBytes: sessionUploadBytes,
            sessionDownloadBytes: sessionDownloadBytes,
            wifi: wifi
        )
    }

    private func readWiFi(now: Date) -> WiFiReading? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return WiFiReading(
            ssid: interface.ssid(),
            rssi: interface.rssiValue(),
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
                received: UInt64(stats.ifi_ibytes),
                sent: UInt64(stats.ifi_obytes),
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

        return fallback ?? NetworkCounter(received: 0, sent: 0, interface: nil, capturedAt: now)
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
