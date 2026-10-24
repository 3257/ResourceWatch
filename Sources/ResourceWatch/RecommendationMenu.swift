import AppKit
import SwiftUI

struct RecommendationMenu: View {
    let recommendation: Recommendation
    let monitor: Monitor
    var body: some View {
        Menu(recommendation.title, systemImage: recommendation.symbol) {
            ForEach(recommendation.detail, id: \.self) { Text($0) }
            Divider()
            RecommendationActions(recommendation: recommendation, monitor: monitor)
        }
    }
}

/// The menu bar submenu and the mini panel's row menus offer the same actions.
struct RecommendationActions: View {
    let recommendation: Recommendation
    let monitor: Monitor
    var body: some View {
        ForEach(recommendation.actions.filter(\.isAvailable), id: \.self) { action in
            Button(action.title, systemImage: action.symbol) { monitor.perform(action) }
        }
        if !monitor.agents.isEmpty {
            Menu("Ask AI in Terminal", systemImage: "sparkles") {
                ForEach(monitor.agents, id: \.self) { agent in Button(agent.name) { monitor.ask(agent, about: recommendation) } }
            }
        }
    }
}

extension Recommendation {
    var symbol: String {
        if id.hasPrefix("app-") { return "memorychip" }
        return id.hasPrefix("growth-") ? "chart.line.uptrend.xyaxis" : "folder"
    }
}

extension Recommendation.Action {
    var symbol: String {
        switch self {
        case .reveal: "folder"
        case .copy: "doc.on.doc"
        case .activate: "macwindow.on.rectangle"
        case .openActivityMonitor: "gauge.with.dots.needle.33percent"
        case .moveToTrash: "trash"
        case .runScript: "terminal"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .activate(let pid): NSRunningApplication(processIdentifier: pid) != nil
        case .runScript(let script): script.command(in: CleanupScript.folder) != nil
        default: true
        }
    }
}
