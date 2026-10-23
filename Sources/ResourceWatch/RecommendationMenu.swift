import AppKit
import SwiftUI

struct RecommendationMenu: View {
    let recommendation: Recommendation
    let monitor: Monitor
    var body: some View {
        Menu(recommendation.title, systemImage: recommendation.symbol) {
            ForEach(recommendation.detail, id: \.self) { Text($0) }
            Divider()
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
        }
    }

    var isAvailable: Bool {
        if case .activate(let pid) = self { return NSRunningApplication(processIdentifier: pid) != nil }
        return true
    }
}
