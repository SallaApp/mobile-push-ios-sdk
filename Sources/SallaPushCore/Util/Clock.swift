import Foundation

/// Wall-clock time in seconds since 1970. Injected so tests control time.
package protocol Clock: Sendable {
    func now() -> Double
}

/// The device clock.
package struct SystemClock: Clock {
    package init() {}

    package func now() -> Double {
        Date().timeIntervalSince1970
    }
}

/// Durations are clamped before any conversion, so a negative, non-finite or huge value can never trap.
package enum Duration {
    /// The longest timer the SDK ever schedules: one day.
    package static let maximum: Double = 86_400

    /// `seconds` clamped to `0…86_400`; non-finite values become 0.
    package static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), maximum)
    }
}
