import AppKit

extension Monitor {
    func ask(_ agent: AIAgent, about recommendation: Recommendation) {
        let gib = Double(1 << 30)
        var context = "Mac: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        if let m = latest {
            context += String(format: ", %.1f of %.0f GiB RAM used, memory pressure %@, swap %.1f GiB, %.0f of %.0f GB storage free.",
                              Double(m.memoryUsed) / gib, Double(m.memoryTotal) / gib, m.pressure >= 4 ? "critical" : m.pressure >= 2 ? "warning" : "normal",
                              Double(m.swap) / gib, Double(m.free) / 1e9, Double(m.total) / 1e9)
        }
        let worktree = recommendation.id.hasPrefix("storage-worktree-") ? recommendation.actions.compactMap { if case .reveal(let path) = $0 { path } else { nil } }.first : nil
        do {
            try AIAgents.launch(agent, prompt: AIAgents.prompt(for: recommendation, context: context), directory: worktree ?? NSHomeDirectory())
        } catch {
            events.insert("Could not start \(agent.name)\n\(error.localizedDescription)", at: 0)
        }
    }
    func perform(_ action: Recommendation.Action) {
        switch action {
        case .reveal(let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .copy(let command): NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        case .activate(let pid): NSRunningApplication(processIdentifier: pid)?.activate()
        case .openActivityMonitor: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .moveToTrash(let title, let paths): confirmTrash(title: title, paths: paths)
        }
    }
    func confirmTrash(title: String, paths: [String]) {
        guard TrashPolicy.allows(paths) else {
            events.insert("Did not move \(title) to the Trash\nThe path is outside the allowed folders.", at: 0)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(title) to the Trash?"
        alert.informativeText = "ResourceWatch moves these items to the Trash:\n\n" + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            + "\n\nQuit apps that use them first, such as Xcode. You can restore the items from the Trash until you empty it."
        let move = alert.addButton(withTitle: "Move to Trash")
        move.hasDestructiveAction = true
        move.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failures: [String] = []
        for path in paths {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch { failures.append("\((path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)") }
        }
        let now = Date().formatted(date: .omitted, time: .shortened)
        events.insert(failures.isEmpty ? "\(now) — Moved \(title) to the Trash" : "\(now) — Could not move all of \(title) to the Trash\n" + failures.joined(separator: "\n"), at: 0)
        lastStorageScan = nil
        scanStorage(trigger: .daily)
    }
}
