import Foundation

/// A lock plus a flag. Every continuation resume and every app-supplied or system completion goes through one,
/// so a callback that fires twice never resumes or completes twice.
package final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    package init() {}

    /// True the first time it is called, false afterwards.
    package func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Bridges a callback-based start function to `async`. The continuation is resumed by the first callback only;
/// `onRepeat` is told about every later one.
package func onceContinuation<Value: Sendable>(
    onRepeat: @escaping @Sendable () -> Void = {},
    _ start: (@escaping @Sendable (Value) -> Void) -> Void
) async -> Value {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
        let once = Once()
        start { value in
            if once.claim() {
                continuation.resume(returning: value)
            } else {
                onRepeat()
            }
        }
    }
}
