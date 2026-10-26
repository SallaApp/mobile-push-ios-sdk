# SallaPush iOS SDK

Push notifications for the iOS apps of Salla stores. This Swift package registers the device,
links the signed-in customer, and shows and reports SallaPush notifications.

[![Release](https://img.shields.io/github/v/release/SallaApp/mobile-push-ios-sdk?sort=semver&color=004956&label=release)](https://github.com/SallaApp/mobile-push-ios-sdk/releases) [![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSallaApp%2Fmobile-push-ios-sdk%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/SallaApp/mobile-push-ios-sdk) [![License: MIT](https://img.shields.io/github/license/SallaApp/mobile-push-ios-sdk?color=004956)](LICENSE) [![CI](https://img.shields.io/github/actions/workflow/status/SallaApp/mobile-push-ios-sdk/ci.yml?branch=master&label=CI)](https://github.com/SallaApp/mobile-push-ios-sdk/actions/workflows/ci.yml)

[API reference](docs/REFERENCE.md) · [Logging and log codes](docs/LOGGING.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Changelog](CHANGELOG.md) · [Report a bug](https://github.com/SallaApp/mobile-push-ios-sdk/issues/new/choose)

> **SallaPush is for the mobile apps of Salla stores.** Contact the Salla team for your app id.

- **Version:** 1.0.4. See [CHANGELOG.md](CHANGELOG.md).
- **Also for:** [Android](https://github.com/SallaApp/mobile-push-android-sdk) · [Flutter](https://github.com/SallaApp/mobile-push-sdk/tree/master/flutter) · [React Native](https://github.com/SallaApp/mobile-push-sdk/tree/master/react-native) · [Capacitor](https://github.com/SallaApp/mobile-push-sdk/tree/master/capacitor)

**Contents:** [Requirements](#requirements) · [Installation](#installation) · [Platform setup](#platform-setup) · [Quick start](#quick-start) · [Usage](#usage) · [Other push SDKs](#sallapush-and-other-push-sdks) · [Example app](#example-app) · [Troubleshooting](#troubleshooting) · [Support](#support) · [Contributing](#contributing) · [License](#license)

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0 |
| Xcode | 16 |
| Swift | 5.9 (Swift 6 language mode supported) |
| Install with | Swift Package Manager or CocoaPods |

## Installation

Create your Notification Service Extension target first ([Platform setup, step 2](#2-notification-service-extension)):
`SallaPushExtension` goes into it, and CocoaPods stops on a Podfile target that doesn't exist.

### Swift Package Manager

1. In Xcode, choose **File → Add Package Dependencies…** and enter
   `https://github.com/SallaApp/mobile-push-ios-sdk.git`.
2. Set the dependency rule to **Exact Version** `1.0.4`.
3. Add the `SallaPush` library to your app target, and `SallaPushExtension` (never `SallaPush`) to your extension.

In a `Package.swift`, add the package, then `.product(name: "SallaPush", package: "mobile-push-ios-sdk")` to your app
target and `SallaPushExtension` to your extension target:

<!-- unchecked: a SwiftPM manifest excerpt; the example project uses the package from this folder -->
```swift
.package(url: "https://github.com/SallaApp/mobile-push-ios-sdk.git", exact: "1.0.4"),
```

### CocoaPods

Add all three pods from this repository, with the same tag. Declare `SallaPushCore` too: the other two depend on it,
and it isn't in the public specs repository. CocoaPods fetches them over HTTPS, with no GitHub account or token.

```ruby
target 'YourApp' do
  pod 'SallaPushCore', :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => '1.0.4'
  pod 'SallaPush', :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => '1.0.4'
end

target 'YourNotificationServiceExtension' do
  pod 'SallaPushCore', :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => '1.0.4'
  pod 'SallaPushExtension', :git => 'https://github.com/SallaApp/mobile-push-ios-sdk.git', :tag => '1.0.4'
end
```

Run `pod install`, then open the `.xcworkspace` it creates, not the `.xcodeproj`.

**Updating:** set the new version in your package dependency, or in the `:tag` of all four `pod` lines.

## Platform setup

### 1. Capabilities

In your app target, under **Signing & Capabilities**, add **Push Notifications** and **Background Modes → Remote
notifications**. Check: the app's entitlements file now has `aps-environment`.

### 2. Notification Service Extension

The extension shows images and counts the [badge](#badges). If your app already has one, add `SallaPushExtension` to
it and call SallaPush first ([other push SDKs](#sallapush-and-other-push-sdks)). Otherwise:

1. Choose **File → New → Target → Notification Service Extension**.
2. Set its deployment target to your app's. With a higher one, iOS skips the extension on older iOS versions.
3. Add `SallaPushExtension` to it (Swift Package Manager: the target's **General → Frameworks and Libraries → +**;
   CocoaPods: its `target` block in the Podfile), and replace its `NotificationService.swift` with this one:

<!-- snippet:SallaPushExampleNSE/NotificationService.swift -->
```swift
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
```

`didReceive` returns false and doesn't handle the notification when it isn't a SallaPush notification.

### 3. App Group

Add the same App Group, such as `group.com.example.shop`, to the app and the extension, and put its name in the
`SallaPushAppGroup` Info.plist key of both targets ([Info.plist keys](docs/REFERENCE.md#infoplist-keys)). The
extension needs it to report `received` and to count the badge. Check: no `config.no_app_group` line at the `info`
log level.

## Quick start

### Initialize

Initialize SallaPush in your app delegate, and forward the token and the notification delegate calls. This is the
example app's `AppDelegate.swift`, complete. If your app already has one, add the SallaPush lines to its methods:

<!-- snippet:SallaPushExample/AppDelegate.swift -->
```swift
import SallaPush
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
        // Set the delegate before this method returns, or the tap that launched the app is lost.
        UNUserNotificationCenter.current().delegate = self
        return true
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
        completionHandler()
    }
}
```

- Replace `00000000-0000-4000-8000-000000000001` with your app id. `initialize` returns at once, and calls
  `registerForRemoteNotifications()` for you. Optional settings go in a
  [`SallaPushConfiguration`](docs/REFERENCE.md#configuration). Then [ask for permission](#notification-permission).
- **SwiftUI app** (Xcode's default template): remove `@main` from this `AppDelegate`, and add
  `@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate` to your `App`. Objective-C, Swift 6 and
  apps without a notification delegate: [Other app shapes](docs/REFERENCE.md#other-app-shapes).
- `willPresent` returns nil for other SDKs' notifications: keep your own options for those. SallaPush never calls your
  completion handlers: you call each one, once.

## Usage

### Login and logout

Call `login` after the customer signs in, with their id and the customer token your app received at sign-in, and
`logout` after they sign out:

<!-- snippet:ReadmeSnippets/Identity.swift#sign-in-out -->
```swift
func customerDidSignIn(customerId: String, token: String) {
    SallaPush.login(externalId: customerId, identityToken: token)
}

func customerDidSignOut() {
    SallaPush.logout()
}
```

Call `login` at each app launch too, while the customer is signed in, and `logout()` while nobody is: after a
reinstall, it unlinks the customer of the earlier install.

### Notification permission

SallaPush never shows the system prompt on its own. Ask where it fits your app:

<!-- snippet:ReadmeSnippets/Notifications.swift#request-permission-async -->
```swift
let granted = await SallaPush.Notifications.requestPermission(fallbackToSettings: true)
```

`fallbackToSettings: true` opens your app's notification settings when the user already said no.
`requestPermission(fallbackToSettings:completion:)` is the completion form, `SallaPush.Notifications.permission` the
current answer, and `addPermissionObserver` reports changes.

### Notification taps and deep links

Add a click listener, and keep the returned observation for as long as you want it. `cancel()` it to stop:

<!-- snippet:ReadmeSnippets/Notifications.swift#click-listener -->
```swift
clickListener = SallaPush.Notifications.addClickListener { event in
    route(event.notification)
}
```

- Read your data with `notification.string(forKey:)`, `int(forKey:)` and `launchURL`
  ([Routing taps yourself](docs/REFERENCE.md#routing-taps-yourself)). SallaPush opens launch URLs only with
  `openLaunchURLs` set in the [configuration](docs/REFERENCE.md#configuration).
- Listeners run on the main thread. A tap that arrives before the first listener, such as the one that launched the
  app, is kept for 5 minutes and delivered to it.

### Foreground notifications

In the foreground, SallaPush notifications show as a banner, in the list and with sound; a listener can hold one back:

<!-- snippet:ReadmeSnippets/Notifications.swift#foreground-listener -->
```swift
foregroundListener = SallaPush.Notifications.addForegroundLifecycleListener { event in
    guard Checkout.shared.isInProgress else { return }
    event.preventDefault()
    Checkout.shared.whenFinished {
        event.notification.display()
    }
}
```

Call `preventDefault()` before the listener returns. `display()` shows the notification later, once, within 10
minutes, as a local copy without its image and action buttons.

### Tags and language

<!-- snippet:ReadmeSnippets/User.swift#tags -->
```swift
SallaPush.User.addTag(key: "add_to_cart", value: String(Int(Date().timeIntervalSince1970)))
SallaPush.User.addTags(["total_cart_amount": String(total), "cart_items": String(items)])
```

- `removeTag(_:)` and `removeTags(_:)` remove tags, and `getTags()` returns them with your latest changes. Keys are
  trimmed and lowercased, then must be 1 to 64 characters of `a-z`, `0-9` and `_`, or they are dropped. At most 100
  tags. A logout and an account switch delete the device's tags (`clearTagsOnLogout`, on by default).
- `SallaPush.User.setLanguage(_:)` sets the customer's language, such as `"ar"`.

### Push subscription

`SallaPush.User.pushSubscription.optOut()` turns SallaPush notifications off on this device, and `optIn()` turns them
back on, with the permission prompt when the app never asked. `optedIn` is true when notifications are allowed, the
user didn't opt out, and the device has a token. Observe it, with the device id:

<!-- snippet:ReadmeSnippets/User.swift#subscription-observer -->
```swift
subscriptionObserver = SallaPush.User.pushSubscription.addObserver { state in
    SettingsScreen.shared.show(deviceId: state.current.id, optedIn: state.current.optedIn)
}
```

### Consent

If your app needs the user's consent first (PDPL), require it before `initialize`, at every launch, and pass the
user's choice to `SallaPush.setConsentGiven(_:)` whenever they make it:

<!-- snippet:ReadmeSnippets/Consent.swift#consent-required -->
```swift
SallaPush.setConsentRequired(true)
SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
```

Until consent is given, SallaPush sends nothing and saves nothing but the answer. Withdrawing consent opts the device
out and logs the customer out, then SallaPush stops ([Consent](docs/REFERENCE.md#consent)).

### Logging

The default level is `warn`: `SallaPush.Debug.logLevel` or the `SallaPushLogLevel` Info.plist key changes it. While
you debug, turn on verbose logs before `initialize`, and filter the Xcode console on `SallaPush`:

<!-- snippet:ReadmeSnippets/Logging.swift#log-level -->
```swift
SallaPush.Debug.logLevel = .verbose
```

After `init.started`, expect `token.received` and `register.ok` at the first launch on a device, or on a simulator
with iOS 16 or later on a Mac with Apple silicon or a T2 chip. Forward entries to your telemetry with a log handler:

<!-- snippet:ReadmeSnippets/Logging.swift#log-handler -->
```swift
SallaPush.Debug.setLogHandler(level: .error) { entry in
    Telemetry.report(source: "sallapush", code: entry.code, message: entry.message, metadata: entry.metadata)
}
```

The handler runs on a private serial queue, never the main thread: call only thread-safe code from it. Match on each
entry's stable `code`, not on its message ([log codes](docs/LOGGING.md#log-code-reference)).

### Badges

Each SallaPush notification adds 1 to the app icon's badge (`autoUpdateBadge`), and the badge goes back to 0 when the
app opens (`autoClearBadge`). Both are on by default on iOS; the Android SDK leaves `autoClearBadge` off. Counting
needs the [extension](#2-notification-service-extension) and the [App Group](#3-app-group).
`SallaPush.Notifications.clearAll()` removes SallaPush's notifications and, while `autoUpdateBadge` is on, sets the
badge to 0 (on iOS 15, only when no other SDK's notification is delivered). Set `autoClearBadge = false` in the
[configuration](docs/REFERENCE.md#configuration) to keep the badge when the app opens: it then follows the SallaPush
notifications still in Notification Center. An app that sets its own badge number also sets `autoUpdateBadge = false`
([Badges](docs/REFERENCE.md#badges)).

## SallaPush and other push SDKs

SallaPush never swizzles and never sets a delegate. It returns nil or false for other SDKs' notifications, so the order
of your forwarding lines doesn't matter. In a shared Notification Service Extension, call SallaPush first: check
`SallaPushServiceExtension.isSallaPushNotification(request)`, as the
[extension above](#2-notification-service-extension) does, and hand every other notification to the other SDKs.

## Example app

[Examples/SallaPushExample](Examples/SallaPushExample) is a complete integration that builds without signing: the
quick start's `AppDelegate.swift`, the extension above, and a target that compiles every other snippet of this README
([The example project](CONTRIBUTING.md#the-example-project)).

## Troubleshooting

| Problem | Fix |
|---|---|
| `No such module 'SallaPush'` or `'SallaPushExtension'` | Add `SallaPush` to the app target and `SallaPushExtension` to the extension target ([Installation](#installation)). |
| `token.missing` or `token.registration_failed` | Forward the token from `didRegisterForRemoteNotificationsWithDeviceToken`, and add the Push Notifications capability. On a simulator, use iOS 16 or later on a Mac with Apple silicon or a T2 chip. |
| `register.ok`, but no notification arrives | Check that `SallaPush.User.pushSubscription.optedIn` is true. Development builds use the APNs sandbox; TestFlight and App Store builds use production. |
| No image, no `received` while the app is closed, or no badge count | Embed the extension with `SallaPushExtension`, and use the same App Group in both targets. Images must be https and at most 10 MB. Set `SallaPushLogLevel` to `info` in the extension's Info.plist: `nse.received_deferred` and `nse.badge_skipped` say why. |
| `login.rejected` | Salla refused the token for that customer. Pass the customer's current token, without a `Bearer ` prefix, and their id as `externalId`. |
| `init.no_delegate` | Set your notification delegate in `didFinishLaunchingWithOptions`. |

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) has more.

## Support

- **SDK bugs and feature requests:** [open an issue](https://github.com/SallaApp/mobile-push-ios-sdk/issues/new/choose)
  with the SDK and iOS versions and the SallaPush log codes you saw. Never paste tokens, keys or customer data.
- **App ids:** Contact the Salla team for your app id.

## Contributing

Pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## License

The SallaPush iOS SDK is available under the [MIT License](LICENSE).
