import Foundation
import Testing
@testable import ResourceWatch

private func baseline() -> Metrics {
    Metrics(cpu: 5, pressure: 1, swap: 10 << 30, free: 200_000_000_000, total: 1_000_000_000_000, processes: "", processSamples: [])
}
private func run(_ engine: inout AlertEngine, _ metrics: Metrics, seconds: Int, settings: WatchSettings = WatchSettings()) -> [WatchAlert] {
    engine.evaluate(metrics, settings: settings, now: Date(timeIntervalSince1970: Double(seconds)))
}
@Test func quietNormalAndHighSwap() {
    var engine = AlertEngine()
    for time in stride(from: 0, through: 120, by: 10) {
        let alerts = run(&engine, baseline(), seconds: time)
        #expect(alerts.isEmpty)
    }
}
@Test func catchesRunawayWithIdleMachineAndMemoryHog() {
    var engine = AlertEngine(), m = baseline()
    m.processSamples = [ProcessSample(identity: "12:1:0", name: "fixture", cpu: 200, memory: 9 << 30)]
    var alerts: [WatchAlert] = []
    for time in stride(from: 0, through: 60, by: 10) { alerts += run(&engine, m, seconds: time) }
    #expect(alerts.count == 2)
    #expect(alerts.contains { $0.title.contains("CPU") })
    #expect(alerts.contains { $0.title.contains("memory") })
    let repeated = run(&engine, m, seconds: 70)
    #expect(repeated.isEmpty)
}
@Test func pressureAndLowDisk() {
    var engine = AlertEngine(), m = baseline()
    m.pressure = 2; m.free = 10_000_000_000
    var alerts: [WatchAlert] = []
    for time in stride(from: 0, through: 30, by: 10) { alerts += run(&engine, m, seconds: time) }
    #expect(Set(alerts.map(\.title)) == ["Memory pressure is high", "Storage is running low"])
}
@Test func storageGrowthAndWindowExpiry() {
    var engine = AlertEngine(), m = baseline()
    var alerts: [WatchAlert] = []
    for time in stride(from: 0, through: 300, by: 10) {
        m.free = 200_000_000_000 - Int64(time) * 40_000_000
        alerts += run(&engine, m, seconds: time)
    }
    #expect(alerts.count == 1)
    #expect(alerts.first?.title == "Storage is growing quickly")
    alerts = []
    for time in stride(from: 310, through: 4200, by: 10) { alerts += run(&engine, m, seconds: time) }
    #expect(alerts.filter { $0.title == "Storage is growing quickly" }.count <= 3)
    let expired = run(&engine, m, seconds: 4210)
    #expect(expired.isEmpty)
}
@Test func sampleGapAndPIDReuseResetDuration() {
    var engine = AlertEngine(), m = baseline()
    m.cpu = 99
    _ = run(&engine, m, seconds: 0)
    let afterSleep = run(&engine, m, seconds: 120)
    #expect(afterSleep.isEmpty)
    m.cpu = 5
    m.processSamples = [ProcessSample(identity: "12:1:0", name: "fixture", cpu: 200, memory: 0)]
    for time in stride(from: 130, through: 180, by: 10) { _ = run(&engine, m, seconds: time) }
    m.processSamples[0].identity = "12:2:0"
    let reused = run(&engine, m, seconds: 190)
    #expect(reused.isEmpty)
}
@Test func settingsPersistInIsolatedStore() throws {
    let suite = "ResourceWatchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = WatchSettings(); settings.processCPUPercent = 250
    settings.save(defaults)
    #expect(WatchSettings.load(defaults) == settings)
}
