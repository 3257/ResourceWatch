import Foundation

struct StorageTarget: Sendable {
    var name: String
    var path: String
    var advice: String
    var command: String? = nil
    // Folders behind macOS privacy prompts; scanned only after the user starts a scan once.
    var protected = false
    var olderThanDays: Int? = nil

    static let catalog: [StorageTarget] = [
        .init(name: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData", advice: "Build products and indexes. Xcode rebuilds them when needed."),
        .init(name: "Xcode Archives", path: "Library/Developer/Xcode/Archives", advice: "Keep archives of shipped builds that you may need to symbolicate."),
        .init(name: "iOS DeviceSupport", path: "Library/Developer/Xcode/iOS DeviceSupport", advice: "Symbols for device OS versions. Xcode copies them again when you reconnect a device."),
        .init(name: "watchOS DeviceSupport", path: "Library/Developer/Xcode/watchOS DeviceSupport", advice: "Symbols for device OS versions. Xcode copies them again when you reconnect a device."),
        .init(name: "tvOS DeviceSupport", path: "Library/Developer/Xcode/tvOS DeviceSupport", advice: "Symbols for device OS versions. Xcode copies them again when you reconnect a device."),
        .init(name: "Simulator devices", path: "Library/Developer/CoreSimulator/Devices", advice: "Remove simulators whose runtime is no longer installed.", command: "xcrun simctl delete unavailable"),
        .init(name: "Swift Package Manager cache", path: "Library/Caches/org.swift.swiftpm", advice: "Downloaded package sources. Xcode downloads them again when needed."),
        .init(name: "Xcode cache", path: "Library/Caches/com.apple.dt.Xcode", advice: "Xcode recreates this cache."),
        .init(name: "Homebrew cache", path: "Library/Caches/Homebrew", advice: "Old downloads of installed formulae.", command: "brew cleanup --prune=all"),
        .init(name: "CocoaPods cache", path: "Library/Caches/CocoaPods", advice: "CocoaPods downloads pods again when needed.", command: "pod cache clean --all"),
        .init(name: "npm cache", path: ".npm", advice: "npm downloads packages again when needed.", command: "npm cache clean --force"),
        .init(name: "Gradle caches", path: ".gradle/caches", advice: "Gradle downloads dependencies again when needed."),
        .init(name: "Trash", path: ".Trash", advice: "Empty the Trash in Finder to free this space."),
        .init(name: "iPhone and iPad backups", path: "Library/Application Support/MobileSync/Backup", advice: "Delete old backups in Finder: select the device, then Manage Backups."),
        .init(name: "Old downloads", path: "Downloads", advice: "Top-level items in Downloads unchanged for 30 days.", protected: true, olderThanDays: 30),
    ]
}

struct StorageFinding: Equatable, Sendable {
    var id: String
    var title: String
    var path: String
    var bytes: Int64?
    var complete = true
    var detail: [String]
    var command: String? = nil
}

enum ScanTrigger: Sendable { case manual, daily, storageAlert }

enum ScanSchedule {
    static func due(last: Date?, now: Date, trigger: ScanTrigger) -> Bool {
        guard let last, now >= last else { return true }
        switch trigger {
        case .manual: return true
        case .daily: return now.timeIntervalSince(last) >= 86_400
        case .storageAlert: return now.timeIntervalSince(last) >= 3_600
        }
    }
}

enum StorageScanner {
    static let timeLimit: TimeInterval = 20

    static func allocatedSize(_ url: URL, deadline: Date) -> (bytes: Int64, complete: Bool) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return (0, true) }
        guard values.isDirectory == true else { return (Int64(values.totalFileAllocatedSize ?? 0), true) }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return (0, true) }
        var total: Int64 = 0, count = 0
        for case let item as URL in items {
            count += 1
            if count.isMultiple(of: 2_000), Date() > deadline { return (total, false) }
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return (total, true)
    }

    static func scan(_ targets: [StorageTarget] = StorageTarget.catalog, home: URL, includeProtected: Bool, now: Date = Date()) -> [StorageFinding] {
        targets.filter { includeProtected || !$0.protected }.compactMap { target in
            let url = home.appending(path: target.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let deadline = Date().addingTimeInterval(timeLimit)
            var size: (bytes: Int64, complete: Bool)
            var detail = [target.advice]
            if let days = target.olderThanDays {
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                let old = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now) < cutoff
                }
                size = old.reduce((0, true)) { sum, item in
                    let part = allocatedSize(item, deadline: deadline)
                    return (sum.0 + part.bytes, sum.1 && part.complete)
                }
                detail.append("\(old.count) item\(old.count == 1 ? "" : "s")")
            } else {
                size = allocatedSize(url, deadline: deadline)
            }
            return StorageFinding(id: target.path, title: target.name, path: url.path, bytes: size.bytes, complete: size.complete, detail: detail, command: target.command)
        }
    }
}

enum StorageAdvisor {
    static func advice(_ findings: [StorageFinding], minimumBytes: Int64 = 1_000_000_000) -> [Recommendation] {
        findings.filter { $0.bytes.map { $0 >= minimumBytes } ?? true }
            .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            .map { finding in
                let size = finding.bytes.map { (finding.complete ? "" : "at least ") + format($0) }
                let actions: [Recommendation.Action] = [.reveal(finding.path)] + (finding.command.map { [.copy($0)] } ?? [])
                return Recommendation(id: "storage-\(finding.id)", title: size.map { "\(finding.title) — \($0)" } ?? finding.title,
                                      detail: finding.detail + [(finding.path as NSString).abbreviatingWithTildeInPath] + Advisor.commandLines(actions),
                                      bytes: finding.bytes, actions: actions)
            }
    }

    static func format(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
}
