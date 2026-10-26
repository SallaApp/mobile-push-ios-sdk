import Foundation

/// Schedules one-shot work items. Injected so tests advance time by hand.
package protocol Scheduler: Sendable {
    /// Runs `item` on `queue` after `seconds` (clamped to `0…86_400`). Cancelling the item cancels the run.
    func schedule(after seconds: Double, on queue: DispatchQueue, _ item: DispatchWorkItem)
}

/// Schedules with `asyncAfter`. No dispatch sources are ever created.
package struct DispatchScheduler: Scheduler {
    package init() {}

    package func schedule(after seconds: Double, on queue: DispatchQueue, _ item: DispatchWorkItem) {
        let nanoseconds = Int(Duration.clamped(seconds) * 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: item)
    }
}
