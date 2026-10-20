import Foundation

enum HealthSummary {
    static func warnings(_ m: Metrics, settings: WatchSettings) -> [String] {
        var result: [String] = []
        if m.cpu >= settings.cpuPercent { result.append("High CPU") }
        if m.pressure >= 2 { result.append("Memory pressure") }
        if m.processSamples.contains(where: { $0.cpu >= settings.processCPUPercent }) { result.append("Busy process") }
        if m.processSamples.contains(where: { Double($0.memory) / Double(1 << 30) >= settings.processMemoryGiB }) { result.append("Large process memory") }
        if m.total > 0, Double(m.free) < settings.diskFreeGB * 1e9 || Double(m.free) / Double(m.total) * 100 < settings.diskFreePercent { result.append("Low storage") }
        if max(m.network.download, m.network.upload) >= settings.networkMBPerSecond * 1e6 { result.append("Heavy network traffic") }
        return result
    }
}
