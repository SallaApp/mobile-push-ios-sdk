import Foundation

/// One SallaPush log entry, as delivered to the handler set with `SallaPush.Debug.setLogHandler(level:_:)`.
///
/// Every field is redacted by construction: no secret (the device secret, the identity token) ever appears in an entry.
/// The full push token and the customer's id appear only in the info status entries (`status.launch`,
/// `status.changed`), and only in a development build (the sandbox APNs environment) whose Info.plist turns on the
/// debug switch `SallaPushLogFullIdentifiers`. Don't forward info entries to third parties.
@objc public final class SallaPushLogEntry: NSObject, Sendable {
    /// The level of the entry.
    @objc public let level: SallaPushLogLevel
    /// The area that produced it: lifecycle, registration, identity, notifications, events, tags, network,
    /// storage, consent or extension.
    @objc public let category: String
    /// A stable identifier such as `register.ok`. Codes never change between releases.
    @objc public let code: String
    /// A one-line, human-readable message that says what happened and, for problems, what to do.
    @objc public let message: String
    /// Structured details. The keys are limited to `http_status`, `error_code`, `request_id`, `device_id`,
    /// `app_id`, `attempt`, `delay_s`, `route`, `reason` and `count`.
    @objc public let metadata: [String: String]
    /// When the entry was created.
    @objc public let date: Date

    package init(level: SallaPushLogLevel, category: String, code: String, message: String,
                 metadata: [String: String], date: Date) {
        self.level = level
        self.category = category
        self.code = code
        self.message = message
        self.metadata = metadata
        self.date = date
        super.init()
    }
}
