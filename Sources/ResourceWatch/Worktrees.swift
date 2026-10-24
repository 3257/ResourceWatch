import Foundation

struct Worktree: Equatable, Sendable {
    var repository: URL
    var path: URL
    var branch: String?
    var lastActivity: Date?
    var exists: Bool
}

struct DerivedDataProject: Equatable, Sendable {
    var folder: URL
    var workspace: String
}

enum DerivedDataReader {
    static func projects(in derivedData: URL) -> [DerivedDataProject] {
        ((try? FileManager.default.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []).compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appending(path: "info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String else { return nil }
            return DerivedDataProject(folder: entry, workspace: workspace)
        }.sorted { $0.folder.path < $1.folder.path }
    }

    static func orphans(_ projects: [DerivedDataProject], derivedData: URL) -> StorageFinding? {
        let orphans = projects.filter { !FileManager.default.fileExists(atPath: $0.workspace) }
        guard !orphans.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(StorageScanner.timeLimit)
        let sizes = orphans.map { StorageScanner.allocatedSize($0.folder, deadline: deadline) }
        return StorageFinding(id: "derived-orphans", title: "Xcode DerivedData for deleted projects", path: derivedData.path,
                              bytes: sizes.reduce(0) { $0 + $1.bytes }, complete: sizes.allSatisfy(\.complete),
                              detail: ["Xcode keeps DerivedData after you delete or move a project. Nothing uses these folders now.",
                                       "\(orphans.count) folder\(orphans.count == 1 ? "" : "s") whose project no longer exists: "
                                        + orphans.map { ($0.workspace as NSString).lastPathComponent }.joined(separator: ", ")],
                              command: "rm -rf " + orphans.map { WorktreeReader.quote($0.folder.path) }.joined(separator: " "),
                              trash: orphans.map(\.folder.path),
                              script: .devClean("dd-gone", summary: "Lists DerivedData of deleted projects again, then asks before it deletes them."))
    }
}

enum WorktreeReader {
    static func repositories(in root: URL, depth: Int = 2) -> [URL] {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appending(path: ".git").path, isDirectory: &isDirectory), isDirectory.boolValue { return [root] }
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.path < $1.path }
            .flatMap { repositories(in: $0, depth: depth - 1) }
    }

    // Reads git's worktree records directly so discovery needs no subprocess.
    static func worktrees(repository: URL) -> [Worktree] {
        let records = repository.appending(path: ".git/worktrees")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { entry in
            guard let gitdir = try? String(contentsOf: entry.appending(path: "gitdir"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !gitdir.isEmpty else { return nil }
            let gitFile = gitdir.hasPrefix("/") ? URL(fileURLWithPath: gitdir) : entry.appending(path: gitdir).standardizedFileURL
            let path = gitFile.deletingLastPathComponent()
            let head = (try? String(contentsOf: entry.appending(path: "HEAD"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst("ref: refs/heads/".count)) : nil }
            let dates = ["index", "HEAD"].compactMap { (try? entry.appending(path: $0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            return Worktree(repository: repository, path: path, branch: branch, lastActivity: dates.max(), exists: FileManager.default.fileExists(atPath: path.path))
        }.sorted { $0.path.path < $1.path.path }
    }

    static func merged(_ repository: URL) -> (base: String, branches: Set<String>)? {
        let origin = git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repository)?.trimmingCharacters(in: .whitespacesAndNewlines)
        for base in [origin, "main", "master"].compactMap({ $0 }) where !base.isEmpty {
            if let output = git(["for-each-ref", "--merged", base, "--format=%(refname:short)", "refs/heads"], in: repository) {
                return (base, Set(output.split(separator: "\n").map(String.init)))
            }
        }
        return nil
    }

    static func findings(roots: [URL], derivedData: [DerivedDataProject] = [], now: Date = Date(), staleDays: Double = 14) -> [StorageFinding] {
        roots.flatMap { repositories(in: $0) }.flatMap { repository -> [StorageFinding] in
            let trees = worktrees(repository: repository)
            guard !trees.isEmpty else { return [] }
            let merged = merged(repository)
            let baseBranch = merged.flatMap { $0.base.split(separator: "/").last.map(String.init) }
            var result: [StorageFinding] = []
            let missing = trees.filter { !$0.exists }
            if !missing.isEmpty {
                result.append(StorageFinding(id: "prune-\(repository.path)",
                                             title: "\(repository.lastPathComponent): \(missing.count) missing worktree\(missing.count == 1 ? "" : "s")", path: repository.path, bytes: nil,
                                             detail: ["Git still lists worktree folders that no longer exist."], command: "git -C \(quote(repository.path)) worktree prune"))
            }
            for tree in trees where tree.exists {
                let idleDays = tree.lastActivity.map { now.timeIntervalSince($0) / 86_400 } ?? 0
                var reasons: [String] = []
                // A new branch with no commits is already "merged"; one idle day separates it from finished work.
                if let branch = tree.branch, let merged, branch != baseBranch, merged.branches.contains(branch), idleDays >= 1 {
                    reasons.append("Branch \(branch) is merged into \(merged.base).")
                }
                if idleDays >= staleDays { reasons.append("No git activity for \(Int(idleDays)) days.") }
                guard !reasons.isEmpty else { continue }
                let deadline = Date().addingTimeInterval(StorageScanner.timeLimit)
                let builds = derivedData.filter { $0.workspace.hasPrefix(tree.path.path + "/") }
                let size = StorageScanner.allocatedSize(tree.path, deadline: deadline)
                let buildSizes = builds.map { StorageScanner.allocatedSize($0.folder, deadline: deadline) }
                let buildBytes = buildSizes.reduce(0) { $0 + $1.bytes }
                if !builds.isEmpty { reasons.append("Includes \(StorageAdvisor.format(buildBytes)) of Xcode DerivedData for this worktree.") }
                var command = "git -C \(quote(repository.path)) worktree remove \(quote(tree.path.path))"
                if !builds.isEmpty { command += " && rm -rf " + builds.map { quote($0.folder.path) }.joined(separator: " ") }
                result.append(StorageFinding(id: "worktree-\(tree.path.path)", title: "Worktree \(tree.branch ?? tree.path.lastPathComponent) (\(repository.lastPathComponent))", path: tree.path.path,
                                             bytes: size.bytes + buildBytes, complete: size.complete && buildSizes.allSatisfy(\.complete),
                                             detail: reasons + ["The command removes the worktree folder\(builds.isEmpty ? "" : " and its DerivedData"). "
                                                                + "The branch and its commits stay in the repository.",
                                                                "Git refuses to remove a worktree with uncommitted or untracked changes."],
                                             command: command))
            }
            return result
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacing("'", with: "'\\''") + "'" }

    private static func git(_ arguments: [String], in repository: URL) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(bytes: data, encoding: .utf8) : nil
    }
}
