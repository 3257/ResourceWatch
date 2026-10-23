import Foundation

struct StorageTarget: Sendable {
    var name: String
    var path: String
    var advice: String
    var command: String?
    // Folders behind macOS privacy prompts; scanned only after the user starts a scan once.
    var protected = false
    var olderThanDays: Int?

    static let catalog: [StorageTarget] = [
        .init(name: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData",
              advice: "Xcode keeps build products, indexes and logs here for each project.\nDeleting it is safe. The next build of each project takes longer.\nQuit Xcode first, then delete the contents of the folder."),
        .init(name: "Xcode Archives", path: "Library/Developer/Xcode/Archives",
              advice: "Xcode keeps an archive of each build that you exported or uploaded.\nKeep archives of shipped builds if you need their symbols for crash reports.\nDelete old archives in Xcode → Window → Organizer."),
        .init(name: "iOS DeviceSupport", path: "Library/Developer/Xcode/iOS DeviceSupport", advice: deviceSupport),
        .init(name: "watchOS DeviceSupport", path: "Library/Developer/Xcode/watchOS DeviceSupport", advice: deviceSupport),
        .init(name: "tvOS DeviceSupport", path: "Library/Developer/Xcode/tvOS DeviceSupport", advice: deviceSupport),
        .init(name: "Simulator devices", path: "Library/Developer/CoreSimulator/Devices",
              advice: "Each simulator keeps its own apps, data and caches here.\nThe command removes only simulators whose runtime is no longer installed.\nRemove other simulators in Xcode → Window → Devices and Simulators.",
              command: "xcrun simctl delete unavailable"),
        .init(name: "Parallel testing simulator clones", path: "Library/Developer/XCTestDevices",
              advice: "Xcode clones simulators here to run tests in parallel. The clones are needed only while tests run.\nThe command deletes all clones. Xcode creates new ones for the next parallel test run.",
              command: "xcrun simctl --set testing delete all"),
        .init(name: "Swift Package Manager cache", path: "Library/Caches/org.swift.swiftpm",
              advice: "Swift Package Manager keeps downloaded package repositories here.\nDeleting it is safe. Xcode downloads the packages again on the next resolve, which is slow for large projects."),
        .init(name: "Xcode cache", path: "Library/Caches/com.apple.dt.Xcode",
              advice: "Xcode keeps download and documentation caches here.\nDeleting it is safe. Quit Xcode first."),
        .init(name: "Homebrew cache", path: "Library/Caches/Homebrew",
              advice: "Homebrew keeps the downloads of installed packages and old versions here.\nThe command removes all cached downloads and old versions.",
              command: "brew cleanup --prune=all"),
        .init(name: "CocoaPods cache", path: "Library/Caches/CocoaPods",
              advice: "CocoaPods keeps downloaded pods here.\nThe command empties the cache. CocoaPods downloads pods again on the next install.",
              command: "pod cache clean --all"),
        .init(name: "npm cache", path: ".npm",
              advice: "npm keeps downloaded packages here.\nThe command empties the cache. npm downloads packages again when needed.",
              command: "npm cache clean --force"),
        .init(name: "Gradle caches", path: ".gradle/caches",
              advice: "Gradle keeps downloaded dependencies and build caches here.\nDeleting it is safe when no Gradle build runs. The next build downloads dependencies again."),
        .init(name: "Trash", path: ".Trash", advice: "Files in the Trash still use disk space.\nEmpty the Trash in Finder to free it."),
        .init(name: "iPhone and iPad backups", path: "Library/Application Support/MobileSync/Backup",
              advice: "Finder keeps full backups of iPhones and iPads here.\nDelete old backups in Finder: select the device, then Manage Backups."),
        .init(name: "Old downloads", path: "Downloads",
              advice: "Top-level items in Downloads that did not change for 30 days.\nCheck the items and keep what you need before you delete the rest.",
              protected: true, olderThanDays: 30)
    ]
    private static let deviceSupport = "Xcode copies debug symbols here for each OS version of a device that you connect.\nDelete the folders of OS versions that you no longer debug. Xcode copies them again when needed."
}

struct StorageFinding: Equatable, Sendable {
    var id: String
    var title: String
    var path: String
    var bytes: Int64?
    var complete = true
    var detail: [String]
    var command: String?
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

    static func scan(_ targets: [StorageTarget] = StorageTarget.catalog, home: URL, projectFolders: [String] = [], includeProtected: Bool, now: Date = Date()) -> [StorageFinding] {
        let roots = projectFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData")
        let projects = DerivedDataReader.projects(in: derivedData)
        let developerFindings = WorktreeReader.findings(roots: roots, derivedData: projects, now: now) + [DerivedDataReader.orphans(projects, derivedData: derivedData)].compactMap { $0 }
        return developerFindings + targets.filter { includeProtected || !$0.protected }.compactMap { target in
            let url = home.appending(path: target.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let deadline = Date().addingTimeInterval(timeLimit)
            var size: (bytes: Int64, complete: Bool)
            var detail = target.advice.components(separatedBy: "\n")
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
