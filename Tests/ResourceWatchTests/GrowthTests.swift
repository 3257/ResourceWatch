import CoreServices
import Foundation
import Testing
@testable import ResourceWatch

private let home = "/Users/fixture"
private let mb: Int64 = 1_000_000

@Test func createdFilesCountAndExistingFilesStartAsBaseline() {
    var ledger = GrowthLedger(home: home)
    let now = Date()
    ledger.record("\(home)/Projects/app/build/a.o", .created(300 * mb), at: now)
    ledger.record("\(home)/VMs/disk.raw", .modified(60_000 * mb), at: now)
    ledger.record("\(home)/VMs/disk.raw", .modified(60_250 * mb), at: now)
    ledger.record("/private/var/vm/swapfile0", .created(2_000 * mb), at: now)
    let report = ledger.report(now: now)
    #expect(report.entries.map(\.path) == ["\(home)/Projects/app/build", "\(home)/VMs"])
    #expect(report.entries.map(\.bytes) == [300 * mb, 250 * mb])
    #expect(report.total == 550 * mb)
}

@Test func removalsAndRenamesDoNotInflateGrowth() {
    var ledger = GrowthLedger(home: home)
    let now = Date()
    ledger.record("\(home)/Downloads/movie.crdownload", .created(900 * mb), at: now)
    ledger.record("\(home)/Downloads/movie.crdownload", .removed, at: now)
    ledger.record("\(home)/Downloads/movie.mp4", .created(900 * mb), at: now)
    ledger.record("\(home)/Clones/device/big.img", .created(400 * mb), at: now)
    ledger.record("\(home)/Clones/device/big.img", .removed, at: now)
    ledger.record("\(home)/tmp/scratch.bin", .created(500 * mb), at: now)
    ledger.record("\(home)/tmp/scratch.bin", .removed, at: now)
    ledger.record("\(home)/tmp/unknown.bin", .removed, at: now)
    #expect(ledger.report(now: now).entries.map(\.path) == ["\(home)/Downloads"])
    #expect(ledger.report(now: now).entries.first?.bytes == 900 * mb)
    #expect(ledger.trackedFiles == 1)
}

@Test func reportDrillsDownToTheFolderThatHoldsTheGrowth() {
    var ledger = GrowthLedger(home: home)
    let now = Date()
    let build = "\(home)/Library/Developer/Xcode/DerivedData/App-abc/Build"
    for index in 0..<8 { ledger.record("\(build)/Products/file\(index)", .created(1_000 * mb), at: now) }
    ledger.record("\(build)/Logs/log.txt", .created(50 * mb), at: now)
    ledger.record("\(home)/Library/Caches/com.example/blob", .created(400 * mb), at: now)
    ledger.record("\(home)/Library/Caches/com.example/other", .created(300 * mb), at: now)
    ledger.record("\(home)/.npm/_cacache/x", .created(100 * mb), at: now)
    let report = ledger.report(now: now)
    #expect(report.entries.map(\.path) == ["\(build)/Products", "\(home)/Library/Caches/com.example"])
    #expect(report.entries.map(\.bytes) == [8_000 * mb, 700 * mb])
    #expect(report.entries.first?.changes == 8)
    #expect(report.total == 8_850 * mb)
}

@Test func oldMinutesLeaveTheWindowAndProtectedFoldersOnlyCountChanges() {
    var ledger = GrowthLedger(home: home)
    let now = Date()
    ledger.record("\(home)/Old/file", .created(900 * mb), at: now.addingTimeInterval(-4_000))
    for index in 0..<2_500 { ledger.record("\(home)/Library/Containers/com.docker.docker/Data/f\(index)", .unmeasured, at: now) }
    let report = ledger.report(now: now)
    #expect(report.entries.isEmpty)
    #expect(report.unmeasured == [GrowthEntry(path: "\(home)/Library/Containers/com.docker.docker", bytes: 0, changes: 2_500, measured: false)])
    ledger.prune(before: now.addingTimeInterval(-3_600))
    #expect(ledger.report(now: now, window: 10_000).entries.isEmpty)
}

@Test func filesPastTheLimitDoNotCountBecauseTheirRemovalCouldNotBeSubtracted() {
    var ledger = GrowthLedger(home: home)
    ledger.maxFiles = 1
    let now = Date()
    // Test runs create and delete simulator clones in a loop; past the limit, only the creations used to count.
    for _ in 0..<5 {
        ledger.record("\(home)/a/one", .created(150 * mb), at: now)
        ledger.record("\(home)/a/two", .created(150 * mb), at: now)
        ledger.record("\(home)/a/two", .removed, at: now)
        ledger.record("\(home)/a/one", .removed, at: now)
    }
    ledger.record("\(home)/a/one", .created(250 * mb), at: now)
    ledger.record("\(home)/a/two", .created(250 * mb), at: now)
    let report = ledger.report(now: now)
    #expect(ledger.trackedFiles == 1)
    #expect(report.entries.first?.bytes == 250 * mb)
    #expect(report.incomplete)
}

