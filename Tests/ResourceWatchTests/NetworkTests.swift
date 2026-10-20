import Foundation
import Testing
@testable import ResourceWatch

@Test func networkRatesTotalsAndCounterResets() {
    var tracker = NetworkTracker()
    let first = tracker.update(["en0": NetworkCounter(received: 5_000_000_000, sent: 0)], elapsed: 0)
    #expect(first.download == 0 && first.received == 0)
    let second = tracker.update(["en0": NetworkCounter(received: 5_100_000_000, sent: 10_000_000)], elapsed: 10)
    #expect(second.download == 10_000_000 && second.upload == 1_000_000)
    #expect(second.received == 100_000_000 && second.sent == 10_000_000)
    let reset = tracker.update(["en0": NetworkCounter(received: 0, sent: 0), "en1": NetworkCounter(received: 20_000_000_000, sent: 0)], elapsed: 10)
    #expect(reset.download == 0 && reset.upload == 0 && reset.received == second.received)
    let removed = tracker.update([:], elapsed: 10)
    #expect(removed.download == 0 && removed.interfaces.isEmpty)
    let reattached = tracker.update(["en0": NetworkCounter(received: 20_000_000_000, sent: 0)], elapsed: 10)
    #expect(reattached.download == 0)
}
@Test func sustainedNetworkAlertAndCooldown() {
    var engine = AlertEngine()
    var m = Metrics(cpu: 0, pressure: 1, swap: 0, free: 200_000_000_000, total: 1_000_000_000_000, processes: "")
    m.network.upload = 30_000_000
    var alerts: [WatchAlert] = []
    for second in stride(from: 0, through: 120, by: 10) {
        alerts += engine.evaluate(m, settings: WatchSettings(), now: Date(timeIntervalSince1970: Double(second)))
    }
    #expect(alerts.map(\.title) == ["Sustained heavy network traffic"])
}
@Test func settingsUpgradePreservesEarlierThresholds() throws {
    let suite = "ResourceWatchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data(#"{"cpuPercent":95,"diskFreeGB":50}"#.utf8), forKey: "watchSettings")
    let loaded = WatchSettings.load(defaults)
    #expect(loaded.cpuPercent == 95 && loaded.diskFreeGB == 50 && loaded.networkMBPerSecond == 25)
}
