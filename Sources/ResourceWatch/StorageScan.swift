import Foundation

struct StorageTarget: Sendable {
    var name: String
    var path: String
    var advice: String
    var command: String?
    // Folders behind macOS privacy prompts; scanned only after the user starts a scan once.
    var protected = false
    var olderThanDays: Int?
    // Offers Move to Trash only for folders that their tools recreate; others need their own tool or a manual choice.
    var trashable = false
    var script: CleanupScript?

    static let catalog: [StorageTarget] = [
        .init(name: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData",
              advice: "Xcode keeps build products, indexes and logs here for each project.\nDeleting it is safe. The next build of each project takes longer.\n"
                + "Quit Xcode first, then delete the contents of the folder.\n"
                + "Each clone or worktree of a project gets its own folder here, with its own copy of every package. Keep few worktrees of large projects.\n"
                + "Command-line builds of checkouts with the same package versions can share one package copy: pass the same -clonedSourcePackagesDirPath to xcodebuild.",
              trashable: true,
              script: .devClean("dd-gone,dd-stale,dd-orphan", summary: "Lists DerivedData of deleted projects and of projects not opened for 30 days, then asks before it deletes each group.")),
        .init(name: "Xcode Archives", path: "Library/Developer/Xcode/Archives",
              advice: "Xcode keeps an archive of each build that you exported or uploaded.\nKeep archives of shipped builds if you need their symbols for crash reports.\n"
                + "Delete old archives in Xcode → Window → Organizer."),
        .init(name: "iOS DeviceSupport", path: "Library/Developer/Xcode/iOS DeviceSupport", advice: deviceSupport, trashable: true, script: deviceSupportScript),
        .init(name: "watchOS DeviceSupport", path: "Library/Developer/Xcode/watchOS DeviceSupport", advice: deviceSupport, trashable: true, script: deviceSupportScript),
        .init(name: "tvOS DeviceSupport", path: "Library/Developer/Xcode/tvOS DeviceSupport", advice: deviceSupport, trashable: true, script: deviceSupportScript),
        .init(name: "Simulator devices", path: "Library/Developer/CoreSimulator/Devices",
              advice: "Each simulator keeps its own apps, data and caches here.\nThe command removes only simulators whose runtime is no longer installed.\n"
                + "Remove other simulators in Xcode → Window → Devices and Simulators.",
              command: "xcrun simctl delete unavailable",
              script: .devClean("sims,runtimes", summary: "Lists simulators that are unavailable or not booted for 30 days, and runtimes no simulator uses, then asks before it deletes each group.")),
        .init(name: "Parallel testing simulator clones", path: "Library/Developer/XCTestDevices",
              advice: "Xcode clones simulators here to run tests in parallel. The clones are needed only while tests run.\n"
                + "Xcode makes one clone for each parallel test runner. To make fewer clones, pass -maximum-parallel-testing-workers to xcodebuild test.\n"
                + "The command deletes all clones. Xcode creates new ones for the next parallel test run.",
              command: "xcrun simctl --set testing delete all",
              script: .devClean("xctest", summary: "Shows how many clones there are and the space only they use, then asks before it deletes them all.")),
        .init(name: "Swift Package Manager cache", path: "Library/Caches/org.swift.swiftpm",
              advice: "Swift Package Manager keeps downloaded package repositories here.\n"
                + "Deleting it is safe. Xcode downloads the packages again on the next resolve, which is slow for large projects.", trashable: true,
              script: .devClean("spm", summary: "Shows the size of the Swift Package Manager cache, then asks before it empties the cache.")),
        .init(name: "Xcode cache", path: "Library/Caches/com.apple.dt.Xcode",
              advice: "Xcode keeps download and documentation caches here.\nDeleting it is safe. Quit Xcode first.", trashable: true),
        .init(name: "Homebrew cache", path: "Library/Caches/Homebrew",
              advice: "Homebrew keeps the downloads of installed packages and old versions here.\nThe command removes all cached downloads and old versions.",
              command: "brew cleanup --prune=all", trashable: true),
        .init(name: "CocoaPods cache", path: "Library/Caches/CocoaPods",
              advice: "CocoaPods keeps downloaded pods here.\nThe command empties the cache. CocoaPods downloads pods again on the next install.",
              command: "pod cache clean --all", trashable: true),
        .init(name: "npm cache", path: ".npm",
              advice: "npm keeps downloaded packages here.\nThe command empties the cache. npm downloads packages again when needed.",
              command: "npm cache clean --force", trashable: true),
        .init(name: "Gradle caches", path: ".gradle/caches",
              advice: "Gradle keeps downloaded dependencies and build caches here.\nDeleting it is safe when no Gradle build runs. The next build downloads dependencies again.", trashable: true),
        .init(name: "Tart virtual machines", path: ".tart",
              advice: "Tart keeps local virtual machines in vms and downloaded base images in cache.\n" + vmGrowth
                + "Delete a VM that you no longer need with tart delete <name>. The command removes base images that Tart did not use for 7 days.",
              command: "tart prune --entries caches --older-than 7"),
        .init(name: "Parallels virtual machines", path: "Parallels",
              advice: "Parallels Desktop keeps virtual machines here by default.\n" + vmGrowth + "Remove virtual machines that you no longer need in Parallels Desktop."),
        .init(name: "OrbStack data", path: "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
              advice: "OrbStack keeps containers, images, volumes and Linux machines in one disk image here. The image shrinks when you delete data in OrbStack.\n"
                + "The command asks, then removes stopped containers, unused networks, dangling images and unused build cache.",
              command: "docker system prune", protected: true),
        .init(name: "Trash", path: ".Trash", advice: "Files in the Trash still use disk space.\nEmpty the Trash in Finder to free it."),
        .init(name: "iPhone and iPad backups", path: "Library/Application Support/MobileSync/Backup",
              advice: "Finder keeps full backups of iPhones and iPads here.\nDelete old backups in Finder: select the device, then Manage Backups."),
        .init(name: "Old downloads", path: "Downloads",
              advice: "Top-level items in Downloads that did not change for 30 days.\nCheck the items and keep what you need before you delete the rest.",
              protected: true, olderThanDays: 30)
    ]
    private static let deviceSupportScript = CleanupScript.devClean("devsupport", summary: "Lists DeviceSupport folders not changed for 30 days, then asks before it deletes them.")
    private static let vmGrowth = "A disk image grows as the virtual machine writes to it, so free space can drop while no other file changes.\n"
    private static let deviceSupport = "Xcode copies debug symbols here for each OS version of a device that you connect.\n"
        + "Delete the folders of OS versions that you no longer debug. Xcode copies them again when needed."
}

