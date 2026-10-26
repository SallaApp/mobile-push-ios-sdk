import Foundation

/// Retry timing shared by every operation.
package enum Backoff {
    /// Transient failures in one process before an operation waits for the next trigger (launch, foreground, network).
    package static let attemptsPerProcess = 6

    /// `min(3600, 2 × 2^(attempt − 1)) × U(0.5, 1.0)` seconds, with the exponent clamped at 12.
    /// - Parameters:
    ///   - attempt: the failed attempt count, starting at 1.
    ///   - random: a uniform value in `0…1` used for the jitter.
    package static func delay(attempt: Int, random: Double) -> Double {
        // `attempt - 1` is only computed when it cannot overflow.
        let exponent = attempt <= 1 ? 0 : Double(min(attempt - 1, 12))
        let base = min(3_600, 2 * pow(2, exponent))
        let unit = random.isFinite ? min(max(random, 0), 1) : 1
        return base * (0.5 + 0.5 * unit)
    }
}
