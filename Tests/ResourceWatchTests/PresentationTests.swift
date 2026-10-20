import Foundation
import Testing
@testable import ResourceWatch

@Test func warningStateTracksCurrentConditionsAndRecovery() {
    var m = Metrics(cpu: 10, pressure: 1, swap: 8 << 30, free: 200_000_000_000, total: 1_000_000_000_000, processes: "")
    #expect(HealthSummary.warnings(m, settings: WatchSettings()).isEmpty)
    m.cpu = 99; m.pressure = 4; m.free = 1_000_000_000; m.network.upload = 30_000_000
    m.processSamples = [ProcessSample(identity: "12:0:0", name: "fixture", cpu: 200, memory: 9 << 30)]
    #expect(Set(HealthSummary.warnings(m, settings: WatchSettings())) == ["High CPU", "Memory pressure", "Low storage", "Heavy network traffic", "Busy process", "Large process memory"])
    m.cpu = 10; m.pressure = 1; m.free = 200_000_000_000; m.network.upload = 0; m.processSamples = []
    #expect(HealthSummary.warnings(m, settings: WatchSettings()).isEmpty)
}

@Test func showingMenuStatsDoesNotResetAlertTiming() {
    var engine = AlertEngine(), settings = WatchSettings()
    let m = Metrics(cpu: 99, pressure: 1, swap: 0, free: 200_000_000_000, total: 1_000_000_000_000, processes: "")
    var alerts: [WatchAlert] = []
    for second in stride(from: 0, through: 60, by: 10) {
        if second == 30 { settings.showMenuBarStats = true }
        alerts += engine.evaluate(m, settings: settings, now: Date(timeIntervalSince1970: Double(second)))
    }
    #expect(alerts.map(\.title) == ["Sustained high CPU"])
}
