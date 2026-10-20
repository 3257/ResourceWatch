import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()
    @Published var status = "Starting…"
    @Published var details = ""
    @Published var events: [String] = []
    @Published var notificationStatus = "Notifications not enabled"
    @Published var settings = WatchSettings.load() { didSet { settings.save() } }
    @Published var loginStatus = ""
    @Published var memorySummary = "RAM: waiting for sample"
    @Published var memoryDetails = ""
    @Published var memoryProcesses: [String] = []
    @Published var networkSummary = "Network: waiting for sample"
    @Published var networkDetails: [String] = []
    @Published var latest: Metrics?
    @Published var cpuHistory: [Double] = []
    @Published var currentWarnings: [String] = []
    @Published var samplingError: String?
    private var miniPanel: MiniPanelController?
    var menuBarSymbol: String { samplingError != nil || !currentWarnings.isEmpty ? "exclamationmark.triangle.fill" : "waveform.path.ecg" }
    var menuBarStats: String {
        guard let latest else { return "…" }
        let ram = latest.memoryTotal > 0 ? Double(latest.memoryUsed) / Double(latest.memoryTotal) * 100 : 0
        return String(format: "CPU %.0f%% · RAM %.0f%%", latest.cpu, ram)
    }
    func showMiniPanel() {
        if miniPanel == nil { miniPanel = MiniPanelController(monitor: self) }
        miniPanel?.show()
    }
    private var task: Task<Void, Never>?
    private var engine = AlertEngine()
    init() { start() }
    func start() {
        guard task == nil else { return }
        let sampler = SamplingWorker()
        task = Task {
            while !Task.isCancelled {
                do {
                    let metrics = try await sampler.sample()
                    accept(metrics)
                } catch { status = "Monitoring error"; details = error.localizedDescription; samplingError = error.localizedDescription }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status == .enabled ? "Starts at login" : "Login startup needs approval in System Settings"
        } catch { loginStatus = error.localizedDescription }
    }
    func testNotification() {
        send("ResourceWatch test", "CPU, memory, network and storage alerts will appear here.", verify: true)
    }
    func enableNotifications() {
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationStatus = allowed ? "Notifications enabled" : "Notifications denied — enable in System Settings"
            } catch { notificationStatus = error.localizedDescription }
        }
    }
    func refreshPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = settings.authorizationStatus == .authorized ? "Notifications enabled" : "Enable notifications to receive background alerts"
        }
    }
    private func accept(_ m: Metrics) {
        let now = Date(), gib = Double(1 << 30)
        latest = m; samplingError = nil
        currentWarnings = HealthSummary.warnings(m, settings: settings)
        cpuHistory.append(m.cpu)
        cpuHistory = Array(cpuHistory.suffix(60))
        memorySummary = String(format: "RAM: %.1f / %.0f GiB used", Double(m.memoryUsed) / gib, Double(m.memoryTotal) / gib)
        memoryDetails = String(format: "Compressed %.1f GiB · Wired %.1f GiB", Double(m.compressed) / gib, Double(m.wired) / gib)
        memoryProcesses = m.processSamples.sorted { $0.memory > $1.memory }.prefix(5).map {
            "\($0.name) · \(String(format: "%.1f", Double($0.memory) / gib)) GiB · PID \($0.identity.split(separator: ":")[0])"
        }
        networkSummary = String(format: "Network: ↓ %.1f · ↑ %.1f MB/s", m.network.download / 1e6, m.network.upload / 1e6)
        networkDetails = [String(format: "Session: ↓ %.2f · ↑ %.2f GB", Double(m.network.received) / 1e9, Double(m.network.sent) / 1e9), "Interfaces: \(m.network.interfaces.joined(separator: ", "))", "Wi-Fi/Ethernet traffic, including local transfers"]
        status = String(format: "CPU %.0f%% · %.0f GB free", m.cpu, Double(m.free) / 1e9)
        details = String(format: "CPU: %.1f%% of all cores\nMemory pressure: %@\nSwap: %.2f GiB\nHome volume: %.1f / %.1f GB free\n\nTop CPU processes (100%% = one core):\n%@", m.cpu, m.pressure >= 4 ? "critical" : m.pressure >= 2 ? "warning" : "normal", Double(m.swap) / gib, Double(m.free) / 1e9, Double(m.total) / 1e9, m.processes)
        for alert in engine.evaluate(m, settings: settings, now: now) {
            events.insert("\(now.formatted(date: .omitted, time: .shortened)) — \(alert.title)\n\(alert.body)", at: 0)
            events = Array(events.prefix(30))
            send(alert.title, alert.body)
        }
        if engine.storageGrowthActive { currentWarnings.append("Storage growing quickly") }
    }
    private func send(_ title: String, _ body: String, verify: Bool = false) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        Task {
            do {
                let center = UNUserNotificationCenter.current()
                let permission = await center.notificationSettings()
                guard permission.authorizationStatus == .authorized else { notificationStatus = "Notifications disabled — click Enable notifications"; return }
                let identifier = UUID().uuidString
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                notificationStatus = "Notification submitted successfully"
                if verify {
                    try await Task.sleep(for: .seconds(2))
                    let delivered = await center.deliveredNotifications()
                    notificationStatus = delivered.contains { $0.request.identifier == identifier }
                        ? "Test delivered to Notification Center"
                        : "Test submitted — check notification settings and Focus"
                }
            }
            catch { notificationStatus = "Notification failed: \(error.localizedDescription)" }
        }
    }
}

