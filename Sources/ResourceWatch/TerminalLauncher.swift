import AppKit

enum TerminalLauncher {
    static var shell: String { ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("fish") ? nil : $0 } ?? "/bin/zsh" }

    /// Opens a `.command` file, so the user's default terminal app runs it in a new window or tab without an Automation permission.
    static func open(_ script: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ResourceWatch-Terminal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let commandFile = folder.appending(path: "\(UUID().uuidString).command")
        try script.write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandFile.path)
        NSWorkspace.shared.open(commandFile)
    }

    static func open(executable: String, arguments: [String], directory: String) throws {
        try open(script(command: ([executable] + arguments).map(WorktreeReader.quote).joined(separator: " "), directory: directory, shell: shell))
    }

    /// `command` must already be quoted. The login shell runs it, so the user's PATH applies (`docker`, `brew`).
    static func script(command: String, directory: String, shell: String, setup: [String] = []) -> String {
        (["#!/bin/zsh", "cd \(WorktreeReader.quote(directory)) 2>/dev/null || cd ~"] + setup + [
            "rm -f \"$0\"",
            "exec \(WorktreeReader.quote(shell)) -ilc 'exec \"$@\"' resourcewatch \(command)",
            ""
        ]).joined(separator: "\n")
    }
}