@Test func growthThatFreeSpaceCannotExplainIsMarkedUnclear() {
    let entries = [GrowthEntry(path: "\(home)/Library/Developer/XCTestDevices", bytes: 1_001_900 * mb, changes: 3_458_946),
                   GrowthEntry(path: "\(home)/Projects/app", bytes: 4_000 * mb, changes: 900)]
    let report = GrowthReport(entries: entries, total: 1_005_900 * mb, shrunk: 1_000 * mb).checked(freeSpaceDrop: 5_000 * mb)
    #expect(report.entries.map(\.sizeUnclear) == [true, false])
    #expect(report.sizeUnclear)
    #expect(!GrowthReport(entries: [entries[1]], total: 4_000 * mb).checked(freeSpaceDrop: 3_000 * mb).sizeUnclear)
    #expect(GrowthReport(entries: [entries[1]], total: 4_000 * mb).checked(freeSpaceDrop: 0).sizeUnclear)

    let advice = GrowthAdvisor.advice(report, home: home)
    #expect(advice[0].title == "\(home)/Library/Developer/XCTestDevices — \(3_458_946.formatted()) file changes in the last hour")
    #expect(advice[0].bytes == nil)
    #expect(advice[0].detail[1].hasPrefix("ResourceWatch counted 1001.9 GB, but free space did not drop by that much"))
    #expect(advice[1].title.hasSuffix("app — +4.0 GB in the last hour"))
}

@Test func eventFlagsMapToChanges() {
    typealias Flags = FSEventStreamEventFlags
    let created = Flags(kFSEventStreamEventFlagItemCreated), renamed = Flags(kFSEventStreamEventFlagItemRenamed), modified = Flags(kFSEventStreamEventFlagItemModified)
    #expect(GrowthTracker.change(created | modified, size: 10) == .created(10))
    #expect(GrowthTracker.change(modified, size: 10) == .modified(10))
    #expect(GrowthTracker.change(renamed, size: 10) == .created(10))
    #expect(GrowthTracker.change(renamed, size: nil) == .removed)
    #expect(GrowthTracker.change(created | Flags(kFSEventStreamEventFlagItemRemoved), size: nil) == .removed)
}

@Test func trackerAttributesRealFileWritesToTheirFolder() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: "ResourceWatchGrowth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary.appending(path: "cache/blobs"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = try #require(realpath(temporary.path, nil))
    defer { free(root) }
    let home = String(cString: root)
    let tracker = GrowthTracker(home: home, latency: 0.1)
    tracker.start()
    try await Task.sleep(for: .milliseconds(500))
    for index in 0..<3 { try Data(repeating: 1, count: 2_000_000).write(to: URL(fileURLWithPath: "\(home)/cache/blobs/\(index).bin")) }
    var report = GrowthReport()
    for _ in 0..<50 where report.total < 6_000_000 {
        try await Task.sleep(for: .milliseconds(200))
        report = await tracker.report(minimumBytes: 1_000_000)
    }
    #expect(report.entries.first?.path == "\(home)/cache/blobs")
    #expect((report.entries.first?.bytes ?? 0) >= 6_000_000)
}

@Test func trackerCountsAnAPFSCloneOnlyForTheBlocksItChanges() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: "ResourceWatchClones-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary.appending(path: "clones"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary.appending(path: "fresh"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = try #require(realpath(temporary.path, nil))
    defer { free(root) }
    let home = String(cString: root)
    try Data(repeating: 3, count: 4_000_000).write(to: URL(fileURLWithPath: "\(home)/source.bin"))
    let tracker = GrowthTracker(home: home, latency: 0.1)
    tracker.start()
    try await Task.sleep(for: .milliseconds(500))
    for index in 0..<5 { #expect(copyfile("\(home)/source.bin", "\(home)/clones/\(index).bin", nil, copyfile_flags_t(COPYFILE_CLONE)) == 0) }
    try Data(repeating: 1, count: 2_000_000).write(to: URL(fileURLWithPath: "\(home)/fresh/new.bin"))
    var report = GrowthReport()
    for _ in 0..<50 where report.total < 2_000_000 {
        try await Task.sleep(for: .milliseconds(200))
        report = await tracker.report(minimumBytes: 1_000_000)
    }
    #expect(report.entries.map(\.path) == ["\(home)/fresh"])
    #expect(report.total < 3_000_000)
}

@Test func growthAdviceExplainsKnownFoldersAndProtectedOnes() {
    let report = GrowthReport(entries: [GrowthEntry(path: "\(home)/Library/Caches/Homebrew/downloads", bytes: 2_500 * mb, changes: 40)],
                              unmeasured: [GrowthEntry(path: "\(home)/Library/Containers/com.docker.docker", bytes: 0, changes: 12_000, measured: false)],
                              total: 2_500 * mb, incomplete: true)
    let advice = GrowthAdvisor.advice(report, home: home)
    #expect(advice.count == 2)
    #expect(advice[0].title.hasSuffix("Library/Caches/Homebrew/downloads — +2.5 GB in the last hour"))
    #expect(advice[0].detail.first == "Files in this folder grew by 2.5 GB in the last hour (40 file changes).")
    #expect(advice[0].detail.contains("Homebrew keeps the downloads of installed packages and old versions here."))
    #expect(advice[0].detail.contains { $0.contains("Some file changes were not measured") })
    #expect(advice[0].actions == [.copy("brew cleanup --prune=all")])
    #expect(advice[1].actions == [.copy("docker system df")])
    #expect(advice[1].detail.contains { $0.hasPrefix("macOS protects this folder") })
}

@Test func deepSplitsReportTheirCommonParentAndOldDropsExpire() {
    var ledger = GrowthLedger(home: home)
    let now = Date()
    let device = "\(home)/Library/Developer/XCTestDevices/E369/data"
    ledger.record("\(device)/Library/a", .created(600 * mb), at: now)
    ledger.record("\(device)/Containers/Shared/b", .created(400 * mb), at: now)
    #expect(ledger.report(now: now).entries.map(\.path) == [device])
    ledger.lastDrop = now.addingTimeInterval(-4_000)
    #expect(!ledger.report(now: now).incomplete)
    ledger.lastDrop = now.addingTimeInterval(-60)
    #expect(ledger.report(now: now).incomplete)
}
