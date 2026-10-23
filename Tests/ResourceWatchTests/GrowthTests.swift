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
    ledger.record("\(home)/Downloads/movie.crdownload", .renamed(nil), at: now)
    ledger.record("\(home)/Downloads/movie.mp4", .renamed(900 * mb), at: now)
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

@Test func fileLimitKeepsCountingNewFiles() {
    var ledger = GrowthLedger(home: home)
    ledger.maxFiles = 1
    let now = Date()
    ledger.record("\(home)/a/one", .created(150 * mb), at: now)
    ledger.record("\(home)/a/two", .created(150 * mb), at: now)
    #expect(ledger.trackedFiles == 1)
    #expect(ledger.report(now: now).entries.first?.bytes == 300 * mb)
}

@Test func eventFlagsMapToChanges() {
    typealias Flags = FSEventStreamEventFlags
    let created = Flags(kFSEventStreamEventFlagItemCreated), renamed = Flags(kFSEventStreamEventFlagItemRenamed), modified = Flags(kFSEventStreamEventFlagItemModified)
    #expect(GrowthTracker.change(created | modified, size: 10) == .created(10))
    #expect(GrowthTracker.change(modified, size: 10) == .modified(10))
    #expect(GrowthTracker.change(renamed, size: 10) == .renamed(10))
    #expect(GrowthTracker.change(renamed, size: nil) == .renamed(nil))
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

@Test func growthAdviceExplainsKnownFoldersAndProtectedOnes() {
    let report = GrowthReport(entries: [GrowthEntry(path: "\(home)/Library/Caches/Homebrew/downloads", bytes: 2_500 * mb, changes: 40)],
                              unmeasured: [GrowthEntry(path: "\(home)/Library/Containers/com.docker.docker", bytes: 0, changes: 12_000, measured: false)],
                              total: 2_500 * mb, incomplete: true)
    let advice = GrowthAdvisor.advice(report, home: home)
    #expect(advice.count == 2)
    #expect(advice[0].title.hasSuffix("Library/Caches/Homebrew/downloads — +2.5 GB in the last hour"))
    #expect(advice[0].detail.first == "Files in this folder grew by 2.5 GB in the last hour (40 file changes).")
    #expect(advice[0].detail.contains("Homebrew keeps the downloads of installed packages and old versions here."))
    #expect(advice[0].detail.contains { $0.contains("macOS dropped some file events") })
    #expect(advice[0].actions == [.copy("brew cleanup --prune=all")])
    #expect(advice[1].actions == [.copy("docker system df")])
    #expect(advice[1].detail.contains { $0.hasPrefix("macOS protects this folder") })
}
