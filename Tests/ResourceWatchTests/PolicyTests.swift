import Testing
import Foundation
@testable import ResourceWatch

@Test func samplerUsesFootprintInsteadOfResidentSize() throws {
    let footprint: UInt64 = 123456
    let m = try Sampler(memoryFootprint: { _ in footprint }).sample()
    let ownProcess = try #require(m.processSamples.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
    #expect(ownProcess.memory == footprint)
    #expect(m.processSamples.allSatisfy { $0.memory == footprint })
}

@Test func unavailableFootprintsDoNotFallBackToResidentSize() throws {
    let m = try Sampler(memoryFootprint: { _ in nil }).sample()
    #expect(m.processSamples.isEmpty)
    #expect(m.memoryUsed > 0)
}

@Test func nativeFootprintCanReadOwnProcessAndRejectsMissingProcess() throws {
    let footprint = try #require(processMemoryFootprint(ProcessInfo.processInfo.processIdentifier))
    #expect(footprint > 0)
    #expect(processMemoryFootprint(-1) == nil)
}

@Test func nativeProcessCPUMeasuresOneBusyCore() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer { child.terminate(); child.waitUntilExit() }
    let sampler = Sampler()
    _ = try sampler.sample()
    Thread.sleep(forTimeInterval: 0.4)
    let m = try sampler.sample()
    let row = try #require(m.processSamples.first { $0.identity.hasPrefix("\(child.processIdentifier):") })
    #expect(row.cpu > 30 && row.cpu < 180)
}
@Test func liveSamplerProducesValidMetrics() throws {
    let sampler = Sampler()
    let m = try sampler.sample()
    #expect(m.cpu >= 0 && m.cpu <= 100)
    #expect([1, 2, 4].contains(m.pressure))
    #expect(m.total > 0 && m.free >= 0 && m.free <= m.total)
    #expect(!m.processes.isEmpty)
    #expect(m.memoryTotal > 0 && m.memoryUsed > 0 && m.memoryUsed <= m.memoryTotal)
    #expect(m.wired > 0)
    #expect(m.network.download >= 0 && m.network.upload >= 0)
    // Offline Macs need not expose an up physical interface.
    #expect(m.network.interfaces.allSatisfy { $0.hasPrefix("en") })
}
@Test func sustainedAndCooldown() {
    var p = AlertPolicy(); let t = Date()
    let initial = p.evaluate("cpu", active: true, now: t, sustained: 60)
    let early = p.evaluate("cpu", active: true, now: t.addingTimeInterval(59), sustained: 60)
    let ready = p.evaluate("cpu", active: true, now: t.addingTimeInterval(60), sustained: 60)
    let repeated = p.evaluate("cpu", active: true, now: t.addingTimeInterval(61), sustained: 60)
    let cooled = p.evaluate("cpu", active: true, now: t.addingTimeInterval(960), sustained: 60)
    #expect(!initial && !early && ready && !repeated && cooled)
}
@Test func recoveryResetsDuration() {
    var p = AlertPolicy(); let t = Date()
    _ = p.evaluate("cpu", active: true, now: t, sustained: 60)
    _ = p.evaluate("cpu", active: false, now: t.addingTimeInterval(59), sustained: 60)
    let recovered = p.evaluate("cpu", active: true, now: t.addingTimeInterval(61), sustained: 60)
    #expect(!recovered)
}
