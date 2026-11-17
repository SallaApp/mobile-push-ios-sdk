#if os(iOS)
// A plain import on purpose: this file sees only the public API, as an app does.
import SallaPush
import UIKit
import UserNotifications
import XCTest

/// Every documented call shape of the public API, which never breaks within a major version. A signature that stops
/// compiling fails the build.
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate,
                              SallaPushClickListener, SallaPushUserObserver, SallaPushSubscriptionObserver,
                              SallaPushPermissionObserver, SallaPushForegroundLifecycleListener {
    var observations: [SallaPushObservation] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        start(launchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    /// The SallaPush part of `didFinishLaunching`; returns the async permission request so a test can await it.
    @discardableResult
    func start(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Task<Bool, Never> {
        SallaPush.initialize("st_42_ios", withLaunchOptions: launchOptions)
        let config = SallaPushConfiguration()
        config.logLevel = .verbose
        config.registerForRemoteNotificationsOnInit = false
        config.autoClearBadge = false
        config.autoUpdateBadge = false
        SallaPush.initialize("st_42_ios", withLaunchOptions: launchOptions, configuration: config)
        SallaPush.setConsentRequired(true)
        SallaPush.setConsentGiven(true)
        SallaPush.Debug.setLogLevel(.verbose)
        SallaPush.Debug.logLevel = .off
        SallaPush.Debug.setLogHandler { entry in _ = (entry.code, entry.metadata) }
        SallaPush.Debug.setLogHandler(level: .error) { _ in }
        SallaPush.Debug.setLogHandler(nil)
        SallaPush.login(externalId: "1001", identityToken: "eyJ.identity.token")
        SallaPush.logout()
        SallaPush.User.addTag(key: "k", value: "v")
        SallaPush.User.addTags(["a": "1"])
        SallaPush.User.removeTag("k")
        SallaPush.User.removeTags(["a"])
        _ = SallaPush.User.getTags()
        SallaPush.User.setLanguage("ar")
        SallaPush.User.addObserver(self)
        observations.append(SallaPush.User.addObserver { state in _ = state.current.externalId })
        observations.append(SallaPush.User.addLoginFailureHandler { failure in
            _ = failure == .tokenRejected || failure == .invalidRequest
        })
        SallaPush.User.pushSubscription.addObserver(self)
        observations.append(SallaPush.User.pushSubscription.addObserver { state in _ = state.current.id })
        SallaPush.User.pushSubscription.optIn()
        SallaPush.User.pushSubscription.optOut()
        _ = (SallaPush.User.pushSubscription.id, SallaPush.User.pushSubscription.token, SallaPush.User.pushSubscription.optedIn)
        SallaPush.Notifications.addClickListener(self)
        observations.append(SallaPush.Notifications.addClickListener { event in _ = event.result.url })
        SallaPush.Notifications.addForegroundLifecycleListener(self)
        observations.append(SallaPush.Notifications.addForegroundLifecycleListener { event in
            event.preventDefault()
            event.notification.display()
        })
        SallaPush.Notifications.addPermissionObserver(self)
        observations.append(SallaPush.Notifications.addPermissionObserver { granted in _ = granted })
        SallaPush.Notifications.requestPermission(fallbackToSettings: true) { granted in _ = granted }
        SallaPush.Notifications.registerForProvisionalAuthorization { _ in }
        SallaPush.Notifications.refreshPermission()
        SallaPush.Notifications.clearAll()
        _ = SallaPush.Notifications.permissionStatus
        return Task { await SallaPush.Notifications.requestPermission() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SallaPush.Notifications.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        SallaPush.Notifications.didReceiveRemoteNotification(userInfo)
        completionHandler(.noData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(SallaPush.Notifications.willPresent(notification) ?? [.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        SallaPush.Notifications.didReceive(response)
        if let parsed = SallaPush.Notifications.parse(response.notification.request.content.userInfo) {
            _ = (parsed.int(forKey: "id"), parsed.bool(forKey: "flag"), parsed.number(forKey: "id"), parsed.string(forKey: "type"))
        }
        completionHandler()
    }

    func onClick(event: SallaPushClickEvent) {}
    func onUserStateDidChange(state: SallaPushUserChangedState) {}
    func onLoginFailure(_ failure: SallaPushLoginFailure) {}
    func onPushSubscriptionDidChange(state: SallaPushSubscriptionChangedState) {}
    func onNotificationPermissionDidChange(_ permission: Bool) {}
    func onWillDisplay(event: SallaPushWillDisplayEvent) {}
}

final class ProbeDelegateSubclass: SallaPushNotificationCenterDelegate {}

/// Runs the probe against a runtime wired to fakes: no system services, no network. A logic-test bundle has no
/// `UIApplication`, so the delegate's SallaPush calls are made directly.
final class APISurfaceTests: XCTestCase {
    @MainActor
    func test_everyDocumentedCallShape_compilesAndRuns() async {
        let h = Harness()
        h.installAsShared()
        let delegate = ProbeAppDelegate()
        let permission = delegate.start(launchOptions: nil)
        let granted = await permission.value
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: Harness.token())
        SallaPush.Notifications.didFailToRegisterForRemoteNotifications(error: NSError(domain: "APNs", code: 3_000))
        XCTAssertTrue(SallaPush.Notifications.didReceiveRemoteNotification(["sp_v": "1", "sp_id": "msg_ab"]))
        XCTAssertFalse(SallaPush.Notifications.didReceiveRemoteNotification(["custom": ["i": "onesignal"]]))
        h.settle()
        XCTAssertTrue(granted)
        XCTAssertTrue(SallaPush.isInitialized)
        XCTAssertEqual(SallaPush.sdkVersion, "1.1.0")
        XCTAssertEqual(SallaPush.appId, "st_42_ios")
        XCTAssertEqual(delegate.observations.count, 6)
        XCTAssertNotNil(SallaPush.Notifications.notificationCenterDelegate)
        XCTAssertNotNil(ProbeDelegateSubclass())
    }
}
#endif
