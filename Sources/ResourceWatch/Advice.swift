import Foundation

struct Recommendation: Identifiable, Equatable, Sendable {
    enum Action: Hashable, Sendable {
        case reveal(String)
        case copy(String)
        case activate(Int32)
        case openActivityMonitor
        case moveToTrash(title: String, paths: [String])
        case runScript(CleanupScript)

        var title: String {
            switch self {
            case .reveal: "Show in Finder"
            case .copy: "Copy command"
            case .activate: "Bring app to front"
            case .openActivityMonitor: "Open Activity Monitor"
            case .moveToTrash: "Move to Trash…"
            case .runScript: "Run script in Terminal"
            }
        }
    }

    var id: String
    var title: String
    var detail: [String]
    var bytes: Int64?
    var actions: [Action] = []
}

/// A bundled script that reports first and asks y/N before each change. ResourceWatch only opens it in Terminal.
struct CleanupScript: Hashable, Sendable {
    var file: String
    var arguments: [String]
    var summary: String

    static func devClean(_ categories: String, summary: String) -> CleanupScript {
        CleanupScript(file: "dev_clean.py", arguments: ["--apply", "--only", categories], summary: summary)
    }

    static let folder = Bundle.main.resourceURL?.appending(path: "Scripts")

    // /usr/bin/python3 is a stub that asks to install the developer tools when they are missing.
    static let developerToolsInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// The interpreter and arguments that run the script, or nil when the script cannot run here.
    func command(in folder: URL?, developerTools: Bool = developerToolsInstalled) -> (executable: String, arguments: [String])? {
        guard let path = folder?.appending(path: file).path, FileManager.default.fileExists(atPath: path) else { return nil }
        if file.hasSuffix(".py") { return developerTools ? ("/usr/bin/python3", ["-I", path] + arguments) : nil }
        return ("/bin/zsh", [path] + arguments)
    }
}

struct AppGroup: Equatable, Sendable {
    var name: String
    var rootPID: Int32
    var members: [ProcessSample]
    var memory: UInt64 { members.reduce(0) { $0 + $1.memory } }
    var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
    var largest: ProcessSample? { members.max { $0.memory < $1.memory } }
}

