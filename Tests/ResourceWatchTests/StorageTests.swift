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

@Test func clonesCountAsSharedNotAsTheirOwnSize() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root.appending(path: "source/a.bin"), bytes: 3_000_000)
    try FileManager.default.createDirectory(at: root.appending(path: "clones"), withIntermediateDirectories: true)
    for index in 0..<4 {
        #expect(copyfile(root.appending(path: "source/a.bin").path, root.appending(path: "clones/\(index).bin").path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0)
    }
    let clones = StorageScanner.allocatedSize(root.appending(path: "clones"), deadline: .distantFuture)
    #expect(clones.bytes < 100_000)
    #expect(clones.shared >= 12_000_000)
    #expect(StorageScanner.privateSize(root.appending(path: "clones/0.bin").path) == 0)
    try write(root.appending(path: "plain.bin"), bytes: 1_000_000)
    #expect((StorageScanner.privateSize(root.appending(path: "plain.bin").path) ?? 0) >= 1_000_000)
    #expect(StorageScanner.privateSize(root.appending(path: "missing").path) == nil)
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
        StorageFinding(id: "d", title: "Records", path: "/tmp/d", bytes: nil, detail: [])
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

// Git records real paths, and macOS temporary folders sit behind the /var symlink.
private func canonical(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

@discardableResult
private func git(_ arguments: [String], in folder: URL) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", folder.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
    process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    return String(bytes: data, encoding: .utf8) ?? ""
}

private func project(in derivedData: URL, _ name: String, workspace: String, bytes: Int) throws {
    let folder = derivedData.appending(path: name)
    try write(folder.appending(path: "Build/output.bin"), bytes: bytes)
    try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0).write(to: folder.appending(path: "info.plist"))
}

/// A repo with a merged worktree, an unmerged one, and one whose folder was deleted.
private func worktreeFixture(_ root: URL) throws -> URL {
    let repo = root.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], in: repo)
    try write(repo.appending(path: "README"), bytes: 10)
    try git(["add", "."], in: repo); try git(["commit", "-qm", "start"], in: repo)
    try git(["worktree", "add", "-q", "-b", "feature/done", "../wt-done"], in: repo)
    try write(root.appending(path: "wt-done/done.txt"), bytes: 10)
    try git(["add", "."], in: root.appending(path: "wt-done")); try git(["commit", "-qm", "done"], in: root.appending(path: "wt-done"))
    try git(["merge", "-q", "feature/done"], in: repo)
    try git(["worktree", "add", "-q", "-b", "feature/active", "../wt-active"], in: repo)
    try write(root.appending(path: "wt-active/active.txt"), bytes: 10)
    try git(["add", "."], in: root.appending(path: "wt-active")); try git(["commit", "-qm", "active"], in: root.appending(path: "wt-active"))
    try git(["worktree", "add", "-q", "-b", "feature/gone", "../wt-gone"], in: repo)
    try FileManager.default.removeItem(at: root.appending(path: "wt-gone"))
    return repo
}

