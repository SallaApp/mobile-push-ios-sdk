import Foundation

/// ISO-8601 timestamps in UTC with milliseconds (`2026-10-02T09:30:00.123Z`), the form push-service needs: it cuts an
/// event's `at` at the first `.` before it stores it, so a value without a fraction keeps its `Z` and the whole batch
/// is lost. Reading also takes the form without a fraction, which an earlier (pre-release) version wrote.
package enum ISO8601 {
    /// The process's formatters: with milliseconds (written and read) and without a fraction (read only).
    private struct Formatters {
        let milliseconds: ISO8601DateFormatter
        let wholeSeconds: ISO8601DateFormatter
    }

    private static let formatters: Locked<Formatters> = {
        let milliseconds = ISO8601DateFormatter()
        milliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        milliseconds.timeZone = TimeZone(secondsFromGMT: 0)
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        wholeSeconds.timeZone = TimeZone(secondsFromGMT: 0)
        return Locked(Formatters(milliseconds: milliseconds, wholeSeconds: wholeSeconds))
    }()

    /// Formats a time given in seconds since 1970, to the nearest millisecond. Reading the text back and formatting it
    /// again gives the same text.
    package static func string(from seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        return formatters.withLock { $0.milliseconds.string(from: date) }
    }

    /// Parses a timestamp with a zone designator, with or without a fraction of a second; nil when it is not one.
    package static func seconds(from string: String) -> Double? {
        formatters.withLock { $0.milliseconds.date(from: string) ?? $0.wholeSeconds.date(from: string) }?.timeIntervalSince1970
    }
}