enum Advisor {
    private static let gib = Double(1 << 30)
    // Commands started from a shell belong to the command, not to the terminal app that hosts the shell.
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "login", "tmux", "screen"]
    private static let chromium = ["Google Chrome", "Microsoft Edge", "Brave Browser", "Arc", "Vivaldi", "Chromium"]

    static func groups(_ samples: [ProcessSample]) -> [AppGroup] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [String: [ProcessSample]] = [:], roots: [String: ProcessSample] = [:]
        for sample in samples {
            var root = sample
            for _ in 0..<32 {
                guard root.parentPID > 1, root.parentPID != root.pid, let parent = byPID[root.parentPID], !shells.contains(parent.name) else { break }
                root = parent
            }
            let name = displayName(root.name)
            members[name, default: []].append(sample)
            if roots[name].map({ root.memory > $0.memory }) ?? true { roots[name] = root }
        }
        return members.map { AppGroup(name: $0.key, rootPID: roots[$0.key]?.pid ?? 0, members: $0.value) }.sorted { $0.memory > $1.memory }
    }

    static func processAdvice(_ m: Metrics, settings: WatchSettings) -> [Recommendation] {
        groups(m.processSamples).filter { Double($0.memory) / gib >= settings.processMemoryGiB || $0.cpu >= settings.processCPUPercent }.map { group in
            var title = String(format: "%@: %.1f GiB memory footprint", group.name, Double(group.memory) / gib)
            if group.members.count > 1 { title += " in \(group.members.count) processes" }
            if group.cpu >= settings.processCPUPercent { title += String(format: " · %.0f%% CPU", group.cpu) }
            let tip = tip(for: group, samples: m.processSamples)
            var detail = tip.about
            detail.append("Memory footprint includes compressed or swapped memory. It is not a share of physical RAM; check memory pressure for system health.")
            if group.members.count > 1, let largest = group.largest {
                detail.append(String(format: "Largest: %@ — %.1f GiB, PID %d", largest.name, Double(largest.memory) / gib, largest.pid))
            }
            detail.append(tip.text)
            return Recommendation(id: "app-\(group.name)", title: title, detail: detail + commandLines(tip.actions), actions: tip.actions)
        }
    }

    static func processHint(identity: String, samples: [ProcessSample]) -> String? {
        guard let group = groups(samples).first(where: { $0.members.contains { $0.identity == identity } }) else { return nil }
        let summary = group.members.count > 1
            ? String(format: "%@ has a %.1f GiB memory footprint in %d processes. ", group.name, Double(group.memory) / gib, group.members.count) : ""
        return summary + tip(for: group, samples: samples).text
    }

    static func commandLines(_ actions: [Recommendation.Action]) -> [String] {
        actions.compactMap {
            switch $0 {
            case .copy(let command): "Command: \(command)"
            case .runScript(let script): "Script: \(script.file) — \(script.summary)"
            default: nil
            }
        }
    }

    private static func displayName(_ name: String) -> String {
        if name.hasPrefix("com.apple.WebKit") { return "Safari and WebKit pages" }
        // macOS truncates the process name com.apple.Virtualization.VirtualMachine to 31 characters.
        if name.hasPrefix("com.apple.Virtualization.Virtu") { return "Virtual machines" }
        return name == "launchd_sim" ? "Running simulators" : name
    }

    private struct Tip {
        var about: [String]
        var text: String
        var actions: [Recommendation.Action]
    }

    /// The app behind a process name. Virtual machines run in a process of launchd, so the running apps are the only clue to their owner.
    private static func vmApp(_ name: String) -> String? {
        switch name {
        case "tart": "Tart"
        case "limactl": "Lima"
        case "UTM", "QEMULauncher": "UTM"
        case "Docker Desktop", "com.docker.backend": "Docker Desktop"
        case _ where name.hasPrefix("Parallels") || name.hasPrefix("prl_"): "Parallels Desktop"
        case _ where name.hasPrefix("OrbStack"): "OrbStack"
        default: nil
        }
    }

    private static func tip(for group: AppGroup, samples: [ProcessSample]) -> Tip {
        let name = group.name
        if chromium.contains(where: { name.hasPrefix($0) }) {
            return Tip(about: ["\(name) runs each tab, extension and the GPU in a separate helper process.",
                               "Video, maps and large web apps such as Gmail keep a tab's memory high."],
                       text: "Open the browser's Task Manager (Shift+Esc), sort by memory, then close or reload the largest tabs.",
                       actions: [.activate(group.rootPID)])
        }
        if name == "Safari" || name == "Safari and WebKit pages" {
            return Tip(about: ["Safari, and apps that show web content, run each page in a separate WebKit process.",
                               "Video, maps and large web apps such as Gmail keep a page's memory high."],
                       text: "Close unused tabs. Activity Monitor shows the site name for each page process.",
                       actions: [.openActivityMonitor])
        }
        if name == "Xcode" || name == "SourceKitService" {
            return Tip(about: ["Xcode, SourceKitService and the indexer use more memory in large projects and long sessions."],
                       text: "Restart Xcode to release that memory. Your project and settings stay.",
                       actions: name == "Xcode" ? [.activate(group.rootPID)] : [.openActivityMonitor])
        }
        if name == "Simulator" || name == "Running simulators" {
            let running = group.members.filter { $0.name == "launchd_sim" }.count
            return Tip(about: ["Each running simulator starts a full set of iOS system processes, such as SpringBoard."]
                           + (running > 0 ? ["\(running) simulator\(running == 1 ? " is" : "s are") running."] : []),
                       text: "Shut down simulators you do not use. The command shuts down all of them; their apps and data stay.",
                       actions: [.copy("xcrun simctl shutdown all")])
        }
        if name == "Virtual machines" || name.contains("qemu") {
            let apps = Set(samples.compactMap { vmApp($0.name) }).sorted()
            let tart = apps.contains("Tart"), docker = apps == ["Docker Desktop"]
            return Tip(about: ["macOS runs virtual machines in this process. A running machine keeps the memory that its settings give it, even when it is idle.",
                               apps.isEmpty ? "No known virtual machine app runs now, such as Tart, UTM, Parallels Desktop, OrbStack or Docker Desktop."
                                            : "Virtual machine apps that run now: \(apps.joined(separator: ", "))."],
                       text: "Stop the virtual machines that you do not use, or give them less memory in their settings."
                           + (tart ? " The command lists Tart's machines. Stop one with tart stop <name>." : docker ? " The command stops all running containers." : ""),
                       actions: tart ? [.copy("tart list")] : docker ? [.copy("docker stop $(docker ps -q)")] : [.openActivityMonitor])
        }
        if name.hasPrefix("com.docker") || name.hasPrefix("Docker") {
            return Tip(about: ["Docker Desktop runs a Linux virtual machine. The machine keeps its memory, up to the Docker limit, even when containers are idle."],
                       text: "Stop idle containers, or lower the limit in Docker Desktop → Settings → Resources. The command stops all running containers.",
                       actions: [.copy("docker stop $(docker ps -q)")])
        }
        return Tip(about: ["\(name) and its helper processes use this memory."],
                   text: "Quit or restart \(name) if you do not need it now. A restart often releases memory that grew during a long session.",
                   actions: [.activate(group.rootPID), .openActivityMonitor])
    }
}
