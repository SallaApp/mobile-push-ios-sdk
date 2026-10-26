import Foundation

/// `Retry-After`: delta-seconds or an HTTP-date, clamped to `1…86_400` seconds.
package enum RetryAfter {
    /// The wait when a 429 carries no usable `Retry-After`.
    package static let defaultRateLimitDelay: Double = 60

    private static let httpDateFormatter: Locked<DateFormatter> = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return Locked(formatter)
    }()

    /// The clamped delay in seconds; nil when the header is absent or unreadable.
    package static func seconds(from header: String?, now: Double) -> Double? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let integer = Int(raw) {
            return clamp(Double(integer))
        }
        guard let date = httpDateFormatter.withLock({ $0.date(from: raw) }) else { return nil }
        return clamp(date.timeIntervalSince1970 - now)
    }

    private static func clamp(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 1 }
        return min(max(seconds, 1), 86_400)
    }
}
