import Foundation

/// A parsed SallaPush notification. Immutable.
///
/// Read routing data with the typed accessors (`string(forKey:)`, `int(forKey:)`, `bool(forKey:)`,
/// `number(forKey:)`): they accept both JSON numbers and numeric strings, so routing keeps working
/// whether the payload is compatible (typed data) or native (string data).
@objc public final class SallaPushNotification: NSObject, @unchecked Sendable {
    /// The SallaPush message id (`msg_…`), from `sp_id` or `custom.a.push_ref`; nil when the payload has no valid id.
    @objc public let notificationId: String?
    /// The title from `aps.alert`.
    @objc public let title: String?
    /// The subtitle from `aps.alert`.
    @objc public let subtitle: String?
    /// The body from `aps.alert` (a string `aps.alert` is the body).
    @objc public let body: String?
    /// The image URL (`sp_image` or `att.id`); https only.
    @objc public let imageURL: URL?
    /// The launch URL (`sp_url` or `custom.u`), exactly as sent. SallaPush never opens it unless asked to.
    @objc public let launchURL: String?
    /// The custom data: `custom.a` without `push_ref` for compatible payloads (JSON types kept),
    /// or the top-level keys that are not `aps` or `sp_*` for native payloads.
    @objc public let additionalData: [String: Any]
    /// The badge from `aps.badge`.
    @objc public let badge: NSNumber?
    /// The sound name from `aps.sound`.
    @objc public let sound: String?
    /// The thread identifier from `aps.thread-id`.
    @objc public let threadId: String?
    /// Whether the payload is native or compatible.
    @objc public let source: SallaPushPayloadSource
    /// The notification's original `userInfo`.
    @objc public let rawPayload: [AnyHashable: Any]

    package init(notificationId: String?, title: String?, subtitle: String?, body: String?, imageURL: URL?,
                 launchURL: String?, additionalData: [String: Any], badge: NSNumber?, sound: String?,
                 threadId: String?, source: SallaPushPayloadSource, rawPayload: [AnyHashable: Any]) {
        self.notificationId = notificationId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.imageURL = imageURL
        self.launchURL = launchURL
        self.additionalData = additionalData
        self.badge = badge
        self.sound = sound
        self.threadId = threadId
        self.source = source
        self.rawPayload = rawPayload
        super.init()
    }

    /// The value for `key` in `additionalData` as a string; numbers are converted to their decimal form.
    @objc public func string(forKey key: String) -> String? {
        switch additionalData[key] {
        case let string as String:
            return string
        case let number as NSNumber:
            if number.isBoolean { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return nil
        }
    }

    /// The value for `key` in `additionalData` as a number; accepts JSON numbers and numeric strings.
    @objc(numberForKey:) public func number(forKey key: String) -> NSNumber? {
        switch additionalData[key] {
        case let number as NSNumber:
            return number
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int64(trimmed) { return NSNumber(value: integer) }
            guard NumericText.isDecimal(trimmed), let double = Double(trimmed), double.isFinite else { return nil }
            return NSNumber(value: double)
        default:
            return nil
        }
    }

    /// The value for `key` in `additionalData` as an integer; accepts JSON numbers and numeric strings. The value is
    /// exact or nil: a fraction, or a number outside `Int`, gives nil instead of a rounded integer.
    public func int(forKey key: String) -> Int? {
        switch additionalData[key] {
        case let number as NSNumber:
            return NumericText.exactInteger(number)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int(trimmed) { return integer }
            guard NumericText.isDecimal(trimmed) else { return nil }
            let decimal = NSDecimalNumber(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
            return decimal == NSDecimalNumber.notANumber ? nil : NumericText.exactInteger(decimal)
        default:
            return nil
        }
    }

    /// The value for `key` in `additionalData` as a boolean; accepts true/false, 1/0 and "true"/"false".
    public func bool(forKey key: String) -> Bool? {
        switch additionalData[key] {
        case let number as NSNumber:
            if number.isBoolean { return number.boolValue }
            switch number.doubleValue {
            case 1: return true
            case 0: return false
            default: return nil
            }
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}

extension NSNumber {
    /// Whether this number is a JSON boolean rather than a numeric value.
    package var isBoolean: Bool {
        CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}