@Test func worktreeCheckFlagsMergedIdleAndMissingWorktrees() throws {
    let root = try canonical(temporaryFolder())
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try worktreeFixture(root)
    #expect(WorktreeReader.repositories(in: root).map(\.path) == [repo.path])
    let trees = WorktreeReader.worktrees(repository: repo)
    #expect(trees.map(\.branch) == ["feature/active", "feature/done", "feature/gone"])
    #expect(trees.map(\.exists) == [true, true, false])
    #expect(WorktreeReader.findings(roots: [root]).filter { $0.id.hasPrefix("worktree-") }.isEmpty)

    let soon = WorktreeReader.findings(roots: [root], now: Date().addingTimeInterval(2 * 86_400))
    #expect(soon.map(\.title) == ["repo: 1 missing worktree", "Worktree feature/done (repo)"])
    #expect(soon[0].command == "git -C '\(repo.path)' worktree prune")
    let done = soon[1]
    #expect(done.detail.first == "Branch feature/done is merged into main.")
    #expect(done.command?.hasPrefix("git -C '\(repo.path)' worktree remove '") == true)
    #expect(done.command?.hasSuffix("/wt-done'") == true)
    #expect((done.bytes ?? 0) > 0)

    let derivedData = try canonical(temporaryFolder())
    defer { try? FileManager.default.removeItem(at: derivedData) }
    for workspace in [root.appending(path: "wt-done/App.xcodeproj"), repo.appending(path: "Other.xcodeproj")] {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }
    try project(in: derivedData, "App-abc", workspace: root.appending(path: "wt-done/App.xcodeproj").path, bytes: 500_000)
    try project(in: derivedData, "Gone-xyz", workspace: "/nonexistent/Gone.xcodeproj", bytes: 300_000)
    try project(in: derivedData, "Other-def", workspace: repo.appending(path: "Other.xcodeproj").path, bytes: 10)
    let projects = DerivedDataReader.projects(in: derivedData)
    #expect(projects.map(\.folder.lastPathComponent) == ["App-abc", "Gone-xyz", "Other-def"])
    let withBuilds = try #require(WorktreeReader.findings(roots: [root], derivedData: projects, now: Date().addingTimeInterval(2 * 86_400)).last)
    #expect((withBuilds.bytes ?? 0) >= (done.bytes ?? 0) + 500_000)
    #expect(withBuilds.detail.contains { $0.hasPrefix("Includes 0.0 GB of Xcode DerivedData") })
    #expect(withBuilds.command?.hasSuffix("/wt-done' && rm -rf '\(derivedData.path)/App-abc'") == true)
    let orphans = try #require(DerivedDataReader.orphans(projects, derivedData: derivedData))
    #expect(orphans.detail.last == "1 folder whose project no longer exists: Gone.xcodeproj")
    #expect(orphans.command == "rm -rf '\(derivedData.path)/Gone-xyz'")
    #expect(orphans.trash == ["\(derivedData.path)/Gone-xyz"])
    let worktreeFindings = WorktreeReader.findings(roots: [root], derivedData: projects, now: Date().addingTimeInterval(2 * 86_400))
    #expect(worktreeFindings.allSatisfy { $0.trash.isEmpty })
    #expect((orphans.bytes ?? 0) >= 300_000 && (orphans.bytes ?? 0) < 500_000)

    let later = WorktreeReader.findings(roots: [root], now: Date().addingTimeInterval(20 * 86_400))
    #expect(later.map(\.title) == ["repo: 1 missing worktree", "Worktree feature/active (repo)", "Worktree feature/done (repo)"])
    #expect(later[1].detail.first == "No git activity for 20 days.")
    #expect(WorktreeReader.quote("it's") == "'it'\\''s'")
}

@Test func moveToTrashIsOfferedOnlyForRecreatableFolders() {
    let trashable = StorageFinding(id: "a", title: "Cache", path: "/Users/x/Library/Caches/tool", bytes: 3_000_000_000, detail: [], trash: ["/Users/x/Library/Caches/tool"])
    let kept = StorageFinding(id: "b", title: "Archives", path: "/Users/x/Library/Developer/Xcode/Archives", bytes: 2_000_000_000, detail: [])
    let advice = StorageAdvisor.advice([trashable, kept])
    #expect(advice[0].actions == [.reveal("/Users/x/Library/Caches/tool"), .moveToTrash(title: "Cache — 3.0 GB", paths: ["/Users/x/Library/Caches/tool"])])
    #expect(advice[1].actions == [.reveal("/Users/x/Library/Developer/Xcode/Archives")])
    let catalog = Dictionary(uniqueKeysWithValues: StorageTarget.catalog.map { ($0.path, $0.trashable) })
    #expect(catalog["Library/Developer/Xcode/DerivedData"] == true)
    #expect(catalog["Library/Caches/org.swift.swiftpm"] == true)
    for path in ["Library/Developer/Xcode/Archives", "Library/Developer/CoreSimulator/Devices", "Library/Developer/XCTestDevices", ".Trash", "Downloads", "Library/Application Support/MobileSync/Backup"] {
        #expect(catalog[path] == false, "\(path) must not offer Move to Trash")
    }
}

@Test func trashPolicyRejectsHomeTopFoldersAndEscapes() {
    let home = "/Users/x"
    #expect(TrashPolicy.allows(["/Users/x/Library/Caches/tool"], home: home))
    #expect(TrashPolicy.allows(["/Users/x/Library/Developer/Xcode/DerivedData/App-abc", "/Users/x/.npm/_cacache"], home: home))
    #expect(!TrashPolicy.allows([], home: home))
    #expect(!TrashPolicy.allows(["/Users/x"], home: home))
    #expect(!TrashPolicy.allows(["/Users/x/Downloads"], home: home))
    #expect(!TrashPolicy.allows(["/Users/x/Library/../Downloads"], home: home))
    #expect(!TrashPolicy.allows(["/Users/xavier/Library/Caches"], home: home))
    #expect(!TrashPolicy.allows(["/Library/Caches/tool"], home: home))
    #expect(!TrashPolicy.allows(["/Users/x/Library/Caches/tool", "/etc/hosts"], home: home))
}
