import Foundation
import Testing
@testable import ResourceWatch

private func sample(_ pid: Int32, _ parent: Int32, _ name: String, gib: Double, cpu: Double = 0) -> ProcessSample {
    ProcessSample(identity: "\(pid):0:0", name: name, cpu: cpu, memory: UInt64(gib * Double(1 << 30)), pid: pid, parentPID: parent)
}

@Test func helpersGroupUnderTheirApp() throws {
    let samples = [
        sample(100, 1, "Google Chrome", gib: 1),
        sample(101, 100, "Google Chrome Helper (Renderer)", gib: 4),
        sample(102, 100, "Google Chrome Helper (Renderer)", gib: 3),
        sample(103, 100, "Google Chrome Helper (GPU)", gib: 1),
        sample(200, 1, "Terminal", gib: 0.2),
        sample(201, 200, "login", gib: 0),
        sample(202, 201, "zsh", gib: 0),
        sample(203, 202, "swift-build", gib: 0.5),
        sample(204, 203, "swift-frontend", gib: 2)
    ]
    let groups = Advisor.groups(samples)
    let chrome = try #require(groups.first { $0.name == "Google Chrome" })
    #expect(chrome.members.count == 4)
    #expect(chrome.memory == 9 << 30)
    #expect(chrome.largest?.pid == 101)
    #expect(chrome.rootPID == 100)
    let build = try #require(groups.first { $0.name == "swift-build" })
    #expect(build.members.map(\.pid).sorted() == [203, 204])
    #expect(groups.first { $0.name == "Terminal" }?.members.map(\.pid).sorted() == [200, 201])
}

@Test func webKitProcessesFromLaunchdShareOneGroup() {
    let groups = Advisor.groups([sample(10, 1, "com.apple.WebKit.WebContent", gib: 3), sample(11, 1, "com.apple.WebKit.WebContent", gib: 6), sample(12, 1, "com.apple.WebKit.GPU", gib: 1)])
    #expect(groups.count == 1)
    #expect(groups.first?.name == "Safari and WebKit pages")
    #expect(groups.first?.rootPID == 11)
}

@Test func adviceNamesTheGroupTheLargestChildAndATip() throws {
    var m = Metrics(cpu: 10, pressure: 1, swap: 0, free: 0, total: 0, processes: "")
    m.processSamples = [sample(100, 1, "Google Chrome", gib: 1), sample(101, 100, "Google Chrome Helper (Renderer)", gib: 5), sample(102, 100, "Google Chrome Helper (Renderer)", gib: 3), sample(300, 1, "Notes", gib: 0.3)]
    let advice = Advisor.processAdvice(m, settings: WatchSettings())
    let chrome = try #require(advice.first)
    #expect(advice.count == 1)
    #expect(chrome.title == "Google Chrome: 9.0 GiB RAM in 3 processes")
    #expect(chrome.detail.contains("Largest: Google Chrome Helper (Renderer) — 5.0 GiB, PID 101"))
    #expect(chrome.detail.contains { $0.contains("Task Manager (Shift+Esc)") })
    #expect(chrome.actions == [.activate(100)])
    #expect(Advisor.processHint(identity: "101:0:0", samples: m.processSamples)?.hasPrefix("Google Chrome uses 9.0 GiB in 3 processes.") == true)
}

@Test func busyGroupsReportCPUAndCopyableCommands() {
    var m = Metrics(cpu: 10, pressure: 1, swap: 0, free: 0, total: 0, processes: "")
    m.processSamples = [sample(50, 1, "launchd_sim", gib: 0.1, cpu: 90), sample(51, 50, "SpringBoard", gib: 0.1, cpu: 90)]
    let advice = Advisor.processAdvice(m, settings: WatchSettings())
    #expect(advice.map(\.title) == ["launchd_sim: 0.2 GiB RAM in 2 processes · 180% CPU"])
    #expect(advice.first?.actions == [.copy("xcrun simctl shutdown all")])
    #expect(advice.first?.detail.last == "Command: xcrun simctl shutdown all")
    m.processSamples = [sample(50, 1, "launchd_sim", gib: 0.1, cpu: 40)]
    #expect(Advisor.processAdvice(m, settings: WatchSettings()).isEmpty)
}
