import CoreServices
import Foundation

struct GrowthEntry: Equatable, Sendable {
    var path: String
    var bytes: Int64
    var changes: Int
    var measured = true
    var sizeUnclear = false
}

struct GrowthReport: Equatable, Sendable {
    var entries: [GrowthEntry] = []
    var unmeasured: [GrowthEntry] = []
    var total: Int64 = 0
    var shrunk: Int64 = 0
    var incomplete = false
    var sizeUnclear = false

    /// Marks sizes that free space cannot explain. Growth in one folder can exceed the drop in free space only by what other folders freed;
    /// the factor and the 1 GB allow for purgeable space and snapshots. A larger number comes from a counting error, not from the disk.
    func checked(freeSpaceDrop: Int64) -> GrowthReport {
        let limit = 2 * (max(0, freeSpaceDrop) + shrunk) + 1_000_000_000
        var report = self
        for index in report.entries.indices where report.entries[index].bytes > limit { report.entries[index].sizeUnclear = true }
        report.sizeUnclear = total > limit
        return report
    }
}

/// Attributes file-size changes to folders under home, per minute, for a rolling window.
struct GrowthLedger {
    enum Change: Equatable { case created(Int64), modified(Int64), removed, unmeasured }

    let home: String
    var maxDepth = 8
    var maxFiles = 300_000
    var lastDrop: Date?
    private struct Bucket {
        var bytes: Int64 = 0
        var changes = 0
    }
    private var sizes: [String: Int64] = [:]
    // Per minute, growth of each file's own folder only; the report rolls it up to parent folders.
    private var minutes: [Int: [String: Bucket]] = [:]
    private var protectedChanges: [Int: [String: Int]] = [:]

    init(home: String) { self.home = home.hasSuffix("/") ? String(home.dropLast()) : home }

    var trackedFiles: Int { sizes.count }

    mutating func record(_ path: String, _ change: Change, at date: Date) {
        guard path.hasPrefix(home + "/") else { return }
        let minute = Int(date.timeIntervalSince1970 / 60)
        if change == .unmeasured { return recordProtected(path, minute: minute) }
        let known = sizes[path]
        var delta: Int64 = 0
        switch change {
        case .created(let size):
            // Also a file moved in. FSEvents does not pair the two names of a move, so the old name counts as removed and the new one as created.
            // A file past the limit is not counted: its removal could not be subtracted, so create-and-delete churn would only add up.
            delta = remember(path, size, at: date) ? size - (known ?? 0) : 0
        case .modified(let size):
            // The first sight of an existing file only sets a baseline, so a large file that grows a little does not count in full.
            delta = known.map { size - $0 } ?? 0
            remember(path, size, at: date)
        case .removed:
            delta = -(known ?? 0)
            sizes[path] = nil
        case .unmeasured:
            break
        }
        guard let folder = folder(of: path) else { return }
        minutes[minute, default: [:]][folder, default: Bucket()].changes += 1
        minutes[minute, default: [:]][folder, default: Bucket()].bytes += delta
    }

    mutating func prune(before date: Date) {
        let oldest = Int(date.timeIntervalSince1970 / 60)
        minutes = minutes.filter { $0.key >= oldest }
        protectedChanges = protectedChanges.filter { $0.key >= oldest }
    }

    func report(now: Date, window: TimeInterval = 3_600, minimumBytes: Int64 = 200_000_000, minimumChanges: Int = 2_000) -> GrowthReport {
        let oldest = Int(now.addingTimeInterval(-window).timeIntervalSince1970 / 60)
        var totals: [String: Int64] = [:], counts: [String: Int] = [:], protectedCounts: [String: Int] = [:]
        for (minute, folders) in minutes where minute >= oldest {
            for (folder, bucket) in folders {
                for ancestor in ancestors(folder) {
                    totals[ancestor, default: 0] += bucket.bytes
                    counts[ancestor, default: 0] += bucket.changes
                }
            }
        }
        for (minute, folders) in protectedChanges where minute >= oldest {
            for (folder, count) in folders { protectedCounts[folder, default: 0] += count }
        }
        let entries = explain(home, totals: totals, minimum: minimumBytes)
            .map { GrowthEntry(path: $0, bytes: totals[$0] ?? 0, changes: counts[$0] ?? 0) }
            .sorted { $0.bytes > $1.bytes }
        let unmeasured = protectedCounts.filter { $0.value >= minimumChanges }
            .map { GrowthEntry(path: $0.key, bytes: 0, changes: $0.value, measured: false) }
            .sorted { $0.changes > $1.changes }
        let topLevel = totals.filter { depth($0.key) == 1 }.values
        let total = topLevel.filter { $0 > 0 }.reduce(0, +), shrunk = -topLevel.filter { $0 < 0 }.reduce(0, +)
        let incomplete = lastDrop.map { now.timeIntervalSince($0) <= window } ?? false
        return GrowthReport(entries: Array(entries.prefix(5)), unmeasured: Array(unmeasured.prefix(3)), total: total, shrunk: shrunk, incomplete: incomplete)
    }

