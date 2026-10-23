import Foundation

struct WatchSettings: Codable, Equatable {
    var cpuPercent = 85.0
    var processCPUPercent = 150.0
    var processMemoryGiB = 8.0
    var diskFreeGB = 20.0
    var diskFreePercent = 10.0
    var diskGrowthGB = 10.0
    var sustainedSeconds = 60.0
    var cooldownMinutes = 15.0
    var networkMBPerSecond = 25.0
    var showMenuBarStats = false
    var projectFolders = ["~/WorkProjects", "~/PlayProjects"]
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "watchSettings"),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseline = try? JSONEncoder().encode(Self()),
              let fields = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: fields.merging(saved, uniquingKeysWith: { _, saved in saved })),
              let value = try? JSONDecoder().decode(Self.self, from: merged) else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "watchSettings") }
    }
}
