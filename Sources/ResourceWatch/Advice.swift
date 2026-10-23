import Foundation

struct Recommendation: Identifiable, Equatable, Sendable {
    enum Action: Hashable, Sendable {
        case reveal(String)
        case copy(String)
        case activate(Int32)
        case openActivityMonitor

        var title: String {
            switch self {
            case .reveal: "Reveal in Finder"
            case .copy: "Copy command"
            case .activate: "Bring app to front"
            case .openActivityMonitor: "Open Activity Monitor"
            }
        }
    }

    var id: String
    var title: String
    var detail: [String]
    var bytes: Int64?
    var actions: [Action] = []
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
            var title = String(format: "%@: %.1f GiB RAM", group.name, Double(group.memory) / gib)
            if group.members.count > 1 { title += " in \(group.members.count) processes" }
            if group.cpu >= settings.processCPUPercent { title += String(format: " · %.0f%% CPU", group.cpu) }
            let tip = tip(for: group)
            var detail: [String] = []
            if group.members.count > 1, let largest = group.largest {
                detail.append(String(format: "Largest: %@ — %.1f GiB, PID %d", largest.name, Double(largest.memory) / gib, largest.pid))
            }
            detail.append(tip.text)
            if group.members.count > 1 { detail.append("Shared memory counts once per process, so the total is approximate.") }
            return Recommendation(id: "app-\(group.name)", title: title, detail: detail + commandLines(tip.actions), actions: tip.actions)
        }
    }

    static func processHint(identity: String, samples: [ProcessSample]) -> String? {
        guard let group = groups(samples).first(where: { $0.members.contains { $0.identity == identity } }) else { return nil }
        let summary = group.members.count > 1 ? String(format: "%@ uses %.1f GiB in %d processes. ", group.name, Double(group.memory) / gib, group.members.count) : ""
        return summary + tip(for: group).text
    }

    static func commandLines(_ actions: [Recommendation.Action]) -> [String] {
        actions.compactMap { if case .copy(let command) = $0 { "Command: \(command)" } else { nil } }
    }

    private static func displayName(_ name: String) -> String {
        name.hasPrefix("com.apple.WebKit") ? "Safari and WebKit pages" : name
    }

    private static func tip(for group: AppGroup) -> (text: String, actions: [Recommendation.Action]) {
        let name = group.name
        if chromium.contains(where: { name.hasPrefix($0) }) {
            return ("Open the browser's Task Manager (Shift+Esc) to find the tab or extension.", [.activate(group.rootPID)])
        }
        if name == "Safari" || name == "Safari and WebKit pages" {
            return ("Close unused tabs. Activity Monitor shows the site name for each tab process.", [.openActivityMonitor])
        }
        if name == "Xcode" || name == "SourceKitService" {
            return ("Restart Xcode to release indexer and build memory.", name == "Xcode" ? [.activate(group.rootPID)] : [.openActivityMonitor])
        }
        if name == "Simulator" || name == "launchd_sim" {
            return ("Shut down simulators you are not using.", [.copy("xcrun simctl shutdown all")])
        }
        if name.hasPrefix("com.docker") || name.hasPrefix("Docker") || name.contains("qemu") || name.contains("Virtualization") {
            return ("Stop idle containers or lower Docker's memory limit.", [.copy("docker stop $(docker ps -q)")])
        }
        return ("Quit or restart \(name) if you do not need it now.", [.activate(group.rootPID), .openActivityMonitor])
    }
}
