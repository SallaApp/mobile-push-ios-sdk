import Foundation
import SallaPushCore
import UserNotifications

/// An opt-in `UNUserNotificationCenterDelegate` for apps that have none. Assign it yourself
/// (`UNUserNotificationCenter.current().delegate = SallaPush.Notifications.notificationCenterDelegate`) inside
/// `application(_:didFinishLaunchingWithOptions:)`. It forwards to SallaPush, presents other notifications with
/// the default options, and always calls the completion handler once. Subclass it to add your own handling.
@objc open class SallaPushNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Creates a delegate.
    public override init() {
        super.init()
    }

    /// Presents SallaPush notifications as SallaPush decides and every other one as banner, list, sound and badge.
    open func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                     withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(SallaPush.Notifications.willPresent(notification) ?? [.banner, .list, .sound, .badge])
    }

    /// Forwards the response to SallaPush, then calls the completion handler.
    open func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                     withCompletionHandler completionHandler: @escaping () -> Void) {
        SallaPush.Notifications.didReceive(response)
        completionHandler()
    }
}
