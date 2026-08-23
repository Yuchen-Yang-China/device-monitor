import Darwin
import Foundation

// Process enumeration is intentionally demand-driven. The menu bar monitor never needs a process list.
final class ProcessSampler: @unchecked Sendable {
    private struct ProcessState {
        let totalCPUTime: UInt64
        let name: String
        let memoryBytes: UInt64
    }

    private var previous: [Int32: ProcessState] = [:]
    private var previousDate: Date?

    func sample(at date: Date) -> (cpu: [ProcessUsage], memory: [ProcessUsage]) {
        let current = collectCurrentStates()
        defer {
            previous = current
            previousDate = date
        }

        let elapsed = date.timeIntervalSince(previousDate ?? date)
        let denominator = max(elapsed, 0.001) * 1_000_000_000
        var usages: [ProcessUsage] = []

        for (pid, state) in current {
            let priorTime = previous[pid]?.totalCPUTime ?? state.totalCPUTime
            let delta = state.totalCPUTime >= priorTime ? state.totalCPUTime - priorTime : 0
            let cpuPercent = min(800, max(0, Double(delta) / denominator * 100))
            usages.append(ProcessUsage(id: pid, name: state.name, cpuPercent: cpuPercent, memoryBytes: state.memoryBytes))
        }

        let topCPU = usages
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(3)
        let topMemory = usages
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(3)

        return (Array(topCPU), Array(topMemory))
    }

    private func collectCurrentStates() -> [Int32: ProcessState] {
        let pids = processIDs()
        var states: [Int32: ProcessState] = [:]
        states.reserveCapacity(pids.count)

        for pid in pids {
            var taskInfo = proc_taskinfo()
            let result = withUnsafeMutablePointer(to: &taskInfo) { pointer in
                proc_pidinfo(
                    pid,
                    PROC_PIDTASKINFO,
                    0,
                    pointer,
                    Int32(MemoryLayout<proc_taskinfo>.stride)
                )
            }
            guard result == MemoryLayout<proc_taskinfo>.stride else { continue }

            let name = processName(pid: pid)
            guard !name.isEmpty else { continue }
            states[pid] = ProcessState(
                totalCPUTime: taskInfo.pti_total_user + taskInfo.pti_total_system,
                name: name,
                memoryBytes: taskInfo.pti_resident_size
            )
        }
        return states
    }

    private func processIDs() -> [Int32] {
        var capacity = 4096
        for _ in 0..<3 {
            var pids = [Int32](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listallpids(rawBuffer.baseAddress, Int32(rawBuffer.count))
            }
            guard bytes > 0 else { return [] }
            // proc_listallpids returns the number of PIDs copied, not a byte count.
            let count = Int(bytes)
            if count < pids.count {
                return Array(pids.prefix(count))
            }
            capacity *= 2
        }
        return []
    }

    private func processName(pid: Int32) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = nameBuffer.withUnsafeMutableBytes { rawBuffer in
            proc_name(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        if nameLength > 0 {
            return String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0, let path = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            return ""
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
