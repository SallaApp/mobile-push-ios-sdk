import Foundation

/// A value guarded by a lock. Callers keep the critical sections short, never call out of them, and never let an
/// app-supplied value (a closure or an object) be released inside one: its deinit may call SallaPush, which would
/// take the same lock again. Such values leave the critical section first, through `exchange` or a returned value.
package final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    package init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value.
    package func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    /// A copy of the current value.
    package var current: Value {
        withLock { $0 }
    }

    /// Replaces the value.
    package func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }

    /// Replaces the value and returns the old one, which the caller then releases outside the lock.
    @discardableResult
    package func exchange(_ newValue: Value) -> Value {
        withLock { value in
            defer { value = newValue }
            return value
        }
    }
}

/// Wraps a value that is handed between queues by code that guarantees exclusive use.
package struct UncheckedSendable<Value>: @unchecked Sendable {
    package let value: Value

    package init(_ value: Value) {
        self.value = value
    }
}
