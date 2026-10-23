import Foundation
import Testing
@testable import ResourceWatch

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ResourceWatchTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Test func allocatedSizeCountsNestedFilesAndSkipsUnreadableFolders() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "locked").path); try? FileManager.default.removeItem(at: root) }
    try write(root.appending(path: "a.bin"), bytes: 100_000)
    try write(root.appending(path: "nested/b.bin"), bytes: 200_000)
    try write(root.appending(path: "locked/c.bin"), bytes: 50_000)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appending(path: "locked").path)
    let size = StorageScanner.allocatedSize(root, deadline: .distantFuture)
    #expect(size.complete)
    #expect(size.bytes >= 300_000 && size.bytes < 350_000)
    #expect(StorageScanner.allocatedSize(root.appending(path: "a.bin"), deadline: .distantFuture).bytes >= 100_000)
    #expect(StorageScanner.allocatedSize(root.appending(path: "missing"), deadline: .distantFuture).bytes == 0)
}

@Test func scanReportsOldItemsAndRespectsProtectedFolders() throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appending(path: "Cache/x.bin"), bytes: 10_000)
    try write(home.appending(path: "Downloads/old.zip"), bytes: 20_000)
    try write(home.appending(path: "Downloads/new.zip"), bytes: 30_000)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: home.appending(path: "Downloads/old.zip").path)
    let targets = [StorageTarget(name: "Cache", path: "Cache", advice: "Safe.", command: "clean"),
                   StorageTarget(name: "Old downloads", path: "Downloads", advice: "Old.", protected: true, olderThanDays: 30),
                   StorageTarget(name: "Absent", path: "Nope", advice: "")]
    let open = StorageScanner.scan(targets, home: home, includeProtected: false, now: now)
    #expect(open.map(\.title) == ["Cache"])
    #expect(open.first?.command == "clean")
    let all = StorageScanner.scan(targets, home: home, includeProtected: true, now: now)
    let downloads = try #require(all.first { $0.title == "Old downloads" })
    #expect(downloads.detail == ["Old.", "1 item"])
    #expect((downloads.bytes ?? 0) >= 20_000 && (downloads.bytes ?? 0) < 30_000)
}

@Test func storageAdviceKeepsLargeItemsLargestFirst() {
    let findings = [
        StorageFinding(id: "a", title: "Medium", path: "/tmp/a", bytes: 2_000_000_000, detail: ["A."]),
        StorageFinding(id: "b", title: "Small", path: "/tmp/b", bytes: 500_000_000, detail: []),
        StorageFinding(id: "c", title: "Huge", path: "/tmp/c", bytes: 5_000_000_000, complete: false, detail: ["C."], command: "tool clean"),
        StorageFinding(id: "d", title: "Records", path: "/tmp/d", bytes: nil, detail: []),
    ]
    let advice = StorageAdvisor.advice(findings)
    #expect(advice.map(\.title) == ["Huge — at least 5.0 GB", "Medium — 2.0 GB", "Records"])
    #expect(advice[0].actions == [.reveal("/tmp/c"), .copy("tool clean")])
    #expect(advice[0].detail == ["C.", "/tmp/c", "Command: tool clean"])
    #expect(advice[1].actions == [.reveal("/tmp/a")])
}

@Test func scanScheduleLimitsAutomaticScans() {
    let now = Date()
    #expect(ScanSchedule.due(last: nil, now: now, trigger: .daily))
    #expect(ScanSchedule.due(last: now, now: now, trigger: .manual))
    #expect(!ScanSchedule.due(last: now.addingTimeInterval(-3_000), now: now, trigger: .storageAlert))
    #expect(ScanSchedule.due(last: now.addingTimeInterval(-3_700), now: now, trigger: .storageAlert))
    #expect(!ScanSchedule.due(last: now.addingTimeInterval(-3_700), now: now, trigger: .daily))
    #expect(ScanSchedule.due(last: now.addingTimeInterval(-90_000), now: now, trigger: .daily))
    #expect(ScanSchedule.due(last: now.addingTimeInterval(60), now: now, trigger: .daily))
}
