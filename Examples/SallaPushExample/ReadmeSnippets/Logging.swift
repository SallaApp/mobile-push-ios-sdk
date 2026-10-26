import SallaPush

// README "Logging": levels and the log handler.

@MainActor
final class Diagnostics {
    func enableVerboseLogs() {
        // snippet:log-level
        SallaPush.Debug.logLevel = .verbose
        // end-snippet
    }

    func forwardErrors() {
        // snippet:log-handler
        SallaPush.Debug.setLogHandler(level: .error) { entry in
            Telemetry.report(source: "sallapush", code: entry.code, message: entry.message, metadata: entry.metadata)
        }
        // end-snippet
    }
}