    /// Expands a folder into its growing subfolders while they hold most of its growth; otherwise reports the folder itself.
    /// Below the top levels, only a single dominant subfolder is followed, so deep splits report their common parent.
    private func explain(_ node: String, totals: [String: Int64], minimum: Int64) -> [String] {
        let children = depth(node) < maxDepth ? totals.filter { $0.value >= minimum && parent($0.key) == node } : [:]
        let own = node == home ? children.values.reduce(0, +) : totals[node] ?? 0
        if node != home, own < minimum { return [] }
        if !children.isEmpty, children.count == 1 || depth(node) < 3, children.values.reduce(0, +) * 5 >= own * 4 {
            return children.keys.flatMap { explain($0, totals: totals, minimum: minimum) }
        }
        return node == home ? [] : [node]
    }

    private mutating func recordProtected(_ path: String, minute: Int) {
        // One app's container under Library, such as Library/Containers/com.docker.docker, or the top folder elsewhere.
        let parts = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
        let keep = parts.first == "Library" ? 3 : 1
        guard parts.count >= keep else { return }
        protectedChanges[minute, default: [:]][home + "/" + parts.prefix(keep).joined(separator: "/"), default: 0] += 1
    }

    @discardableResult
    private mutating func remember(_ path: String, _ size: Int64, at date: Date) -> Bool {
        guard sizes[path] != nil || sizes.count < maxFiles else {
            lastDrop = date
            return false
        }
        sizes[path] = size
        return true
    }

    /// The file's folder, cut to `maxDepth` levels below home; nil for a file directly in home.
    private func folder(of path: String) -> String? {
        var end: String.Index?, depth = 0
        var index = path.utf8.index(path.startIndex, offsetBy: home.utf8.count + 1)
        while depth < maxDepth, let slash = path.utf8[index...].firstIndex(of: UInt8(ascii: "/")) {
            end = slash; depth += 1
            index = path.utf8.index(after: slash)
        }
        return end.map { String(path[..<$0]) }
    }

    private func ancestors(_ folder: String) -> [String] {
        var result = [folder], current = folder
        while true {
            current = parent(current)
            guard current.count > home.count else { return result }
            result.append(current)
        }
    }

    private func depth(_ path: String) -> Int { path == home ? 0 : path.dropFirst(home.count + 1).split(separator: "/").count }
    private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
}

final class GrowthTracker: @unchecked Sendable {
    // Folders that raise a macOS privacy prompt when read; their files are counted, not measured.
    static let protectedFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/Containers", "Library/Group Containers", "Pictures/Photos Library.photoslibrary"]

    // The queue exclusively owns the ledger and the stream; FSEvents delivers callbacks on it.
    private let queue = DispatchQueue(label: "ResourceWatch.growth", qos: .utility)
    private var ledger: GrowthLedger
    private var stream: FSEventStreamRef?
    private var measuredProtected: Set<String> = []
    private let latency: CFTimeInterval
    private let protectedPrefixes: [String]

    init(home: String = NSHomeDirectory(), latency: CFTimeInterval = 5) {
        ledger = GrowthLedger(home: home)
        self.latency = latency
        protectedPrefixes = Self.protectedFolders.map { (home as NSString).appendingPathComponent($0) + "/" }
    }

    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            // The stream holds the tracker, so a callback never reaches a freed tracker.
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: { info in info.map { _ = Unmanaged<GrowthTracker>.fromOpaque($0).retain() }; return info },
                                               release: { info in info.map { Unmanaged<GrowthTracker>.fromOpaque($0).release() } }, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, [ledger.home] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Allows measuring a protected folder after the user granted access to it, such as Downloads after a manual scan.
    func allowMeasuring(_ folder: String) {
        queue.async { [self] in measuredProtected.insert((ledger.home as NSString).appendingPathComponent(folder) + "/") }
    }

