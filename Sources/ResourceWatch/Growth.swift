import CoreServices
import Foundation

struct GrowthEntry: Equatable, Sendable {
    var path: String
    var bytes: Int64
    var changes: Int
    var measured = true
}

struct GrowthReport: Equatable, Sendable {
    var entries: [GrowthEntry] = []
    var unmeasured: [GrowthEntry] = []
    var total: Int64 = 0
    var incomplete = false
}

/// Attributes file-size changes to folders under home, per minute, for a rolling window.
struct GrowthLedger {
    enum Change: Equatable { case created(Int64), modified(Int64), removed, renamed(Int64?), unmeasured }

    let home: String
    var maxDepth = 8
    var maxFiles = 300_000
    var incomplete = false
    private var sizes: [String: Int64] = [:]
    private var bytes: [Int: [String: Int64]] = [:]
    private var changes: [Int: [String: Int]] = [:]
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
            delta = size - (known ?? 0)
            remember(path, size)
        case .modified(let size):
            // The first sight of an existing file only sets a baseline, so a large file that grows a little does not count in full.
            delta = known.map { size - $0 } ?? 0
            remember(path, size)
        case .removed:
            delta = -(known ?? 0)
            sizes[path] = nil
        case .renamed(let size):
            // FSEvents does not pair the old and new names, so a move never counts as growth.
            sizes[path] = nil
            if let size { remember(path, size) }
        case .unmeasured:
            break
        }
        for prefix in prefixes(path) {
            changes[minute, default: [:]][prefix, default: 0] += 1
            if delta != 0 { bytes[minute, default: [:]][prefix, default: 0] += delta }
        }
    }

    mutating func prune(before date: Date) {
        let oldest = Int(date.timeIntervalSince1970 / 60)
        bytes = bytes.filter { $0.key >= oldest }
        changes = changes.filter { $0.key >= oldest }
        protectedChanges = protectedChanges.filter { $0.key >= oldest }
    }

    func report(now: Date, window: TimeInterval = 3_600, minimumBytes: Int64 = 200_000_000, minimumChanges: Int = 2_000) -> GrowthReport {
        let oldest = Int(now.addingTimeInterval(-window).timeIntervalSince1970 / 60)
        func sum<Value: AdditiveArithmetic>(_ buckets: [Int: [String: Value]]) -> [String: Value] {
            buckets.filter { $0.key >= oldest }.values.reduce(into: [:]) { total, minute in
                for (prefix, value) in minute { total[prefix, default: .zero] += value }
            }
        }
        let totals = sum(bytes), counts = sum(changes), protectedCounts = sum(protectedChanges)
        let entries = explain(home, totals: totals, minimum: minimumBytes)
            .map { GrowthEntry(path: $0, bytes: totals[$0] ?? 0, changes: counts[$0] ?? 0) }
            .sorted { $0.bytes > $1.bytes }
        let unmeasured = protectedCounts.filter { $0.value >= minimumChanges }
            .map { GrowthEntry(path: $0.key, bytes: 0, changes: $0.value, measured: false) }
            .sorted { $0.changes > $1.changes }
        let total = totals.filter { depth($0.key) == 1 }.values.filter { $0 > 0 }.reduce(0, +)
        return GrowthReport(entries: Array(entries.prefix(5)), unmeasured: Array(unmeasured.prefix(3)), total: total, incomplete: incomplete)
    }

    /// Expands a folder into its growing subfolders while they hold most of its growth; otherwise reports the folder itself.
    private func explain(_ node: String, totals: [String: Int64], minimum: Int64) -> [String] {
        let children = depth(node) < maxDepth ? totals.filter { $0.value >= minimum && parent($0.key) == node } : [:]
        let own = node == home ? children.values.reduce(0, +) : totals[node] ?? 0
        if node != home, own < minimum { return [] }
        if !children.isEmpty, children.values.reduce(0, +) * 5 >= own * 4 {
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

    private mutating func remember(_ path: String, _ size: Int64) {
        if sizes[path] != nil || sizes.count < maxFiles { sizes[path] = size }
    }

    private func prefixes(_ path: String) -> [String] {
        let parts = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
        return (0..<min(parts.count, maxDepth)).map { home + "/" + parts[...$0].joined(separator: "/") }
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
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
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
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 { ledger.incomplete = true }
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
            if protectedPrefixes.contains(where: { path.hasPrefix($0) }) && !measuredProtected.contains(where: { path.hasPrefix($0) }) {
                ledger.record(path, .unmeasured, at: now)
                continue
            }
            ledger.record(path, Self.change(flag, size: Self.allocatedSize(path)), at: now)
        }
    }

    static func change(_ flag: FSEventStreamEventFlags, size: Int64?) -> GrowthLedger.Change {
        let created = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
        let renamed = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
        guard let size else { return renamed ? .renamed(nil) : .removed }
        if created { return .created(size) }
        return renamed ? .renamed(size) : .modified(size)
    }

    private static func allocatedSize(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_blocks) * 512
    }
}

enum GrowthAdvisor {
    static func advice(_ report: GrowthReport, home: String = NSHomeDirectory(), targets: [StorageTarget] = StorageTarget.catalog) -> [Recommendation] {
        let caveat = "ResourceWatch measures file changes in your home folder since it started." + (report.incomplete ? " macOS dropped some file events, so the numbers can be low." : "")
        let measured = report.entries.map { entry -> Recommendation in
            let target = targets.first { entry.path.hasPrefix((home as NSString).appendingPathComponent($0.path)) }
            var detail = ["Files in this folder grew by \(StorageAdvisor.format(entry.bytes)) in the last hour (\(entry.changes.formatted()) file changes)."]
            detail += target?.advice.components(separatedBy: "\n") ?? []
            detail.append(caveat)
            var actions: [Recommendation.Action] = FileManager.default.fileExists(atPath: entry.path) ? [.reveal(entry.path)] : []
            if let command = target?.command { actions.append(.copy(command)) }
            return Recommendation(id: "growth-\(entry.path)", title: "\(display(entry.path)) — +\(StorageAdvisor.format(entry.bytes)) in the last hour",
                                  detail: detail + Advisor.commandLines(actions), bytes: entry.bytes, actions: actions)
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

    private static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
