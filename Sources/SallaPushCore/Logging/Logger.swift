import Foundation
import os

/// The stable log codes (scripts/log-catalogue.txt, the iOS ones). The raw value is the code string apps can match on.
package enum LogCode: String, CaseIterable, Sendable {
    case initStarted = "init.started"
    case initInvalidAppId = "init.invalid_app_id"
    case initAppIdChanged = "init.app_id_changed"
    case initDrainStarted = "init.drain_started"
    case initBufferFull = "init.buffer_full"
    case initNoDelegate = "init.no_delegate"
    case configNoAppGroup = "config.no_app_group"
    case statusLaunch = "status.launch"
    case statusChanged = "status.changed"
    case consentWaiting = "consent.waiting"
    case consentGiven = "consent.given"
    case consentRevoked = "consent.revoked"
    case apiInvalidArgument = "api.invalid_argument"
    case apiCallbackRepeated = "api.callback_repeated"
    case tokenReceived = "token.received"
    case tokenUnchanged = "token.unchanged"
    case tokenInvalid = "token.invalid"
    case tokenMissing = "token.missing"
    case tokenRegistrationFailed = "token.registration_failed"
    case registerOk = "register.ok"
    case registerReregistering = "register.reregistering"
    case registerDormant = "register.dormant"
    case updateSent = "update.sent"
    case heartbeatSent = "heartbeat.sent"
    case permissionChanged = "permission.changed"
    case subscriptionOptedOut = "subscription.opted_out"
    case subscriptionOptedIn = "subscription.opted_in"
    case loginQueued = "login.queued"
    case loginOk = "login.ok"
    case loginSkippedSame = "login.skipped_same"
    case loginSwitched = "login.switched"
    case loginRejected = "login.rejected"
    case logoutQueued = "logout.queued"
    case logoutOk = "logout.ok"
    case logoutSkipped = "logout.skipped"
    case identityTokenNeeded = "identity.token_needed"
    case identityClientError = "identity.client_error"
    case tagsFlushed = "tags.flushed"
    case tagsNormalized = "tags.normalized"
    case tagsInvalidKey = "tags.invalid_key"
    case tagsValueTruncated = "tags.value_truncated"
    case tagsLimit = "tags.limit"
    case tagsRejectedKey = "tags.rejected_key"
    case eventsFlushed = "events.flushed"
    case eventsDropped = "events.dropped"
    case eventsQueueFull = "events.queue_full"
    case inboxIngested = "inbox.ingested"
    case inboxInvalidFile = "inbox.invalid_file"
    case netRetry = "net.retry"
    case netRetryExhausted = "net.retry_exhausted"
    case netRateLimited = "net.rate_limited"
    case netClientError = "net.client_error"
    case netRedirectRefused = "net.redirect_refused"
    case netInvalidResponse = "net.invalid_response"
    case netRoutesClosed = "net.routes_closed"
    case storageKeychainLocked = "storage.keychain_locked"
    case storageFailed = "storage.failed"
    case storageStateReset = "storage.state_reset"
    case notifForeign = "notif.foreign"
    case notifParseFailed = "notif.parse_failed"
    case notifUnknownVersion = "notif.unknown_version"
    case notifOffMainThread = "notif.off_main_thread"
    case notifDisplayFailed = "notif.display_failed"
    case notifSuppressed = "notif.suppressed"
    case notifClickQueued = "notif.click_queued"
    case notifClickDelivered = "notif.click_delivered"
    case badgeCleared = "badge.cleared"
    case badgeSet = "badge.set"
    case badgeZeroSkipped = "badge.zero_skipped"
    case lifecycleBackgroundExpired = "lifecycle.background_expired"
    case logDropped = "log.dropped"
    case nseAttachmentFailed = "nse.attachment_failed"
    case nseExpired = "nse.expired"
    case nseReplacedRequest = "nse.replaced_request"
    case nseReceivedSent = "nse.received_sent"
    case nseReceivedDeferred = "nse.received_deferred"
    case nseBadgeSet = "nse.badge_set"
    case nseBadgeSkipped = "nse.badge_skipped"

    /// The catalogue level of the code.
    package var level: SallaPushLogLevel {
        switch self {
        case .initInvalidAppId, .registerDormant, .identityClientError, .netClientError, .netRedirectRefused,
             .storageFailed, .storageStateReset:
            return .error
        case .initAppIdChanged, .initBufferFull, .initNoDelegate, .apiInvalidArgument, .tokenInvalid,
             .tokenMissing, .tokenRegistrationFailed, .loginRejected, .identityTokenNeeded, .tagsInvalidKey,
             .tagsValueTruncated, .tagsLimit, .tagsRejectedKey, .eventsDropped, .eventsQueueFull, .netRetryExhausted,
             .netRateLimited, .netInvalidResponse, .netRoutesClosed, .storageKeychainLocked, .notifParseFailed,
             .notifUnknownVersion, .notifOffMainThread, .notifDisplayFailed, .lifecycleBackgroundExpired,
             .logDropped, .nseAttachmentFailed, .nseExpired:
            return .warn
        case .initStarted, .initDrainStarted, .configNoAppGroup, .statusLaunch, .statusChanged, .consentWaiting,
             .consentGiven, .consentRevoked, .tokenReceived, .registerOk, .registerReregistering, .permissionChanged,
             .subscriptionOptedOut, .subscriptionOptedIn, .loginOk, .loginSwitched, .logoutQueued, .logoutOk,
             .netRetry, .nseReceivedDeferred, .nseBadgeSkipped:
            return .info
        case .apiCallbackRepeated, .tokenUnchanged, .updateSent, .heartbeatSent, .loginQueued,
             .loginSkippedSame, .logoutSkipped, .tagsFlushed, .tagsNormalized, .eventsFlushed, .inboxIngested,
             .inboxInvalidFile, .notifClickQueued, .notifClickDelivered, .notifSuppressed, .badgeCleared, .badgeSet,
             .badgeZeroSkipped, .nseReplacedRequest, .nseReceivedSent, .nseBadgeSet:
            return .debug
        case .notifForeign:
            return .verbose
        }
    }

    /// The category of the code.
    package var category: String {
        switch rawValue.prefix(while: { $0 != "." }) {
        case "consent": return "consent"
        case "token", "register", "update", "heartbeat", "permission", "subscription": return "registration"
        case "login", "logout", "identity": return "identity"
        case "tags": return "tags"
        case "events", "inbox": return "events"
        case "net": return "network"
        case "storage": return "storage"
        case "notif", "badge": return "notifications"
        case "nse": return "extension"
        default: return "lifecycle"
        }
    }
}