    func report(now: Date = Date(), minimumBytes: Int64 = 200_000_000) async -> GrowthReport {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                ledger.prune(before: now.addingTimeInterval(-3_600))
                continuation.resume(returning: ledger.report(now: now, minimumBytes: minimumBytes))
            }
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let tracker = Unmanaged<GrowthTracker>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        tracker.handle(list, Array(UnsafeBufferPointer(start: flags, count: count)))
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let now = Date()
        // A batch often repeats one file many times; merging its flags needs one lstat per file, not one per event.
        var merged: [String: FSEventStreamEventFlags] = [:], order: [String] = []
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 { ledger.lastDrop = now }
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
            if merged[path] == nil { order.append(path) }
            merged[path, default: 0] |= flag
        }
        for path in order {
            guard let flag = merged[path] else { continue }
            if protectedPrefixes.contains(where: { path.hasPrefix($0) }) && !measuredProtected.contains(where: { path.hasPrefix($0) }) {
                ledger.record(path, .unmeasured, at: now)
                continue
            }
            let onlyRemoved = flag & Self.writes == 0 && flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
            ledger.record(path, Self.change(flag, size: onlyRemoved ? nil : Self.allocatedSize(path)), at: now)
        }
    }

    private static let writes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed
                                                        | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod)

    static func change(_ flag: FSEventStreamEventFlags, size: Int64?) -> GrowthLedger.Change {
        guard let size else { return .removed }
        let arrived = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
        return flag & arrived != 0 ? .created(size) : .modified(size)
    }

    /// A new APFS clone shares all its blocks with its source, so it counts only the blocks it changes later.
    private static func allocatedSize(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return StorageScanner.privateSize(path) ?? Int64(info.st_blocks) * 512
    }
}

enum GrowthAdvisor {
    static func advice(_ report: GrowthReport, home: String = NSHomeDirectory(), targets: [StorageTarget] = StorageTarget.catalog) -> [Recommendation] {
        let caveat = "ResourceWatch measures file changes in your home folder since it started." + (report.incomplete ? " Some file changes were not measured, so the numbers can be low." : "")
        let measured = report.entries.map { entry -> Recommendation in
            let target = targets.first { entry.path.hasPrefix((home as NSString).appendingPathComponent($0.path)) }
            let changes = "\(entry.changes.formatted()) file change\(entry.changes == 1 ? "" : "s")"
            var detail = entry.sizeUnclear
                ? ["\(changes) in this folder in the last hour.",
                   "ResourceWatch counted \(StorageAdvisor.format(entry.bytes)), but free space did not drop by that much, so the size is unclear. "
                    + "Files that were deleted without a file event can cause this."]
                : ["Files in this folder grew by \(StorageAdvisor.format(entry.bytes)) in the last hour (\(changes))."]
            detail += target?.advice.components(separatedBy: "\n") ?? []
            detail.append(caveat)
            var actions: [Recommendation.Action] = FileManager.default.fileExists(atPath: entry.path) ? [.reveal(entry.path)] : []
            if let command = target?.command { actions.append(.copy(command)) }
            let title = entry.sizeUnclear ? "\(display(entry.path)) — \(changes) in the last hour" : "\(display(entry.path)) — +\(StorageAdvisor.format(entry.bytes)) in the last hour"
            return Recommendation(id: "growth-\(entry.path)", title: title, detail: detail + Advisor.commandLines(actions), bytes: entry.sizeUnclear ? nil : entry.bytes, actions: actions)
        }
        let unmeasured = report.unmeasured.map { entry -> Recommendation in
            let docker = entry.path.hasSuffix("/com.docker.docker")
            var detail = ["\(entry.changes.formatted()) file changes in the last hour.",
                          "macOS protects this folder, so ResourceWatch counts its file changes but does not read their size."]
            if docker { detail.append("Docker Desktop keeps its virtual machine disk here. The command shows what uses Docker's space.") }
            let actions: [Recommendation.Action] = docker ? [.copy("docker system df")] : [.reveal(entry.path)]
            return Recommendation(id: "growth-\(entry.path)", title: "\(display(entry.path)) — \(entry.changes.formatted()) file changes in the last hour",
                                  detail: detail + Advisor.commandLines(actions), actions: actions)
        }
        return measured + unmeasured
    }

    /// The notification hint for a storage growth alert. The growth report can lag the alert by a minute, so an empty report does not prove that no folder grew.
    static func alertHint(_ growth: [Recommendation]) -> String {
        growth.first.map { "Fastest growth: \($0.title)" }
            ?? "ResourceWatch has not found a growing folder in your home folder yet. Local snapshots, swap or files outside your home folder can use the space."
    }

    private static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
