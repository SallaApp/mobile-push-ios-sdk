import Foundation
import SallaPushCore

/// The local copy `display()` posts for a prevented foreground notification: same title, subtitle, body, sound,
/// badge, thread id and userInfo, plus `sp_local: "1"`, so it skips the listeners and records no second `received`
/// (its display and its tap are recorded). Attachments are not copied.
enum LocalNotification {
    static func request(for payload: ParsedPayload, uuid: UUID = UUID()) -> LocalNotificationRequest {
        var userInfo = payload.notification.rawPayload
        userInfo[PayloadParser.localCopyKey] = "1"
        let suffix = payload.messageId ?? uuid.uuidString.lowercased()
        let notification = payload.notification
        return LocalNotificationRequest(identifier: "sallapush.local." + suffix,
                                        title: notification.title,
                                        subtitle: notification.subtitle,
                                        body: notification.body,
                                        sound: notification.sound,
                                        badge: notification.badge,
                                        threadId: notification.threadId,
                                        userInfo: userInfo)
    }
}
