import SallaPush
import UIKit
import UserNotifications

// README "Notification permission", "Notification taps and deep links" and "Foreground notifications", and
// docs/REFERENCE.md "Notifications" and "Routing taps yourself".

@MainActor
final class PushScreens {
    private var foregroundListener: SallaPushObservation?
    private var clickListener: SallaPushObservation?

    func askForPermission() {
        // snippet:request-permission
        SallaPush.Notifications.requestPermission(fallbackToSettings: true) { granted in
            SettingsScreen.shared.show(permissionGranted: granted)
        }
        // end-snippet
    }

    func askForPermissionAsync() async {
        // snippet:request-permission-async
        let granted = await SallaPush.Notifications.requestPermission(fallbackToSettings: true)
        // end-snippet
        SettingsScreen.shared.show(permissionGranted: granted)
    }

    func holdNotificationsDuringCheckout() {
        // snippet:foreground-listener
        foregroundListener = SallaPush.Notifications.addForegroundLifecycleListener { event in
            guard Checkout.shared.isInProgress else { return }
            event.preventDefault()
            Checkout.shared.whenFinished {
                event.notification.display()
            }
        }
        // end-snippet
    }

    func routeTaps() {
        // snippet:click-listener
        clickListener = SallaPush.Notifications.addClickListener { event in
            route(event.notification)
        }
        // end-snippet
    }
}

// snippet:click-listener-object
@MainActor
final class TapRouter: NSObject, SallaPushClickListener {
    func onClick(event: SallaPushClickEvent) {
        route(event.notification)
    }
}
// end-snippet

// The calls docs/REFERENCE.md "Taps" names for the listener object. SallaPush holds a listener weakly, so the app
// keeps it.
@MainActor
final class TapRouterOwner {
    private let tapRouter = TapRouter()

    func startRouting() {
        SallaPush.Notifications.addClickListener(tapRouter)
    }

    func stopRouting() {
        SallaPush.Notifications.removeClickListener(tapRouter)
    }
}

// snippet:route
@MainActor
func route(_ notification: SallaPushNotification) {
    switch notification.string(forKey: "type") {
    case "product":
        if let id = notification.int(forKey: "id") {
            Router.shared.showProduct(id: id)
        }
    case "order":
        if let id = notification.string(forKey: "id") {
            Router.shared.showOrder(id: id)
        }
    default:
        if let link = notification.launchURL, let url = URL(string: link) {
            Router.shared.open(url)
        }
    }
}
// end-snippet

final class RoutingAppDelegate: UIResponder, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // snippet:parse
        SallaPush.Notifications.didReceive(response)
        if let notification = SallaPush.Notifications.parse(response.notification.request.content.userInfo) {
            route(notification)
        }
        completionHandler()
        // end-snippet
    }
}
