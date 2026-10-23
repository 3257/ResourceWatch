import AppKit

struct AIAgent: Hashable, Sendable {
    var name: String
    var path: String
    var promptFlag: String?

    func arguments(prompt: String) -> [String] { (promptFlag.map { [$0] } ?? []) + [prompt] }
}

enum AIAgents {
    // Each command starts an interactive session that begins with the prompt (checked against each CLI's --help).
    struct Known {
        var name: String
        var command: String
        var promptFlag: String?
    }
    static let known = [
        Known(name: "Claude Code", command: "claude"),
        Known(name: "Codex", command: "codex"),
        Known(name: "OpenCode", command: "opencode", promptFlag: "--prompt"),
        Known(name: "Gemini CLI", command: "gemini", promptFlag: "-i")
    ]
    private static let fallbackFolders = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin"]

    /// Finds the CLIs with the user's interactive login shell, because a menu bar app does not inherit the terminal's PATH.
    static func detect(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> [AIAgent] {
        let resolved = Dictionary(shellPaths(shell: shell).map { (($0 as NSString).lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        return known.compactMap { agent in
            let fallback = fallbackFolders.map { (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent(agent.command) }
            guard let path = ([resolved[agent.command]].compactMap { $0 } + fallback).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            return AIAgent(name: agent.name, path: path, promptFlag: agent.promptFlag)
        }
    }

    static func prompt(for recommendation: Recommendation, context: String) -> String {
        let details = recommendation.detail.map { "- \($0)" }.joined(separator: "\n")
        return """
        I use ResourceWatch, a macOS menu bar resource monitor. It reported this on my Mac:

        \(recommendation.title)
        \(details)

        \(context)

        Investigate this on my Mac. Use read-only commands first. Explain what uses the resources and why, \
        and whether it is safe to clean up. Then give specific steps, largest impact first. \
        Do not delete files, quit apps or stop processes until I confirm each step.
        """
    }

    /// Opens a `.command` file, so the user's default terminal app runs the agent in a new window or tab without an Automation permission.
    static func launch(_ agent: AIAgent, prompt: String, directory: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ResourceWatch-AI")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let promptFile = folder.appending(path: "\(id).txt"), commandFile = folder.appending(path: "\(id).command")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("fish") ? nil : $0 } ?? "/bin/zsh"
        try script(agent, promptFile: promptFile, directory: directory, shell: shell).write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandFile.path)
        NSWorkspace.shared.open(commandFile)
    }

    /// The script reads the prompt from a file, so quotes and new lines in the prompt need no shell escaping.
    static func script(_ agent: AIAgent, promptFile: URL, directory: String, shell: String) -> String {
        let flag = agent.promptFlag.map { " " + WorktreeReader.quote($0) } ?? ""
        return """
        #!/bin/zsh
        cd \(WorktreeReader.quote(directory)) 2>/dev/null || cd ~
        prompt="$(cat \(WorktreeReader.quote(promptFile.path)))"
        rm -f \(WorktreeReader.quote(promptFile.path)) "$0"
        exec \(WorktreeReader.quote(shell)) -ilc 'exec "$@"' resourcewatch \(WorktreeReader.quote(agent.path))\(flag) "$prompt"

        """
    }

    private static func shellPaths(shell: String) -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "for c in \(known.map(\.command).joined(separator: " ")); do command -v $c; done"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }
}