@main
struct ResourceWatchApp: App {
    @NSApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @StateObject private var monitor = Monitor.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra {
                Text("ResourceWatch").font(.headline)
                if let error = monitor.samplingError { Text("Monitoring error: \(error)") }
                Button("Show mini panel") { monitor.showMiniPanel() }
                Divider()
                ForEach(Array(monitor.details.components(separatedBy: "\n").prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                Menu(monitor.memorySummary) {
                    Text(monitor.memoryDetails)
                    Text("Used RAM is an estimate; alerts follow memory pressure")
                    Divider()
                    ForEach(Array(monitor.memoryProcesses.enumerated()), id: \.offset) { _, line in Text(line) }
                    Text("Process memory = resident size, not app footprint")
                }
                Menu(monitor.networkSummary) {
                    ForEach(Array(monitor.networkDetails.enumerated()), id: \.offset) { _, line in Text(line) }
                }
                Menu("Top processes") {
                    ForEach(Array(monitor.details.components(separatedBy: "\n").dropFirst(6).enumerated()), id: \.offset) { _, line in Text(line) }
                }
                Menu("Recent alerts") {
                    if monitor.events.isEmpty { Text("No alerts this session") }
                    ForEach(Array(monitor.events.enumerated()), id: \.offset) { _, event in
                        Menu(event.components(separatedBy: "\n")[0]) {
                            Text(event.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                        }
                    }
                }
                Divider()
                Button("Enable notifications") { monitor.enableNotifications() }
                    .accessibilityLabel("Enable notifications").accessibilityIdentifier("enableNotifications")
                Button("Send test notification") { monitor.testNotification() }
                    .accessibilityLabel("Send test notification").accessibilityIdentifier("testNotification")
                Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",")
                Button("Open Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                Divider()
                Button("Quit ResourceWatch") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: monitor.menuBarSymbol)
                if monitor.settings.showMenuBarStats { Text(monitor.menuBarStats).monospacedDigit() }
            }.accessibilityLabel("ResourceWatch\(monitor.currentWarnings.isEmpty ? "" : ", warning"): \(monitor.menuBarStats)")
        }.menuBarExtraStyle(.menu)
        Window("ResourceWatch Settings", id: "settings") {
                Form {
                    Section("Alerts") {
                    VStack(spacing: 14) {
                        ThresholdSlider(title: "Total CPU", value: $monitor.settings.cpuPercent, range: 10...100, step: 5, unit: "%")
                        ThresholdSlider(title: "Process CPU", value: $monitor.settings.processCPUPercent, range: 50...1800, step: 50, unit: "%")
                        ThresholdSlider(title: "Process memory", value: $monitor.settings.processMemoryGiB, range: 1...128, unit: "GiB")
                        ThresholdSlider(title: "Free space", value: $monitor.settings.diskFreeGB, range: 5...500, step: 5, unit: "GB")
                        ThresholdSlider(title: "Free space percentage", value: $monitor.settings.diskFreePercent, range: 1...50, unit: "%")
                        ThresholdSlider(title: "Storage growth", value: $monitor.settings.diskGrowthGB, range: 1...100, unit: "GB/hour")
                        ThresholdSlider(title: "Network", value: $monitor.settings.networkMBPerSecond, range: 1...1000, unit: "MB/sec")
                        ThresholdSlider(title: "CPU/process duration", value: $monitor.settings.sustainedSeconds, range: 10...600, step: 10, unit: "sec")
                        ThresholdSlider(title: "Repeat after", value: $monitor.settings.cooldownMinutes, range: 1...120, unit: "min")
                        Button("Restore defaults") { monitor.settings = WatchSettings() }
                    }
                    }
                    Section("Notifications and startup") {
                        Toggle("Show CPU and RAM in menu bar", isOn: $monitor.settings.showMenuBarStats)
                        Text(monitor.notificationStatus).font(.caption)
                        Button("Enable notifications") { monitor.enableNotifications() }
                        Button("Send test notification") { monitor.testNotification() }
                        Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { monitor.setLogin($0) }))
                        Text(monitor.loginStatus).font(.caption)
                    }
                }.formStyle(.grouped).frame(width: 450, height: 580).task { monitor.refreshPermission() }
        }.windowResizability(.contentSize)
    }
}

private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let unit: String

    private var selectedValue: String { "\(Int(value)) \(unit)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(selectedValue).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(selectedValue)
        }
    }
}

@MainActor
final class WatchDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Monitor.shared.start()
        Monitor.shared.refreshPermission()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
