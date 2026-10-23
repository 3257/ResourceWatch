import Foundation

struct WatchAlert: Equatable {
    var title: String
    var body: String
    var key = ""
}

struct AlertEngine {
    private var policy = AlertPolicy()
    private var diskHistory: [(Date, Int64)] = []
    private var lastSample: Date?
    private var previousSettings: WatchSettings?
    private(set) var storageGrowthActive = false

    mutating func evaluate(_ m: Metrics, settings: WatchSettings, now: Date) -> [WatchAlert] {
        var alertSettings = settings
        alertSettings.showMenuBarStats = false
        alertSettings.projectFolders = []
        if previousSettings != alertSettings || lastSample.map({ now.timeIntervalSince($0) > 30 || now < $0 }) == true {
            policy = AlertPolicy()
        }
        previousSettings = alertSettings; lastSample = now
        storageGrowthActive = false
        policy.cooldown = settings.cooldownMinutes * 60
        diskHistory.append((now, m.free))
        diskHistory.removeAll { now.timeIntervalSince($0.0) > 3600 }
        let gib = Double(1 << 30)
        var alerts: [WatchAlert] = []
        func check(_ key: String, _ active: Bool, _ duration: TimeInterval, _ title: String, _ body: String) {
            if policy.evaluate(key, active: active, now: now, sustained: duration) {
                alerts.append(WatchAlert(title: title, body: body, key: key))
            }
        }
        var keys: Set<String> = ["cpu", "memory", "disk", "growth", "network"]
        for p in m.processSamples {
            let cpuKey = "process-cpu-\(p.identity)", memoryKey = "process-memory-\(p.identity)"
            keys.formUnion([cpuKey, memoryKey])
            check(cpuKey, p.cpu >= settings.processCPUPercent, settings.sustainedSeconds,
                  "\(p.name) is using sustained CPU", "\(String(format: "%.0f", p.cpu))% CPU (100% = one core). PID \(p.identity.split(separator: ":")[0]).")
            check(memoryKey, Double(p.memory) / gib >= settings.processMemoryGiB, settings.sustainedSeconds,
                  "\(p.name) is using substantial memory", "Resident memory: \(String(format: "%.1f", Double(p.memory) / gib)) GiB. Check Activity Monitor before taking action.")
        }
        policy.retain(keys)
        check("cpu", m.cpu >= settings.cpuPercent, settings.sustainedSeconds,
              "Sustained high CPU", "CPU is \(String(format: "%.0f", m.cpu))% across all cores.\n\(m.processes)")
        check("memory", m.pressure >= 2, 30,
              "Memory pressure is high", "macOS reports memory pressure. Swap: \(String(format: "%.1f", Double(m.swap) / gib)) GiB.")
        check("network", max(m.network.download, m.network.upload) >= settings.networkMBPerSecond * 1e6, settings.sustainedSeconds,
              "Sustained heavy network traffic", "Download \(String(format: "%.1f", m.network.download / 1e6)) MB/s · Upload \(String(format: "%.1f", m.network.upload / 1e6)) MB/s on Wi-Fi/Ethernet.")
        check("disk", Double(m.free) < settings.diskFreeGB * 1e9 || Double(m.free) / Double(m.total) < settings.diskFreePercent / 100, 30,
              "Storage is running low", "Home volume has \(String(format: "%.1f", Double(m.free) / 1e9)) GB free.")
        if let first = diskHistory.first, now.timeIntervalSince(first.0) >= 300 {
            storageGrowthActive = Double(first.1 - m.free) > settings.diskGrowthGB * 1e9
            check("growth", storageGrowthActive, 0,
                  "Storage is growing quickly", "Free space dropped by over \(settings.diskGrowthGB.formatted()) GB within the last hour.")
        }
        return alerts
    }
}