struct StorageFinding: Equatable, Sendable {
    var id: String
    var title: String
    var path: String
    var bytes: Int64?
    var complete = true
    var detail: [String]
    var command: String?
    var trash: [String] = []
    var script: CleanupScript?
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

    struct Size {
        /// Blocks that no other file shares, so deleting the item frees at least this much.
        var bytes: Int64 = 0
        var complete = true
        /// The rest of the allocated size: APFS clones, such as simulator test clones, share blocks with their source.
        var shared: Int64 = 0
    }

    static func allocatedSize(_ url: URL, deadline: Date) -> Size {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return Size() }
        guard values.isDirectory == true else {
            let allocated = Int64(values.totalFileAllocatedSize ?? 0), own = values.isRegularFile == true ? privateSize(url.path) ?? allocated : allocated
            return Size(bytes: own, shared: allocated - own)
        }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return Size() }
        var size = Size(), count = 0
        for case let item as URL in items {
            count += 1
            if count.isMultiple(of: 2_000), Date() > deadline {
                size.complete = false
                return size
            }
            guard let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
            let allocated = Int64(values.totalFileAllocatedSize ?? 0), own = values.isRegularFile == true ? privateSize(item.path) ?? allocated : allocated
            size.bytes += own
            size.shared += allocated - own
        }
        return size
    }

    /// The bytes of a file that no clone shares, or nil where the volume does not report it (not APFS).
    static func privateSize(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 16)
        let status = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) }
        // The kernel packs the reply at 4-byte alignment: a UInt32 length, then the off_t.
        return status == 0 ? buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) } : nil
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
            var size: Size
            var detail = target.advice.components(separatedBy: "\n")
            if let days = target.olderThanDays {
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                let old = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now) < cutoff
                }
                size = old.reduce(Size()) { sum, item in
                    let part = allocatedSize(item, deadline: deadline)
                    return Size(bytes: sum.bytes + part.bytes, complete: sum.complete && part.complete, shared: sum.shared + part.shared)
                }
                detail.append("\(old.count) item\(old.count == 1 ? "" : "s")")
            } else {
                size = allocatedSize(url, deadline: deadline)
            }
            if size.shared >= 1_000_000_000 {
                detail.append("Another \(StorageAdvisor.format(size.shared)) is shared with copies, such as simulator test clones. "
                              + "Deleting this folder frees that space only when the copies are gone too.")
            }
            return StorageFinding(id: target.path, title: target.name, path: url.path, bytes: size.bytes, complete: size.complete, detail: detail, command: target.command,
                                  trash: target.trashable ? [url.path] : [], script: target.script)
        }
    }
}

enum TrashPolicy {
    /// Only folders at least two levels below home qualify, never home itself or a direct child such as ~/Downloads.
    static func allows(_ paths: [String], home: String = NSHomeDirectory()) -> Bool {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return !paths.isEmpty && paths.allSatisfy { path in
            let standardized = (path as NSString).standardizingPath
            return standardized.hasPrefix(prefix) && standardized.dropFirst(prefix.count).split(separator: "/").count >= 2
        }
    }
}

enum StorageAdvisor {
    static func advice(_ findings: [StorageFinding], minimumBytes: Int64 = 1_000_000_000) -> [Recommendation] {
        findings.filter { $0.bytes.map { $0 >= minimumBytes } ?? true }
            .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            .map { finding in
                let size = finding.bytes.map { (finding.complete ? "" : "at least ") + format($0) }
                let title = size.map { "\(finding.title) — \($0)" } ?? finding.title
                let actions: [Recommendation.Action] = [.reveal(finding.path)] + (finding.command.map { [.copy($0)] } ?? []) + (finding.script.map { [.runScript($0)] } ?? [])
                    + (finding.trash.isEmpty ? [] : [.moveToTrash(title: title, paths: finding.trash)])
                return Recommendation(id: "storage-\(finding.id)", title: title,
                                      detail: finding.detail + [(finding.path as NSString).abbreviatingWithTildeInPath] + Advisor.commandLines(actions),
                                      bytes: finding.bytes, actions: actions)
            }
    }

    static func format(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
}
