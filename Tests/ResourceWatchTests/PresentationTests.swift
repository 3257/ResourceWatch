import Foundation
import Testing
import AppKit
@testable import ResourceWatch

@Test @MainActor func statusIconKeepsPulseAndUsesColoredWarningDot() throws {
    for dark in [false, true] {
        let normal = StatusIcon.make(hasWarning: false, dark: dark)
        let warning = StatusIcon.make(hasWarning: true, dark: dark)
        #expect(normal.size == warning.size)
        #expect(!warning.isTemplate)
        let normalData = try #require(normal.tiffRepresentation)
        let warningData = try #require(warning.tiffRepresentation)
        let normalBitmap = try #require(NSBitmapImageRep(data: normalData))
        let warningBitmap = try #require(NSBitmapImageRep(data: warningData))
        func badgeColor(_ bitmap: NSBitmapImageRep) throws -> NSColor {
            let x = Int(Double(bitmap.pixelsWide) * 23.5 / 26)
            let y = bitmap.pixelsHigh / 2
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        }
        let clear = try badgeColor(normalBitmap), red = try badgeColor(warningBitmap)
        #expect(clear.alphaComponent < 0.1)
        #expect(red.alphaComponent > 0.9 && red.redComponent > 0.7 && red.greenComponent < 0.5)
    }
}

@Test func warningSummaryExplainsNumbersAndResponsibleProcesses() {
    var m = Metrics(cpu: 90, pressure: 4, swap: 0, free: 10_000_000_000, total: 1_000_000_000_000, processes: "")
    m.processSamples = [ProcessSample(identity: "12:0:0", name: "FixtureCompiler", cpu: 500, memory: 9 << 30)]
    m.network.upload = 30_000_000
    let details = HealthSummary.warningDetails(m, settings: WatchSettings())
    #expect(details.contains("CPU 90% — above 85%"))
    #expect(details.contains("FixtureCompiler: 500% CPU (one core = 100%)"))
    #expect(details.contains("FixtureCompiler: 9.0 GiB RAM"))
    #expect(details.contains("Critical memory pressure"))
    #expect(details.contains("Low storage: 10.0 GB free (1%)"))
    #expect(details.contains("Network: ↓ 0.0 / ↑ 30.0 MB/s"))
    m.cpu = 0; m.pressure = 1; m.free = 200_000_000_000; m.processSamples = []; m.network.upload = 0
    #expect(HealthSummary.warningDetails(m, settings: WatchSettings()).isEmpty)
}

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
