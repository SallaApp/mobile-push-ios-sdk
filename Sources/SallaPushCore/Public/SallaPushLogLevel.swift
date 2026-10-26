import Foundation

/// How much SallaPush logs, from silent to most detailed.
///
/// An entry reaches a sink (the console or your log handler) when the sink's level is not `.off`
/// and the entry's level is at or below the sink's level. The console and the handler have separate levels.
@objc public enum SallaPushLogLevel: Int, Sendable {
    /// Nothing is logged.
    case off = 0
    /// Failures that need your attention.
    case error = 1
    /// Problems the SDK recovered from, and likely integration mistakes. The default level.
    case warn = 2
    /// Milestones such as registration, login and logout.
    case info = 3
    /// Decisions and skipped work, for debugging an integration.
    case debug = 4
    /// Everything, including notifications that belong to other SDKs.
    case verbose = 5
}

extension SallaPushLogLevel {
    /// Parses `off|error|warn|info|debug|verbose`, ignoring case and surrounding spaces; `warning` is accepted for
    /// `warn`. These are the names the Android SDK's `com.salla.push.LOG_LEVEL` accepts: the silent level is `off`
    /// on both SDKs, so `none` is not a level on either SDK.
    package init?(name: String) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off": self = .off
        case "error": self = .error
        case "warn", "warning": self = .warn
        case "info": self = .info
        case "debug": self = .debug
        case "verbose": self = .verbose
        default: return nil
        }
    }

    /// This value when it is one of the declared cases; nil for any other raw value. Objective-C and bridge callers
    /// can pass any integer, and an exhaustive switch over an undeclared value traps.
    package var validated: SallaPushLogLevel? {
        SallaPushLogLevel(rawValue: rawValue)
    }

    /// The lowercase name used in Info.plist and in log lines; `invalid(<raw>)` for an undeclared raw value.
    package var name: String {
        guard let level = validated else { return "invalid(\(rawValue))" }
        switch level {
        case .off: return "off"
        case .error: return "error"
        case .warn: return "warn"
        case .info: return "info"
        case .debug: return "debug"
        case .verbose: return "verbose"
        }
    }

    /// The sink rule: a sink at this level accepts an entry of `entryLevel`.
    package func admits(_ entryLevel: SallaPushLogLevel) -> Bool {
        self != .off && entryLevel != .off && entryLevel.rawValue <= rawValue
    }
}
