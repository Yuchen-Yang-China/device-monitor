import Darwin
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
    private var sampleCount = 0
    private var previousCPUTicks: CPUTicks?
    private var previousNetworkCounter: NetworkCounter?
    private var previousSnapshot = SystemSnapshot.initial
    private var memoryPressureUntil: Date?
    private var memoryPressureLevel: MetricLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(store: MonitorStore) {
        self.store = store
    }

    func start() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.installMemoryPressureObserver()
            self.sample()

            let timer = DispatchSource.makeTimerSource(queue: self.samplingQueue)
            timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
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
        sampleCount += 1
        let now = Date()
        var snapshot = previousSnapshot
        snapshot.capturedAt = now

        if sampleCount == 1 || sampleCount.isMultiple(of: 5) {
            snapshot.cpu = readCPU(now: now)
            snapshot.memory = readMemory(now: now)
        }

        if sampleCount == 1 || sampleCount.isMultiple(of: 15) {
            snapshot.thermal = readThermal(now: now)
        }

        snapshot.network = readNetwork(now: now)
        previousSnapshot = snapshot

        DispatchQueue.main.async { [weak self] in
            self?.store.apply(snapshot)
        }
    }

    private func readCPU(now: Date) -> CPUReading {
        guard let ticks = readCPUTicks() else {
            return CPUReading(utilization: previousSnapshot.cpu.utilization, level: .stale, capturedAt: previousSnapshot.cpu.capturedAt)
        }
        defer { previousCPUTicks = ticks }

        guard let previous = previousCPUTicks else {
            return CPUReading(utilization: nil, level: .sampling, capturedAt: nil)
        }

        let totalDelta = ticks.total >= previous.total ? ticks.total - previous.total : 0
        let idleDelta = ticks.idle >= previous.idle ? ticks.idle - previous.idle : 0
        guard totalDelta > 0 else {
            return CPUReading(utilization: previousSnapshot.cpu.utilization, level: .stale, capturedAt: previousSnapshot.cpu.capturedAt)
        }

        let utilization = min(100, max(0, (1 - Double(idleDelta) / Double(totalDelta)) * 100))
        let level: MetricLevel
        if utilization >= 90 {
            level = .critical
        } else if utilization >= 65 {
            level = .elevated
        } else {
            level = .normal
        }
        return CPUReading(utilization: utilization, level: level, capturedAt: now)
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
                level: .stale,
                capturedAt: previousSnapshot.memory.capturedAt
            )
        }

        let pageSize = UInt64(getpagesize())
        let usedPages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * pageSize
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

        return MemoryReading(usedBytes: usedBytes, totalBytes: totalBytes, level: level, capturedAt: now)
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
        guard let counter = readNetworkCounter(now: now) else {
            return NetworkReading(
                uploadBytesPerSecond: previousSnapshot.network.uploadBytesPerSecond,
                downloadBytesPerSecond: previousSnapshot.network.downloadBytesPerSecond
            )
        }
        defer { previousNetworkCounter = counter }

        guard let previous = previousNetworkCounter, counter.interface != nil else {
            return NetworkReading(uploadBytesPerSecond: nil, downloadBytesPerSecond: nil)
        }

        let elapsed = now.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0, previous.interface == counter.interface else {
            return NetworkReading(uploadBytesPerSecond: nil, downloadBytesPerSecond: nil)
        }

        let sentDelta = counter.sent >= previous.sent ? counter.sent - previous.sent : 0
        let receivedDelta = counter.received >= previous.received ? counter.received - previous.received : 0
        return NetworkReading(
            uploadBytesPerSecond: Double(sentDelta) / elapsed,
            downloadBytesPerSecond: Double(receivedDelta) / elapsed
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
