import Foundation

/// Holds changes while a menu is open, because rebuilding an open menu closes it under the pointer.
@MainActor
final class MenuUpdateGate {
    private(set) var isHolding = false
    private var pending: [() -> Void] = []

    func submit(_ change: @escaping () -> Void) {
        if isHolding { pending.append(change) } else { change() }
    }

    /// Releasing runs the held changes in the order they arrived.
    func setHolding(_ holding: Bool) {
        isHolding = holding
        guard !holding else { return }
        let released = pending
        pending = []
        released.forEach { $0() }
    }
}