/// The Info.plist `SallaPushLogLevel` value as found, before it is parsed.
package enum ConfiguredLogLevel: Sendable, Equatable {
    /// A string, which should name a level.
    case text(String)
    /// A value of another type, described for the log line (`a number (5)`, `a boolean`, `an array`…).
    case notText(String)
}

/// Metadata keys a log entry may carry. Any other key is dropped.
package enum LogMetadataKey {
    package static let httpStatus = "http_status"
    package static let errorCode = "error_code"
    package static let requestId = "request_id"
    package static let deviceId = "device_id"
    package static let appId = "app_id"
    package static let attempt = "attempt"
    package static let delay = "delay_s"
    package static let route = "route"
    package static let reason = "reason"
    package static let count = "count"

    package static let allowed: Set<String> = [
        httpStatus, errorCode, requestId, deviceId, appId, attempt, delay, route, reason, count,
    ]
}

/// The SDK logger: leveled, redacted by construction (no secret reaches an entry, and the full push token and the
/// customer's id reach only the info status lines, `status.launch` and `status.changed`, and only with the Info.plist
/// switch `SallaPushLogFullIdentifiers` in the sandbox APNs environment), with an independent console level and handler
/// level. Every code is logged at its level in the shared log catalogue (scripts/log-catalogue.txt), so a code always
/// has one meaning and one level.
///
/// Console output goes to `os.Logger` (subsystem `com.salla.push`). The handler runs on a private serial queue
/// behind a bounded buffer: on overflow the oldest entries are dropped and one `log.dropped` entry reports the count.
/// The app logger keeps the first warnings and errors logged before any handler exists and hands them to the first
/// handler, so start-up problems (an invalid app id, say) reach a handler installed right after `initialize`. Debug and
/// verbose entries are never kept, so their messages are built only when a sink accepts them.
package final class SDKLogger: @unchecked Sendable {
    /// Writes one formatted line to the console.
    package typealias ConsoleSink = @Sendable (_ level: SallaPushLogLevel, _ category: String, _ line: String) -> Void
    /// Receives every entry that any sink accepts, synchronously; used by tests and by the extension.
    package typealias Tap = @Sendable (SallaPushLogEntry) -> Void
    /// The app's log handler.
    package typealias Handler = @Sendable (SallaPushLogEntry) -> Void

    /// The process-wide logger of the app SDK.
    package static let shared = SDKLogger(keepsEarlyEntries: true)

    /// Entries waiting for the handler before the oldest are dropped.
    package static let handlerCapacity = 500

    /// Entries kept for the first handler, oldest first; later ones are not kept.
    package static let earlyEntryCapacity = 100

    /// The most detailed level kept for the first handler: the default handler level.
    package static let earlyEntryLevel = SallaPushLogLevel.warn

    private let lock = NSLock()
    private var runtimeLevel: SallaPushLogLevel?
    private var configurationLevel: SallaPushLogLevel?
    private var plistLevel: SallaPushLogLevel?
    private var plistLevelRead = false
    private let plistLevelReader: @Sendable () -> ConfiguredLogLevel?
    private let consoleSink: ConsoleSink
    private let categoryOverride: String?
    private var tap: Tap?
    private var handler: Handler?
    private var handlerLevel: SallaPushLogLevel = .warn
    // nil once a handler was installed, or when this logger keeps no early entries.
    private var earlyEntries: [SallaPushLogEntry]?
    private var pending: [SallaPushLogEntry] = []
    private var droppedCount = 0
    private var draining = false
    private var onceKeys: Set<String> = []
    private let handlerQueue: DispatchQueue

    /// - Parameters:
    ///   - categoryOverride: forces one category on every entry (the extension logs with `extension`).
    ///   - plistLevelReader: returns the Info.plist `SallaPushLogLevel` value; read lazily on the first log call. A value
    ///     that is not a level is reported once (WARN `api.invalid_argument`) and ignored.
    ///   - consoleSink: where console lines go.
    ///   - keepsEarlyEntries: keeps the first entries logged before any handler for the first handler.
    package init(categoryOverride: String? = nil,
                 plistLevelReader: @escaping @Sendable () -> ConfiguredLogLevel? = SDKLogger.mainBundleLogLevel,
                 consoleSink: @escaping ConsoleSink = SDKLogger.systemConsole,
                 handlerQueue: DispatchQueue = DispatchQueue(label: "com.salla.push.log", qos: .utility),
                 keepsEarlyEntries: Bool = false) {
        self.categoryOverride = categoryOverride
        self.plistLevelReader = plistLevelReader
        self.consoleSink = consoleSink
        self.handlerQueue = handlerQueue
        earlyEntries = keepsEarlyEntries ? [] : nil
    }

    // MARK: - Levels

    /// The effective console level: runtime setter, then explicit configuration, then Info.plist, then `.warn`.
    package var consoleLevel: SallaPushLogLevel {
        let plist = resolvedPlistLevel()
        return lock.synchronized { runtimeLevel ?? configurationLevel ?? plist ?? .warn }
    }

    /// Sets the runtime console level (`SallaPush.Debug.logLevel`), the highest precedence.
    package func setRuntimeLevel(_ level: SallaPushLogLevel) {
        lock.synchronized { runtimeLevel = level }
    }

    /// Sets the level an app set explicitly on its configuration; nil when it did not.
    package func setConfigurationLevel(_ level: SallaPushLogLevel?) {
        lock.synchronized { configurationLevel = level }
    }

    /// Reads the Info.plist level now, so later log calls on any thread find it resolved.
    package func primePlistLevel() {
        _ = resolvedPlistLevel()
    }

    /// Installs or removes (nil) the handler; entries at or below `level` reach it on a private queue. The first
    /// handler also gets the kept early entries that pass `level`, before any later entry.
    package func setHandler(level: SallaPushLogLevel, _ newHandler: (@Sendable (SallaPushLogEntry) -> Void)?) {
        let (startDrain, replaced): (Bool, Handler?) = lock.synchronized {
            let replaced = handler
            handler = newHandler
            handlerLevel = level
            pending.removeAll()
            droppedCount = 0
            guard newHandler != nil, let early = earlyEntries else { return (false, replaced) }
            earlyEntries = nil
            pending = early.filter { level.admits($0.level) }
            guard !pending.isEmpty, !draining else { return (false, replaced) }
            draining = true
            return (true, replaced)
        }
        // The replaced handler is released here, after the lock: its captures may log from their deinit.
        withExtendedLifetime(replaced) {}
        if startDrain {
            handlerQueue.async { [self] in drainHandlerQueue() }
        }
    }

    /// Installs a synchronous observer of every emitted entry.
    package func setTap(_ newTap: Tap?) {
        let replaced: Tap? = lock.synchronized {
            defer { tap = newTap }
            return tap
        }
        withExtendedLifetime(replaced) {}
    }

    // MARK: - Logging

    /// Logs `code` at its catalogue level. The message and metadata are built only when some sink accepts the entry.
    package func log(_ code: LogCode,
                     _ message: @autoclosure () -> String,
                     metadata: @autoclosure () -> [String: String] = [:]) {
        let entryLevel = code.level
        let plist = resolvedPlistLevel()
        let keepable = Self.earlyEntryLevel.admits(entryLevel)
        let decision = lock.synchronized {
            Routing(console: (runtimeLevel ?? configurationLevel ?? plist ?? .warn).admits(entryLevel),
                    handler: handler != nil && handlerLevel.admits(entryLevel),
                    keep: keepable && (earlyEntries?.count ?? Self.earlyEntryCapacity) < Self.earlyEntryCapacity,
                    tap: tap)
        }
        guard decision.console || decision.handler || decision.keep || decision.tap != nil else { return }
        let entry = SallaPushLogEntry(level: entryLevel,
                                      category: categoryOverride ?? code.category,
                                      code: code.rawValue,
                                      message: message(),
                                      metadata: metadata().filter { LogMetadataKey.allowed.contains($0.key) },
                                      date: Date())
        if decision.console {
            consoleSink(entryLevel, entry.category, Self.line(for: entry))
        }
        decision.tap?(entry)
        if decision.handler {
            enqueueForHandler(entry)
        } else if decision.keep {
            keepEarly(entry)
        }
    }

    /// Logs `code` only the first time `key` is seen in this logger's lifetime.
    package func logOnce(_ code: LogCode,
                         key: String,
                         _ message: @autoclosure () -> String,
                         metadata: @autoclosure () -> [String: String] = [:]) {
        let first = lock.synchronized { onceKeys.insert(key).inserted }
        guard first else { return }
        log(code, message(), metadata: metadata())
    }

    /// `[SallaPush] <LEVEL> <code>: <message>`, plus the HTTP status, error code and `X-Request-Id` of a failure when
    /// the message does not already name them, in brackets: support finds a request by its id, and the console has no
    /// other place for the metadata (as on Android). Handler entries keep the message as is, with the metadata.
    package static func line(for entry: SallaPushLogEntry) -> String {
        let base = "[SallaPush] \(label(entry.level)) \(entry.code): \(entry.message)"
        var details: [String] = []
        if let status = entry.metadata[LogMetadataKey.httpStatus], !entry.message.contains(status) {
            details.append("HTTP \(status)")
        }
        if let code = entry.metadata[LogMetadataKey.errorCode], !entry.message.contains(code) {
            details.append(code)
        }
        if let request = entry.metadata[LogMetadataKey.requestId], !entry.message.contains(request) {
            details.append("request \(request)")
        }
        return details.isEmpty ? base : base + " [" + details.joined(separator: ", ") + "]"
    }

    private static func label(_ level: SallaPushLogLevel) -> String {
        guard let level = level.validated else { return "LOG" }
        switch level {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .verbose: return "VERBOSE"
        }
    }

    // MARK: - Handler queue

    /// Where one entry goes.
    private struct Routing {
        let console: Bool
        let handler: Bool
        let keep: Bool
        let tap: Tap?
    }

    /// Entries taken from the handler queue in one go.
    private struct HandlerBatch {
        let entries: [SallaPushLogEntry]
        let dropped: Int
        let handler: Handler?
        let level: SallaPushLogLevel
    }

    /// Keeps `entry` for the first handler; when one was installed since the routing decision, hands it over.
    private func keepEarly(_ entry: SallaPushLogEntry) {
        let deliver: Bool = lock.synchronized {
            guard earlyEntries == nil else {
                if (earlyEntries?.count ?? Self.earlyEntryCapacity) < Self.earlyEntryCapacity {
                    earlyEntries?.append(entry)
                }
                return false
            }
            return handler != nil && handlerLevel.admits(entry.level)
        }
        if deliver {
            enqueueForHandler(entry)
        }
    }

    private func enqueueForHandler(_ entry: SallaPushLogEntry) {
        let startDrain: Bool = lock.synchronized {
            pending.append(entry)
            if pending.count > Self.handlerCapacity {
                pending.removeFirst(pending.count - Self.handlerCapacity)
                droppedCount += 1
            }
            if draining { return false }
            draining = true
            return true
        }
        if startDrain {
            handlerQueue.async { [self] in drainHandlerQueue() }
        }
    }

    private func drainHandlerQueue() {
        while true {
            let batch = lock.synchronized { () -> HandlerBatch? in
                if pending.isEmpty && droppedCount == 0 {
                    draining = false
                    return nil
                }
                defer {
                    pending.removeAll()
                    droppedCount = 0
                }
                return HandlerBatch(entries: pending, dropped: droppedCount, handler: handler, level: handlerLevel)
            }
            guard let batch else { return }
            guard let deliver = batch.handler else { continue }
            if batch.dropped > 0 {
                let notice = SallaPushLogEntry(
                    level: LogCode.logDropped.level,
                    category: categoryOverride ?? LogCode.logDropped.category,
                    code: LogCode.logDropped.rawValue,
                    message: "The log handler fell behind; \(batch.dropped) \(batch.dropped == 1 ? "entry was" : "entries were") dropped.",
                    metadata: [LogMetadataKey.count: String(batch.dropped)],
                    date: Date())
                if consoleLevel.admits(notice.level) {
                    consoleSink(notice.level, notice.category, Self.line(for: notice))
                }
                // The sink rule holds for this notice too: a handler set to .error never receives it.
                if batch.level.admits(notice.level) {
                    deliver(notice)
                }
            }
            for entry in batch.entries {
                deliver(entry)
            }
        }
    }

    // MARK: - Sources

    /// The Info.plist level, read once. The thread that settles it reports a value that is not a level, outside the
    /// lock and after the level is known, so the report's own log call finds it resolved.
    private func resolvedPlistLevel() -> SallaPushLogLevel? {
        let known: (read: Bool, level: SallaPushLogLevel?) = lock.synchronized { (plistLevelRead, plistLevel) }
        if known.read { return known.level }
        var configured = plistLevelReader()
        if case let .text(name)? = configured {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty value counts as absent, as on Android.
            configured = trimmed.isEmpty ? nil : .text(trimmed)
        }
        var parsed: SallaPushLogLevel?
        if case let .text(name)? = configured { parsed = SallaPushLogLevel(name: name) }
        let settled: (first: Bool, level: SallaPushLogLevel?) = lock.synchronized {
            guard !plistLevelRead else { return (false, plistLevel) }
            plistLevel = parsed
            plistLevelRead = true
            return (true, parsed)
        }
        if settled.first, parsed == nil, let configured {
            reportInvalidPlistLevel(configured)
        }
        return settled.level
    }

    /// The most characters of an invalid Info.plist value echoed in its report (as on Android).
    private static let maximumShownValue = 32

    private func reportInvalidPlistLevel(_ configured: ConfiguredLogLevel) {
        let accepted = "accepted: off, error, warn, info, debug, verbose"
        switch configured {
        case let .text(value):
            let shown = LogSanitizer.printableASCII(value, maximum: Self.maximumShownValue)
            log(.apiInvalidArgument,
                "The SallaPushLogLevel Info.plist value \"\(shown)\" is not a log level (\(accepted)); it is ignored.")
        case let .notText(kind):
            log(.apiInvalidArgument,
                "The SallaPushLogLevel Info.plist value is \(kind), not the name of a log level (\(accepted)); "
                    + "it is ignored.")
        }
    }

    /// Reads `SallaPushLogLevel` from the main bundle's Info.plist (the app's, or the extension's in the extension).
    package static let mainBundleLogLevel: @Sendable () -> ConfiguredLogLevel? = {
        configuredLevel(Bundle.main.object(forInfoDictionaryKey: "SallaPushLogLevel"))
    }

    /// What an Info.plist value is, for `SallaPushLogLevel`.
    package static func configuredLevel(_ value: Any?) -> ConfiguredLogLevel? {
        guard let value else { return nil }
        if let text = value as? String { return .text(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .notText("a boolean") }
            return .notText("a number (\(LogSanitizer.printableASCII(number.stringValue, maximum: maximumShownValue)))")
        }
        if value is [Any] { return .notText("an array") }
        if value is [AnyHashable: Any] { return .notText("a dictionary") }
        if value is Date { return .notText("a date") }
        if value is Data { return .notText("data") }
        return .notText("a value of another type")
    }

    private static let systemLoggers = Locked<[String: os.Logger]>([:])

    /// Writes to `os.Logger(subsystem: "com.salla.push", category:)` as public, pre-redacted text.
    package static let systemConsole: ConsoleSink = { level, category, line in
        let logger = systemLoggers.withLock { loggers -> os.Logger in
            if let existing = loggers[category] { return existing }
            let created = os.Logger(subsystem: "com.salla.push", category: category)
            loggers[category] = created
            return created
        }
        switch level.validated ?? .debug {
        case .error: logger.error("\(line, privacy: .public)")
        case .warn: logger.notice("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .debug, .verbose: logger.debug("\(line, privacy: .public)")
        case .off: break
        }
    }
}

private extension NSLock {
    func synchronized<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
