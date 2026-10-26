import SallaPush
import SwiftUI
import UIKit
import UserNotifications

// docs/REFERENCE.md "Other app shapes": the quick start's app delegate in Swift 6 language mode, a SwiftUI app and
// an app without a notification delegate.

// snippet:swift6-declaration
final class AppDelegate: UIResponder, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
// end-snippet
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(SallaPush.Notifications.willPresent(notification) ?? [.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        SallaPush.Notifications.didReceive(response)
        completionHandler()
    }
}

// snippet:swiftui-app
@main
struct ShopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
// end-snippet

final class DelegateFreeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // snippet:ready-made-delegate
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = SallaPush.Notifications.notificationCenterDelegate
        // end-snippet
        return true
    }
}

// snippet:delegate-subclass
final class ShopNotificationDelegate: SallaPushNotificationCenterDelegate {
    override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                         withCompletionHandler completionHandler: @escaping () -> Void) {
        Telemetry.report(source: "push", code: "opened", message: response.actionIdentifier, metadata: [:])
        super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
}
// end-snippet

final class SubclassingAppDelegate: UIResponder, UIApplicationDelegate {
    // snippet:delegate-subclass-owner
    // UNUserNotificationCenter holds its delegate weakly: this property keeps it alive.
    private let notificationDelegate = ShopNotificationDelegate()
    // end-snippet

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }
}
