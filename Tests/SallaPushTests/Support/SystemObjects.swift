import Foundation
import UserNotifications

/// Real `UNNotification` and `UNNotificationResponse` objects for tests. Neither has a public initializer, but both are
/// keyed-coding compliant, so they are decoded from an archive of their parts.
enum SystemObjects {
    static func notification(identifier: String = "request-1", userInfo: [AnyHashable: Any]) -> UNNotification? {
        let content = UNMutableNotificationContent()
        content.title = "Title"
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(request, forKey: "request")
        archiver.encode(Date(), forKey: "date")
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return nil }
        unarchiver.requiresSecureCoding = false
        return UNNotification(coder: unarchiver)
    }

    static func response(identifier: String = "request-1", actionIdentifier: String = UNNotificationDefaultActionIdentifier,
                         userInfo: [AnyHashable: Any]) -> UNNotificationResponse? {
        guard let notification = notification(identifier: identifier, userInfo: userInfo) else { return nil }
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(notification, forKey: "notification")
        archiver.encode(actionIdentifier, forKey: "actionIdentifier")
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return nil }
        unarchiver.requiresSecureCoding = false
        return UNNotificationResponse(coder: unarchiver)
    }
}
