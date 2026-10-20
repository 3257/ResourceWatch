import Foundation

struct AlertPolicy {
    struct State { var since: Date; var lastAlert: Date? }
    private var states: [String: State] = [:]
    var cooldown: TimeInterval = 900
    mutating func retain(_ keys: Set<String>) { states = states.filter { keys.contains($0.key) } }
    mutating func evaluate(_ key: String, active: Bool, now: Date, sustained: TimeInterval) -> Bool {
        guard active else { states[key] = nil; return false }
        var state = states[key] ?? State(since: now)
        guard now.timeIntervalSince(state.since) >= sustained,
              state.lastAlert.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else {
            states[key] = state; return false
        }
        state.lastAlert = now; states[key] = state; return true
    }
}
