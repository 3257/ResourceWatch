import Foundation
import Testing
@testable import ResourceWatch

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ResourceWatchAI-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func executable(_ url: URL, _ body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func detectionPrefersThePathFromTheLoginShell() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try executable(root.appending(path: "claude"), "#!/bin/sh\n")
    try executable(root.appending(path: "opencode"), "#!/bin/sh\n")
    let shell = root.appending(path: "fake-shell")
    try executable(shell, "#!/bin/sh\necho 'Welcome banner'\necho '\(root.path)/claude'\necho '\(root.path)/opencode'\necho '\(root.path)/missing/codex'\n")
    let agents = AIAgents.detect(shell: shell.path)
    #expect(agents.first { $0.name == "Claude Code" }?.path == root.appending(path: "claude").path)
    let openCode = try #require(agents.first { $0.name == "OpenCode" })
    #expect(openCode.path == root.appending(path: "opencode").path)
    #expect(openCode.arguments(prompt: "Why?") == ["--prompt", "Why?"])
    #expect(agents.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) })
    #expect(AIAgent(name: "Gemini CLI", path: "/x/gemini", promptFlag: "-i").arguments(prompt: "Q") == ["-i", "Q"])
}

@Test func promptCarriesTheFindingContextAndSafetyRule() {
    let recommendation = Recommendation(id: "app-Running simulators", title: "Running simulators: 24.3 GiB RAM", detail: ["3 simulators are running.", "Command: xcrun simctl shutdown all"])
    let prompt = AIAgents.prompt(for: recommendation, context: "Mac: macOS 26.1, 48 GiB RAM.")
    #expect(prompt.contains("Running simulators: 24.3 GiB RAM\n- 3 simulators are running.\n- Command: xcrun simctl shutdown all"))
    #expect(prompt.contains("Mac: macOS 26.1, 48 GiB RAM."))
    #expect(prompt.contains("Do not delete files, quit apps or stop processes until I confirm each step."))
}

@Test func launchScriptRunsTheAgentInTheFolderWithTheExactPrompt() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appending(path: "it's a worktree")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let output = root.appending(path: "output.txt")
    let agentFile = root.appending(path: "agent")
    try executable(agentFile, "#!/bin/zsh\n{ pwd; print -rl -- \"$@\" } > '\(output.path)'\n")
    let promptFile = root.appending(path: "prompt.txt")
    let prompt = "Line one with 'quotes' and \"double\" $HOME `ticks`\nLine two"
    try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
    let script = root.appending(path: "run.command")
    try executable(script, AIAgents.script(AIAgent(name: "Fake", path: agentFile.path, promptFlag: "--prompt"), promptFile: promptFile, directory: work.path, shell: "/bin/zsh"))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path]
    process.environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"]
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    let lines = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
    #expect(lines[0].hasSuffix("/it's a worktree"))
    #expect(lines[1] == "--prompt")
    #expect(lines[2...3].joined(separator: "\n") == prompt)
    #expect(!FileManager.default.fileExists(atPath: promptFile.path))
    #expect(!FileManager.default.fileExists(atPath: script.path))
}
