import Foundation
import SallaPushCore

/// Logging controls. Console output goes to the unified log (subsystem `com.salla.push`).
@objc public final class SallaPushDebug: NSObject {
    // Stateless, so one instance serves every thread.
    private static let instance = UncheckedSendable(SallaPushDebug())
    static var shared: SallaPushDebug { instance.value }

    override init() {
        super.init()
    }

    /// The console log level, changeable at runtime; it overrides the configuration and Info.plist.
    /// `.off` silences the console only; the log handler has its own level. A value that is not a declared level is
    /// ignored with a warning.
    @objc public var logLevel: SallaPushLogLevel {
        get { Runtime.shared.logger.consoleLevel }
        set { Runtime.shared.setRuntimeLogLevel(newValue) }
    }

    /// Sets the console log level, as setting `logLevel` does.
    public func setLogLevel(_ level: SallaPushLogLevel) {
        Runtime.shared.setRuntimeLogLevel(level)
    }

    /// Receives every entry at or below `level` (default `.warn`) on a private serial queue, never main. The first
    /// handler also receives the warnings and errors logged before it (at most 100), so start-up problems reach a
    /// handler set right after `initialize`. The queue holds 500 entries; when the handler falls behind, the oldest
    /// are dropped and one `log.dropped` entry reports how many. Pass nil to remove the handler. The handler must not
    /// throw. Info entries describe the device (`status.launch`, `status.changed`), with the full push token and the
    /// customer's id in a development build (the sandbox APNs environment) whose Info.plist turns on the switch
    /// `SallaPushLogFullIdentifiers`: don't forward them to third parties.
    @objc(setLogHandlerWithLevel:handler:)
    public func setLogHandler(level: SallaPushLogLevel = .warn, _ handler: (@Sendable (SallaPushLogEntry) -> Void)?) {
        Runtime.shared.setLogHandler(level: level, handler)
    }
}
