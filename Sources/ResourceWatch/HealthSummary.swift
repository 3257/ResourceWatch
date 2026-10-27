import Foundation

enum HealthSummary {
    static func warningDetails(_ m: Metrics, settings: WatchSettings) -> [String] {
        let active = Set(warnings(m, settings: settings))
        var lines: [String] = []
        if active.contains("High CPU") { lines.append(String(format: "CPU %.0f%% — above %.0f%%", m.cpu, settings.cpuPercent)) }
        if active.contains("Memory pressure") { lines.append(m.pressure >= 4 ? "Critical memory pressure" : "Elevated memory pressure") }
        let busy = m.processSamples.filter { $0.cpu >= settings.processCPUPercent }.sorted { $0.cpu > $1.cpu }
        for p in busy.prefix(2) { lines.append(String(format: "%@: %.0f%% CPU (one core = 100%%)", p.name, p.cpu)) }
        if busy.count > 2 { lines.append("\(busy.count - 2) more processes above CPU threshold") }
        let large = m.processSamples.filter { Double($0.memory) / Double(1 << 30) >= settings.processMemoryGiB }.sorted { $0.memory > $1.memory }
        for p in large.prefix(2) { lines.append(String(format: "%@: %.1f GiB memory footprint", p.name, Double(p.memory) / Double(1 << 30))) }
        if large.count > 2 { lines.append("\(large.count - 2) more processes above memory threshold") }
        if active.contains("Low storage") { lines.append(String(format: "Low storage: %.1f GB free (%.0f%%)", Double(m.free) / 1e9, Double(m.free) / Double(m.total) * 100)) }
        if active.contains("Heavy network traffic") { lines.append(String(format: "Network: ↓ %.1f / ↑ %.1f MB/s", m.network.download / 1e6, m.network.upload / 1e6)) }
        return lines
    }

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
