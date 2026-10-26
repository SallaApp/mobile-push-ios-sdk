import Foundation
@testable import SallaPush
import UserNotifications

/// Calls `willPresentNotification:presentationOptions:`, the Objective-C form Swift can't call, through the Objective-C
/// runtime, as an Objective-C app does.
func objcWillPresent(_ notification: UNNotification,
                     _ options: UnsafeMutablePointer<UNNotificationPresentationOptions>?) -> Bool {
    typealias Form = @convention(c) (AnyObject, Selector, UNNotification,
                                     UnsafeMutablePointer<UNNotificationPresentationOptions>?) -> ObjCBool
    let selector = NSSelectorFromString("willPresentNotification:presentationOptions:")
    let notifications = SallaPush.Notifications
    let form = unsafeBitCast(notifications.method(for: selector), to: Form.self)
    return form(notifications, selector, notification, options).boolValue
}
