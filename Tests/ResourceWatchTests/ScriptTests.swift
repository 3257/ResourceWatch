import Foundation
import Testing
@testable import ResourceWatch

private let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "CleanupScripts")

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ResourceWatchScripts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
}

@Test func launcherPassesEachArgumentUnchanged() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appending(path: "it's a folder")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let output = root.appending(path: "output.txt")
    let tool = root.appending(path: "my \"tool\"")
    try "#!/bin/zsh\n{ pwd; print -rl -- \"$@\" } > '\(output.path)'\n".write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let arguments = ["it's a path", "$HOME `ticks`", "--only", "a,b"]
    let command = root.appending(path: "run.command")
    try TerminalLauncher.script(command: ([tool.path] + arguments).map(WorktreeReader.quote).joined(separator: " "), directory: work.path, shell: "/bin/zsh")
        .write(to: command, atomically: true, encoding: .utf8)

    let result = try run("/bin/zsh", [command.path], environment: ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"])
    #expect(result.status == 0)
    let lines = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
    #expect(lines[0].hasSuffix("/it's a folder"))
    #expect(Array(lines[1...4]) == arguments)
    #expect(!FileManager.default.fileExists(atPath: command.path))
}

@Test func catalogRowsCarryTheirDevCleanCategories() {
    let only = Dictionary(uniqueKeysWithValues: StorageTarget.catalog.map { ($0.path, $0.script.map { $0.arguments.joined(separator: " ") }) })
    #expect(only["Library/Developer/Xcode/DerivedData"] == "--apply --only dd-gone,dd-stale,dd-orphan")
    #expect(only["Library/Developer/CoreSimulator/Devices"] == "--apply --only sims,runtimes")
    #expect(only["Library/Caches/org.swift.swiftpm"] == "--apply --only spm")
    for platform in ["iOS", "watchOS", "tvOS"] {
        #expect(only["Library/Developer/Xcode/\(platform) DeviceSupport"] == "--apply --only devsupport")
    }
    for path in ["Library/Developer/Xcode/Archives", ".Trash", "Downloads", "Library/Application Support/MobileSync/Backup"] {
        #expect(only[path] == .some(nil), "\(path) must not offer a script")
    }
    #expect(StorageTarget.catalog.compactMap(\.script).allSatisfy { $0.file == "dev_clean.py" && $0.arguments.first == "--apply" })
}

@Test func adviceOffersTheScriptAndNamesIt() throws {
    let script = CleanupScript.devClean("spm", summary: "Shows the cache size.")
    let finding = StorageFinding(id: "spm", title: "SPM", path: "/Users/me/Library/Caches/org.swift.swiftpm", bytes: 2_000_000_000, detail: [], script: script)
    let advice = try #require(StorageAdvisor.advice([finding]).first)
    #expect(advice.actions.contains(.runScript(script)))
    #expect(advice.detail.last == "Script: dev_clean.py — Shows the cache size.")
}

@Test func scriptCommandNeedsTheFileAndForPythonTheDeveloperTools() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let python = CleanupScript.devClean("spm", summary: ""), shell = CleanupScript(file: "check.sh", arguments: ["x y"], summary: "")
    #expect(python.command(in: nil) == nil)
    #expect(python.command(in: root, developerTools: true) == nil)
    try "".write(to: root.appending(path: "dev_clean.py"), atomically: true, encoding: .utf8)
    try "".write(to: root.appending(path: "check.sh"), atomically: true, encoding: .utf8)
    #expect(python.command(in: root, developerTools: false) == nil)
    let command = try #require(python.command(in: root, developerTools: true))
    #expect(command.executable == "/usr/bin/python3")
    #expect(command.arguments == ["-I", root.appending(path: "dev_clean.py").path, "--apply", "--only", "spm"])
    #expect(shell.command(in: root, developerTools: false)?.arguments == [root.appending(path: "check.sh").path, "x y"])
}

@Test func bundledScriptsParseWithTheSystemInterpreters() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
    #expect(files.contains("dev_clean.py"))
    for file in files {
        let path = scripts.appending(path: file).path
        // compile() checks the syntax without writing __pycache__ into the repository.
        let result = file.hasSuffix(".py") ? try run("/usr/bin/python3", ["-I", "-c", "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')", path])
            : try run("/bin/zsh", ["-n", path])
        #expect(result.status == 0, "\(file): \(result.output)")
    }
}

@Test func devCleanReportsAndDeletesNothingWithoutATerminal() throws {
    let home = try folder()
    defer { try? FileManager.default.removeItem(at: home) }
    let gone = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
    try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/nonexistent/Gone.xcodeproj"], format: .xml, options: 0).write(to: gone.appending(path: "info.plist"))
    let script = scripts.appending(path: "dev_clean.py").path
    let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

    let result = try run("/usr/bin/python3", ["-I", script, "--apply", "--only", "dd-gone"], environment: environment)
    #expect(result.status == 0, "\(result.output)")
    #expect(result.output.contains("Gone-xyz  (was /nonexistent/Gone.xcodeproj)"))
    // Without a terminal the prompt answers No; while Xcode runs, the script only reports.
    #expect(result.output.contains("skipped") || result.output.contains("Nothing was deleted, because"))
    #expect(FileManager.default.fileExists(atPath: gone.path))

    #expect(try run("/usr/bin/python3", ["-I", script, "--help"], environment: environment).status == 0)
    #expect(try run("/usr/bin/python3", ["-I", script, "--bogus"], environment: environment).status != 0)
    #expect(try run("/usr/bin/python3", ["-I", script, "--only", "bogus"], environment: environment).status != 0)
}
