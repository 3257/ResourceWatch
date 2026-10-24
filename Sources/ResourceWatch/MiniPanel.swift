import AppKit
import SwiftUI

@MainActor
final class MiniPanelController {
    private let panel: NSPanel
    init(monitor: Monitor) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "ResourceWatch"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        if !panel.setFrameUsingName("ResourceWatchMiniPanel") { panel.center() }
        panel.setFrameAutosaveName("ResourceWatchMiniPanel")
        panel.contentView = NSHostingView(rootView: MiniPanelView(monitor: monitor, pin: { [weak panel] pinned in
            panel?.level = pinned ? .floating : .normal
        }))
    }
    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum Metric: String, CaseIterable {
    case cpu = "CPU", memory = "Memory", network = "Network", storage = "Storage"
}

private struct MiniPanelView: View {
    @ObservedObject var monitor: Monitor
    let pin: (Bool) -> Void
    @State private var pinned = true
    @State private var selected: Metric?
    private let gib = Double(1 << 30)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: monitor.menuBarSymbol)
                    .foregroundStyle(monitor.currentWarnings.isEmpty && monitor.samplingError == nil ? Color.green : Color.orange)
                Text(monitor.samplingError != nil ? "Monitoring unavailable" : monitor.currentWarnings.first ?? "Within thresholds").font(.headline)
                Spacer()
                Button { pinned.toggle(); pin(pinned) } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.plain).help(pinned ? "Unpin from above other windows" : "Keep above other windows")
                    .accessibilityLabel("Keep above other windows").accessibilityValue(pinned ? "On" : "Off")
            }
            if let error = monitor.samplingError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let m = monitor.latest {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    tile(.cpu, symbol: "cpu", value: String(format: "%.0f%%", m.cpu), detail: "All cores", fraction: m.cpu / 100)
                    tile(.memory, symbol: "memorychip", value: String(format: "%.1f GiB", Double(m.memoryUsed) / gib), detail: m.pressure >= 4 ? "Critical pressure" : m.pressure >= 2 ? "Warning pressure" : "Normal pressure", fraction: m.memoryTotal > 0 ? Double(m.memoryUsed) / Double(m.memoryTotal) : 0)
                    tile(.network, symbol: "network", value: rate(m.network.download) + " ↓", detail: rate(m.network.upload) + " ↑", fraction: nil)
                    tile(.storage, symbol: "internaldrive", value: String(format: "%.0f GB", Double(m.free) / 1e9), detail: "Free on home volume", fraction: m.total > 0 ? 1 - Double(m.free) / Double(m.total) : 0)
                }
                Sparkline(values: monitor.cpuHistory).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)).frame(height: 26).accessibilityLabel("CPU history, up to ten minutes")
                if !monitor.suggestions.isEmpty { SuggestionList(suggestions: monitor.suggestions, agents: monitor.agents, perform: monitor.perform, ask: monitor.ask) }
                if let selected { details(selected, m) }
            } else { Text("Collecting first sample…").foregroundStyle(.secondary) }
            HStack {
                Text("Updates every 10 seconds").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }.font(.caption)
            }
        }.padding(16).frame(width: 340).background(.regularMaterial)
    }
    private func tile(_ metric: Metric, symbol: String, value: String, detail: String, fraction: Double?) -> some View {
        Button { selected = selected == metric ? nil : metric } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(metric.rawValue, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                if let fraction { ProgressView(value: min(1, max(0, fraction))).tint(.accentColor) }
                else { Color.clear.frame(height: 4) }
            }.frame(height: 82, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(selected == metric ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.rawValue), \(value), \(detail). Show details")
            .accessibilityIdentifier("metric-\(metric.rawValue.lowercased())")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selected = selected == metric ? nil : metric }
    }
    @ViewBuilder private func details(_ metric: Metric, _ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(metric.rawValue + " details").font(.subheadline.weight(.semibold))
            switch metric {
            case .cpu: Text(m.processes).font(.caption2)
            case .memory:
                Text(monitor.memoryDetails + String(format: "\nSwap %.1f GiB", Double(m.swap) / gib)).font(.caption2)
                Text("By app").font(.caption2.bold())
                ForEach(Array(monitor.appGroups.enumerated()), id: \.offset) { _, row in Text(row).font(.caption2) }
            case .network:
                ForEach(Array(monitor.networkDetails.enumerated()), id: \.offset) { _, row in Text(row).font(.caption2) }
            case .storage:
                Text(String(format: "%.1f of %.1f GB free", Double(m.free) / 1e9, Double(m.total) / 1e9)).font(.callout)
                if !monitor.growthAdvice.isEmpty {
                    SectionHeader("Growing in the last hour")
                    ForEach(monitor.growthAdvice.prefix(3)) { item in
                        let parts = Headline(item.title)
                        Menu {
                            ForEach(item.actions.filter { if case .reveal = $0 { true } else { false } }, id: \.self) { action in
                                Button(action.title, systemImage: action.symbol) { monitor.perform(action) }
                            }
                        } label: {
                            ValueRow(symbol: "arrow.up.right", tint: .orange, name: parts.name, value: parts.value?.replacing(" in the last hour", with: "") ?? "", options: true)
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                }
                SectionHeader("Largest cleanup items")
                if monitor.storageAdvice.isEmpty { Text(monitor.isScanning ? "Scanning…" : "Nothing over 1 GB found yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(monitor.storageAdvice.prefix(3)) { item in
                    let parts = Headline(item.title)
                    Menu {
                        ForEach(item.actions.filter { if case .copy = $0 { false } else { $0.isAvailable } }, id: \.self) { action in
                            Button(action.title, systemImage: action.symbol) { monitor.perform(action) }
                        }
                    } label: {
                        ValueRow(symbol: "folder", tint: .secondary, name: parts.name, value: parts.value ?? "", options: true)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityIdentifier("cleanup-\(item.id)")
                }
                Text("Click an item to show it in Finder or move it to the Trash. The menu has more options.").font(.caption).foregroundStyle(.secondary)
            }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private func rate(_ value: Double) -> String {
        value >= 1e6 ? String(format: "%.1f MB/s", value / 1e6) : String(format: "%.0f KB/s", value / 1e3)
    }
}

private struct SuggestionList: View {
    let suggestions: [Recommendation]
    let agents: [AIAgent]
    let perform: (Recommendation.Action) -> Void
    let ask: (AIAgent, Recommendation) -> Void
    @State private var expanded: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions").font(.subheadline.weight(.semibold))
            ForEach(suggestions.prefix(3)) { suggestion in
                let open = expanded.contains(suggestion.id), parts = Headline(suggestion.title)
                VStack(alignment: .leading, spacing: 8) {
                    // Collapsed by default so several suggestions fit on screen; the menu always shows the full text.
                    Button { toggle(suggestion.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: suggestion.symbol).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parts.name).font(.callout.weight(.semibold))
                                if let value = parts.value { Text(value).font(.caption).foregroundStyle(.secondary) }
                            }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                        }.contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityHint(open ? "Hide details" : "Show details")
                        .accessibilityIdentifier("suggestion-\(suggestion.id)")
                    if open {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(suggestion.detail.filter { !$0.hasPrefix("Command: ") && !$0.hasPrefix("Script: ") }, id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.textSelection(.enabled)
                    }
                    HStack {
                        // The panel footer already opens Activity Monitor.
                        ForEach(suggestion.actions.filter { $0.isAvailable && $0 != .openActivityMonitor }, id: \.self) { action in
                            Button(action.title) { perform(action) }.help(action.help)
                        }
                        if !agents.isEmpty {
                            Menu("Ask AI") {
                                ForEach(agents, id: \.self) { agent in Button(agent.name) { ask(agent, suggestion) } }
                            }.menuStyle(.button).fixedSize().help("Open a terminal session with this suggestion as the question")
                        }
                    }.buttonStyle(.bordered).controlSize(.small)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
            }
            if suggestions.count > 3 { Text("\(suggestions.count - 3) more in the menu").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func toggle(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }
}

/// Splits "Name — value" or "Name: value" titles so the name and the number can be styled apart.
private struct Headline {
    let name: String
    let value: String?
    init(_ title: String) {
        if let range = title.range(of: " — ", options: .backwards) ?? title.range(of: ": ") {
            name = String(title[..<range.lowerBound]); value = String(title[range.upperBound...])
        } else {
            name = title; value = nil
        }
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4) }
}

private struct ValueRow: View {
    let symbol: String
    let tint: Color
    let name: String
    let value: String
    var options = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(name).lineLimit(1).truncationMode(.middle).help(name)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(tint == .secondary ? Color.primary : tint)
            if options { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
        }.font(.callout).contentShape(.rect)
    }
}

private extension Recommendation.Action {
    var help: String {
        switch self {
        case .copy(let command): "Copies: \(command)"
        case .runScript(let script): "Opens Terminal and runs \(script.file). \(script.summary)"
        default: title
        }
    }
}

private struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(values.count - 1), y: rect.maxY - rect.height * min(100, max(0, value)) / 100)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
