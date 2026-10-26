import Foundation

/// How a payload was recognised.
package enum PayloadKind: Sendable, Equatable {
    /// `sp_v` is present (as a string or a number).
    case native
    /// `custom.i` is a string and `custom.a.push_ref` is a valid message id.
    case compat
}

/// A recognised SallaPush payload.
package struct ParsedPayload: @unchecked Sendable {
    /// The public model.
    package let notification: SallaPushNotification
    /// Native or the compatible format.
    package let kind: PayloadKind
    /// True for a local copy posted by `display()` (`sp_local: "1"`): it skips the foreground listeners and records no
    /// second `received`.
    package let isLocalCopy: Bool

    /// The message id that events are recorded under, if any.
    package var messageId: String? { notification.notificationId }
}

/// Parses notification payloads: native (`sp_*`) first, then the compatible format (`custom.a.push_ref`),
/// else foreign. Every value is type-checked; nothing is force-cast.
package enum PayloadParser {
    /// The key of local copies posted by `display()`.
    package static let localCopyKey = "sp_local"

    /// Recognises a payload without building the model.
    package static func kind(of userInfo: [AnyHashable: Any]) -> PayloadKind? {
        if userInfo["sp_v"] is String || userInfo["sp_v"] is NSNumber {
            return .native
        }
        guard let custom = userInfo["custom"] as? [AnyHashable: Any],
              custom["i"] is String,
              let data = custom["a"] as? [AnyHashable: Any],
              MessageId.validated(data["push_ref"]) != nil,
              DepthLimit.fits(custom, maxDepth: JSONValue.maximumDepth, maxBytes: DepthLimit.maximumCompatBytes)
        else { return nil }
        return .compat
    }

    /// Parses `userInfo`; nil when it is not a SallaPush payload.
    package static func parse(_ userInfo: [AnyHashable: Any], logger: SDKLogger) -> ParsedPayload? {
        switch kind(of: userInfo) {
        case .native:
            return parseNative(userInfo, logger: logger)
        case .compat:
            return parseCompat(userInfo, logger: logger)
        case nil:
            return nil
        }
    }

    private static func parseNative(_ userInfo: [AnyHashable: Any], logger: SDKLogger) -> ParsedPayload {
        warnIfNewerVersion(userInfo["sp_v"], logger: logger)
        var invalidFields: [String] = []
        var notificationId: String?
        if let rawId = userInfo["sp_id"] {
            notificationId = MessageId.validated(rawId)
            if notificationId == nil { invalidFields.append("sp_id") }
        }
        let imageURL = httpsURL(userInfo["sp_image"], field: "sp_image", invalid: &invalidFields)
        var launchURL: String?
        if let rawURL = userInfo["sp_url"] {
            launchURL = rawURL as? String
            if launchURL == nil { invalidFields.append("sp_url") }
        }
        var truncated = false
        var additionalData: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key.base as? String, key != "aps", !key.hasPrefix("sp_") else { continue }
            if let converted = JSONValue.sanitize(value, depth: 2, truncated: &truncated) {
                additionalData[key] = converted
            }
        }
        let alert = Alert(userInfo["aps"])
        reportProblems(invalidFields, truncated: truncated, logger: logger)
        let notification = SallaPushNotification(
            notificationId: notificationId, title: alert.title, subtitle: alert.subtitle, body: alert.body,
            imageURL: imageURL, launchURL: launchURL, additionalData: additionalData, badge: alert.badge,
            sound: alert.sound, threadId: alert.threadId, source: .native, rawPayload: userInfo)
        return ParsedPayload(notification: notification, kind: .native, isLocalCopy: isLocalCopy(userInfo))
    }

    /// Logs a payload version this SDK does not know, which is parsed best effort: once per process,
    /// through the once-keys of the process's logger.
    private static func warnIfNewerVersion(_ rawVersion: Any?, logger: SDKLogger) {
        let version: String
        if let string = rawVersion as? String {
            version = string
        } else if let number = rawVersion as? NSNumber {
            version = number.stringValue
        } else {
            version = ""
        }
        guard version != "1" else { return }
        let shown = LogSanitizer.clean(String(version.prefix(16)))
        logger.logOnce(.notifUnknownVersion, key: "notif.unknown_version",
                       "A SallaPush notification uses payload version \(shown); parsed with version 1 rules. Update the SDK.")
    }

    private static func parseCompat(_ userInfo: [AnyHashable: Any], logger: SDKLogger) -> ParsedPayload? {
        guard let custom = userInfo["custom"] as? [AnyHashable: Any],
              let data = custom["a"] as? [AnyHashable: Any],
              let notificationId = MessageId.validated(data["push_ref"])
        else { return nil }
        var invalidFields: [String] = []
        var truncated = false
        var additionalData = JSONValue.sanitizeDictionary(data, depth: 1, truncated: &truncated)
        additionalData.removeValue(forKey: "push_ref")
        var launchURL: String?
        if let rawURL = custom["u"] {
            launchURL = rawURL as? String
            if launchURL == nil { invalidFields.append("custom.u") }
        }
        var imageURL: URL?
        if let attachment = userInfo["att"] {
            if let attachment = attachment as? [AnyHashable: Any] {
                imageURL = httpsURL(attachment["id"], field: "att.id", invalid: &invalidFields)
            } else {
                invalidFields.append("att")
            }
        }
        let alert = Alert(userInfo["aps"])
        reportProblems(invalidFields, truncated: truncated, logger: logger)
        let notification = SallaPushNotification(
            notificationId: notificationId, title: alert.title, subtitle: alert.subtitle, body: alert.body,
            imageURL: imageURL, launchURL: launchURL, additionalData: additionalData, badge: alert.badge,
            sound: alert.sound, threadId: alert.threadId, source: .compat, rawPayload: userInfo)
        return ParsedPayload(notification: notification, kind: .compat, isLocalCopy: isLocalCopy(userInfo))
    }

    private static func isLocalCopy(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[localCopyKey] as? String) == "1"
    }

    private static func httpsURL(_ value: Any?, field: String, invalid: inout [String]) -> URL? {
        guard let value else { return nil }
        guard let string = value as? String,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else {
            invalid.append(field)
            return nil
        }
        return url
    }

    private static func reportProblems(_ fields: [String], truncated: Bool, logger: SDKLogger) {
        if !fields.isEmpty {
            logger.log(.notifParseFailed,
                       "A SallaPush notification could not be fully parsed (\(fields.joined(separator: ", "))); "
                           + "shown with what was readable.")
        }
        if truncated {
            logger.log(.notifParseFailed,
                       "A SallaPush notification could not be fully parsed (data nested deeper than 32 levels); "
                           + "the deeper data was dropped.")
        }
    }

    /// The `aps` fields SallaPush reads.
    private struct Alert {
        var title: String?
        var subtitle: String?
        var body: String?
        var badge: NSNumber?
        var sound: String?
        var threadId: String?

        init(_ aps: Any?) {
            guard let aps = aps as? [AnyHashable: Any] else { return }
            switch aps["alert"] {
            case let text as String:
                body = text
            case let alert as [AnyHashable: Any]:
                title = alert["title"] as? String
                subtitle = alert["subtitle"] as? String
                body = alert["body"] as? String
            default:
                break
            }
            if let number = aps["badge"] as? NSNumber, !number.isBoolean {
                badge = number
            }
            switch aps["sound"] {
            case let name as String:
                sound = name
            case let critical as [AnyHashable: Any]:
                sound = critical["name"] as? String
            default:
                break
            }
            threadId = aps["thread-id"] as? String
        }
    }
}
