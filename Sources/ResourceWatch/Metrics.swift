import Foundation
import Darwin

struct Metrics: Sendable {
    var cpu: Double
    var pressure: Int
    var swap: UInt64
    var free: Int64
    var total: Int64
    var processes: String
    var processSamples: [ProcessSample] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var compressed: UInt64 = 0
    var wired: UInt64 = 0
    var network = NetworkMetrics()
}

struct ProcessSample: Equatable, Sendable {
    var identity: String
    var name: String
    var cpu: Double
    var memory: UInt64
    var pid: Int32 = 0
    var parentPID: Int32 = 0
}

final class Sampler {
    private let memoryFootprint: (Int32) -> UInt64?
    private var previous: [UInt64]?
    private var processTimes: [String: UInt64] = [:]
    private var lastTime: TimeInterval?
    private var networkTracker = NetworkTracker()

    init(memoryFootprint: @escaping (Int32) -> UInt64? = processMemoryFootprint) {
        self.memoryFootprint = memoryFootprint
    }

    func sample() throws -> Metrics {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        let delta = zip(ticks, previous ?? ticks).map { $0 >= $1 ? $0 - $1 : 0 }
        previous = ticks
        let sum = delta.reduce(0, +)
        let cpu = sum > 0 ? 100 * Double(sum - delta[2]) / Double(sum) : 0
        // Darwin's pressure-level flags: normal=1, warning=2, critical=4.
        var pressure: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 else { throw CocoaError(.featureUnsupported) }
        var swap = xsw_usage(); size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { throw CocoaError(.featureUnsupported) }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
        let pageSize = UInt64(getpagesize())
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        let appPages = UInt64(vm.internal_page_count) > UInt64(vm.purgeable_count) ? UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) : 0
        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let memoryUsed = min(memoryTotal, appPages * pageSize + wired + compressed)
        let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        guard let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { throw CocoaError(.fileReadUnknown) }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTime.map { now - $0 } ?? 0
        let network = networkTracker.update(try networkCounters(), elapsed: elapsed)
        let samples = processSamples(elapsed: elapsed)
        lastTime = now
        let top = samples.sorted { $0.cpu > $1.cpu }.prefix(5).map { p in
            "\(p.name) · PID \(p.identity.split(separator: ":")[0]) · \(String(format: "%.0f", p.cpu))% CPU · \(p.memory / 1048576) MiB"
        }.joined(separator: "\n")
        return Metrics(cpu: cpu, pressure: Int(pressure), swap: swap.xsu_used, free: Int64(free), total: Int64(total), processes: top, processSamples: samples,
                       memoryUsed: memoryUsed, memoryTotal: memoryTotal, compressed: compressed, wired: wired, network: network)
    }

    private func processSamples(elapsed: TimeInterval) -> [ProcessSample] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        var pids = [Int32](repeating: 0, count: max(4096, Int(proc_listallpids(nil, 0)) + 1024))
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let number = proc_listallpids(&pids, bytes)
        var samples: [ProcessSample] = [], next: [String: UInt64] = [:]
        for pid in pids.prefix(max(0, min(Int(number), pids.count))) where pid > 0 {
            var all = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, size) == size,
                  let footprint = memoryFootprint(pid) else { continue }
            let identity = "\(pid):\(all.pbsd.pbi_start_tvsec):\(all.pbsd.pbi_start_tvusec)"
            let time = all.ptinfo.pti_total_user + all.ptinfo.pti_total_system
            next[identity] = time
            let usage: Double
            if let old = processTimes[identity], elapsed > 0, time >= old {
                usage = Double(time - old) * nanosecondsPerTick / 1e9 / elapsed * 100
            } else { usage = 0 }
            var name = [CChar](repeating: 0, count: 1024)
            _ = proc_name(pid, &name, UInt32(name.count))
            let decodedName = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            samples.append(ProcessSample(identity: identity, name: decodedName.isEmpty ? "PID \(pid)" : decodedName, cpu: usage,
                                         memory: footprint, pid: pid, parentPID: Int32(bitPattern: all.pbsd.pbi_ppid)))
        }
        processTimes = next
        return samples
    }
}

/// Kernel-charged footprint includes compressed memory, unlike RSS, which repeats shared clean pages across processes.
func processMemoryFootprint(_ pid: Int32) -> UInt64? {
    var usage = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
}

final class SamplingWorker: @unchecked Sendable {
    // Queue exclusively owns the sampler and serializes all mutable sampling state.
    private let queue = DispatchQueue(label: "ResourceWatch.sampling", qos: .utility)
    private let sampler = Sampler()
    func sample() async throws -> Metrics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.sampler.sample() }) }
        }
    }
}
