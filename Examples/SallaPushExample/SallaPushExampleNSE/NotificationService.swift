import SallaPushExtension
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var sallaPushService: SallaPushServiceExtension?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if SallaPushServiceExtension.isSallaPushNotification(request) {
            // Reads the App Group from this extension's Info.plist key SallaPushAppGroup.
            sallaPushService = SallaPushServiceExtension()
            sallaPushService?.didReceive(request, withContentHandler: contentHandler)
        } else {
            // Not a SallaPush notification: hand it to your other SDKs here, or deliver it unchanged.
            contentHandler(request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        sallaPushService?.serviceExtensionTimeWillExpire()
    }
}
