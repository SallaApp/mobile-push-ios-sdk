# SallaPush iOS SDK: API reference

The public API, with examples. The [README](../README.md) has the installation, the setup and the quick start.

Other docs: [Logging](LOGGING.md) · [Troubleshooting](TROUBLESHOOTING.md)

## Contents

- [The app delegate calls](#the-app-delegate-calls)
- [Notification Service Extension](#notification-service-extension)
- [Other app shapes](#other-app-shapes)
- [Notifications](#notifications)
- [Routing taps yourself](#routing-taps-yourself)
- [Badges](#badges)
- [The user](#the-user)
- [Consent](#consent)
- [Configuration](#configuration)
- [Info.plist keys](#infoplist-keys)
- [Privacy and size](#privacy-and-size)

Every call works from any thread and never throws: bad input is logged (`api.invalid_argument`) and ignored. The app
library's calls work before or after `initialize` and return at once. Listeners, observers and completions run on the
main thread.

## The app delegate calls

The [quick start](../README.md#initialize) forwards these calls from your app delegate:

| Call | What it does |
|---|---|
| `SallaPush.initialize(_:withLaunchOptions:)` | Starts SallaPush with your app id and calls `registerForRemoteNotifications()`. Set your notification delegate before `didFinishLaunchingWithOptions` returns: iOS delivers the tap that launched the app to the delegate set during launch. |
| `SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken:)` | Hands SallaPush the APNs token. The same token twice costs nothing. |
| `didFailToRegisterForRemoteNotifications(error:)` | Logs why iOS gave the app no token (`token.registration_failed`). |
| `didReceiveRemoteNotification(_:)` | Reports `received` for a SallaPush notification. It never calls your completion handler. |
| `willPresent(_:)` | SallaPush's presentation options for its notifications, and nil for the others. Pass SallaPush's options to the completion handler unchanged; to hold a notification back, use a [foreground listener](#foreground-notifications). |
| `didReceive(_:)` | Delivers the tap to your [click listeners](#taps), and returns true for a SallaPush notification. |

## Notification Service Extension

`SallaPushServiceExtension`, in the `SallaPushExtension` library, handles SallaPush notifications in your
Notification Service Extension ([setup](../README.md#2-notification-service-extension)):

- **`SallaPushServiceExtension.isSallaPushNotification(_:)`** tells whether a request is a SallaPush notification.
- **`didReceive(_:withContentHandler:)`** attaches a SallaPush notification's image (https only, at most 10 MB),
  reports `received`, counts the [badge](#badges), and calls the content handler once, also when the extension runs
  out of time. For any other notification it returns false and never touches the content handler. Call it directly
  from your extension's `didReceive`, never from a completion block or a serial queue.
- **`serviceExtensionTimeWillExpire()`** delivers the best attempt, and returns false when SallaPush handles no
  notification.
- **`SallaPushServiceExtension()`** reads the App Group from the extension's `SallaPushAppGroup` Info.plist key, and
  `SallaPushServiceExtension(appGroupIdentifier:)` takes it from your own configuration (nil or blank means none).

## Other app shapes

### SwiftUI

Keep the quick start's app delegate, without its `@main`, and connect it with an adaptor:

<!-- snippet:ReadmeSnippets/AppShapes.swift#swiftui-app -->
```swift
@main
struct ShopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### Swift 6 language mode

`UNUserNotificationCenterDelegate` is not isolated to the main actor, so in Swift 6 language mode an app delegate
can't conform to it as written. Declare the conformance `@preconcurrency`, which checks at run time that iOS calls
the methods on the main thread, as it does:

<!-- snippet:ReadmeSnippets/AppShapes.swift#swift6-declaration -->
```swift
final class AppDelegate: UIResponder, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
```

If another SDK in your app forwards these calls off the main thread, mark the two `userNotificationCenter` methods
`nonisolated` instead: SallaPush's forwarding calls are safe on any thread. Every other snippet of the README and these
docs compiles in Swift 6 language mode as shown.

### Objective-C

Import the module with `@import SallaPush;` (no bridging header entry is needed) and make the same calls:

<!-- snippet:ReadmeSnippets/ObjCAppDelegate.m#objc-app-delegate -->
```objc
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [SallaPush initialize:@"00000000-0000-4000-8000-000000000001" withLaunchOptions:launchOptions];
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    return YES;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [SallaPush.Notifications didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [SallaPush.Notifications didFailToRegisterForRemoteNotificationsWithError:error];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    [SallaPush.Notifications didReceiveRemoteNotification:userInfo];
    completionHandler(UIBackgroundFetchResultNoData);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
        | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge;
    // YES for a SallaPush notification, with options set to SallaPush's choice; NO leaves your options as they are.
    (void)[SallaPush.Notifications willPresentNotification:notification presentationOptions:&options];
    completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    [SallaPush.Notifications didReceiveNotificationResponse:response];
    completionHandler();
}
```

The Notification Service Extension in Objective-C, with `@import SallaPushExtension;`:

<!-- snippet:ReadmeSnippets/ObjCNotificationService.m#objc-notification-service -->
```objc
@interface NotificationService : UNNotificationServiceExtension
@end

@implementation NotificationService {
    SallaPushServiceExtension *_sallaPushService;
}

- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request
                   withContentHandler:(void (^)(UNNotificationContent *))contentHandler {
    if ([SallaPushServiceExtension isSallaPushNotification:request]) {
        _sallaPushService = [[SallaPushServiceExtension alloc] init];
        [_sallaPushService didReceive:request withContentHandler:contentHandler];
    } else {
        contentHandler(request.content);
    }
}

- (void)serviceExtensionTimeWillExpire {
    [_sallaPushService serviceExtensionTimeWillExpire];
}

@end
```

- **Swift-only APIs:** the closure observers that return a `SallaPushObservation` (use the observer protocols
  instead), `requestPermission(fallbackToSettings:) async`, `Debug.setLogLevel(_:)` (set `SallaPush.Debug.logLevel`),
  and `int(forKey:)` and `bool(forKey:)` (use `numberForKey:`).
- **Pass objects of the declared class.** An object of another class where the API declares `NSString`, `NSData`,
  `NSDictionary` or `NSArray`, such as an `NSNumber` from a bridge value typed `id`, crashes in Swift's bridging
  before SallaPush runs. Check it with `isKindOfClass:`, or convert it first.
- **Nil where the header says `_Nonnull`** never crashes SallaPush, except a nil content handler passed to the
  extension's `didReceive:withContentHandler:`: pass the one iOS gave your extension, unchanged.
- **`willPresentNotification:presentationOptions:`** returns a `BOOL` that must be used or cast to `void`, as above.

### Apps without a notification delegate

If your app has no `UNUserNotificationCenter` delegate, assign SallaPush's ready-made one in
`didFinishLaunchingWithOptions`:

<!-- snippet:ReadmeSnippets/AppShapes.swift#ready-made-delegate -->
```swift
SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
UNUserNotificationCenter.current().delegate = SallaPush.Notifications.notificationCenterDelegate
```

It forwards to SallaPush, shows other notifications with banner, list, sound and badge, and calls every completion
handler once. You still forward the APNs token from your app delegate. The class
`SallaPushNotificationCenterDelegate` is `open`: subclass it to add your own handling, and call `super`:

<!-- snippet:ReadmeSnippets/AppShapes.swift#delegate-subclass -->
```swift
final class ShopNotificationDelegate: SallaPushNotificationCenterDelegate {
    override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                         withCompletionHandler completionHandler: @escaping () -> Void) {
        Telemetry.report(source: "push", code: "opened", message: response.actionIdentifier, metadata: [:])
        super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
}
```

`UNUserNotificationCenter` holds its delegate weakly, so keep your subclass's instance in a property of your app
delegate, and assign that property:

<!-- snippet:ReadmeSnippets/AppShapes.swift#delegate-subclass-owner -->
```swift
// UNUserNotificationCenter holds its delegate weakly: this property keeps it alive.
private let notificationDelegate = ShopNotificationDelegate()
```

## Notifications

### Permission

<!-- snippet:ReadmeSnippets/Notifications.swift#request-permission -->
```swift
SallaPush.Notifications.requestPermission(fallbackToSettings: true) { granted in
    SettingsScreen.shared.show(permissionGranted: granted)
}
```

- **`fallbackToSettings: true`** opens your app's notification settings when the user already said no, because iOS
  shows the prompt only once. The `async` form is in the [README](../README.md#notification-permission).
- **The completion** runs once, on the main thread, after the permission getters were updated.
- **`registerForProvisionalAuthorization(completion:)`** asks for quiet notifications, without a prompt.
- **Your own prompt works too.** SallaPush reads the permission again whenever the app becomes active, and whenever
  you forward a token. After any other change, call `SallaPush.Notifications.refreshPermission()`.
- **The getters.** `permission` is true for authorized, provisional and ephemeral; `permissionStatus` is the
  `UNAuthorizationStatus`; `canRequestPermission` is true while iOS can still show the prompt. They fill in shortly
  after `initialize`, and `addPermissionObserver` reports changes.

### Foreground notifications

A SallaPush notification that arrives while the app is in the foreground is shown as a banner, in the list and with
sound. Foreground listeners (the [README](../README.md#foreground-notifications) has an example) run on the main thread
just before that:

- **`preventDefault()`** keeps the notification from being shown now. Call it before your listener returns.
- **`display()`** shows it later as a local copy, once, within 10 minutes, without its image, action buttons,
  interruption level and relevance score, and a later push with the same collapse id doesn't replace it. A `display()`
  for a notification that wasn't prevented in time, a second one, or a late one does nothing and logs
  `notif.display_failed`.
- **While the user is opted out,** SallaPush notifications aren't shown in the foreground and the listeners don't run.
- **Forward `willPresent` on the main thread,** where iOS calls it. From another thread, SallaPush skips the listeners
  and logs `notif.off_main_thread`.
- **`SallaPushForegroundLifecycleListener`** is the listener object form, added with
  `addForegroundLifecycleListener(_:)` and removed with `removeForegroundLifecycleListener(_:)`.

### Taps

Add a click listener as the [README](../README.md#notification-taps-and-deep-links) shows, or use a listener object:
add it with `SallaPush.Notifications.addClickListener(tapRouter)`, keep it (SallaPush holds it weakly), and stop it with
`removeClickListener(tapRouter)`:

<!-- snippet:ReadmeSnippets/Notifications.swift#click-listener-object -->
```swift
@MainActor
final class TapRouter: NSObject, SallaPushClickListener {
    func onClick(event: SallaPushClickEvent) {
        route(event.notification)
    }
}
```

- **On the main thread.** `event.notification` is the parsed notification, `event.result.actionId` the action button
  (nil for a tap on the notification itself) and `event.result.url` its launch URL.
- **Cold starts.** Up to 10 taps that arrive before the first listener is added are kept for 5 minutes and delivered
  to it, so adding the listener a little later during launch is fine.
- **One tap, one click.** A tap that reaches SallaPush twice, for example from your scene's connection options and
  from the delegate, is delivered once. Dismissals are never clicks.

### Launch URLs

SallaPush never opens a notification's URL on its own. The URL is in `event.result.url` and
`notification.launchURL`, for your router. Set `openLaunchURLs` in the [configuration](#configuration) to let
SallaPush open https URLs on tap.

## Routing taps yourself

If your app routes taps from its own `didReceive` instead of a click listener, read the payload with `parse(_:)`:

<!-- snippet:ReadmeSnippets/Notifications.swift#parse -->
```swift
SallaPush.Notifications.didReceive(response)
if let notification = SallaPush.Notifications.parse(response.notification.request.content.userInfo) {
    route(notification)
}
completionHandler()
```

Read your data with the typed accessors, never with raw `userInfo` keys:

<!-- snippet:ReadmeSnippets/Notifications.swift#route -->
```swift
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
```

- **The keys** (`type` and `id` above) are your own data, chosen by whoever sends the notification.
- **`string(forKey:)`, `int(forKey:)`, `bool(forKey:)` and `number(forKey:)`** read a value sent as a number or as a
  string alike: `"id": 42` and `"id": "42"` give the same result.
- **`parse(_:)`** returns nil, and `isSallaPushNotification(_:)` false, for other SDKs' notifications.

| `SallaPushNotification` | What it holds |
|---|---|
| `notificationId` | The SallaPush message id |
| `title`, `subtitle`, `body` | The alert's texts |
| `imageURL` | The image, https only |
| `launchURL` | The launch URL |
| `additionalData` | Your data |
| `badge`, `sound`, `threadId` | The `aps` values |
| `source` | The payload format, `.native` or `.compat` |
| `rawPayload` | The whole `userInfo` |

## Badges

SallaPush counts its notifications on the app icon's badge:

- **Each SallaPush notification adds 1.** The Notification Service Extension counts it, in place of a `badge` the push
  carries. One that replaces an earlier notification with the same collapse id doesn't add 1 while the earlier one is
  still counted.
- **When the app opens,** every time it becomes active, the badge goes back to 0 (`autoClearBadge`). A SallaPush
  notification that arrives while the app is open doesn't change it.
- **`SallaPush.Notifications.clearAll()`** removes the delivered SallaPush notifications only, other SDKs' stay, and
  sets the badge to 0 while `autoUpdateBadge` is on.
- **Counting needs** the Notification Service Extension and the same App Group in the app and the extension. It starts
  once the app has run this version, and, if you require consent, once the user gave it. iOS doesn't run the extension
  for an app whose alerts the user turned off: such a notification isn't counted, and its own `badge` applies.

Two settings change this, and both are on by default on iOS (the Android SDK leaves `autoClearBadge` off):

<!-- snippet:ReadmeSnippets/Configuration.swift#badges -->
```swift
let configuration = SallaPushConfiguration()
// Keep the badge when the app opens: it then counts the SallaPush notifications still in Notification Center.
configuration.autoClearBadge = false
// Never set a number: the badge is left to your app and to the push's own badge.
configuration.autoUpdateBadge = false
SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions, configuration: configuration)
```

- **`autoClearBadge = false`** keeps the badge when the app opens: it then counts the SallaPush notifications still in
  Notification Center. Opening one lowers it at once; one cleared in Notification Center lowers it the next time the
  app becomes active or goes to the background.
- **`autoUpdateBadge = false`** turns counting off, and a push's own `badge` applies. An app that wants its own number
  turns both off and sets the badge itself, with `UNUserNotificationCenter.setBadgeCount(_:)` on iOS 16 and later, or
  `UIApplication.shared.applicationIconBadgeNumber` on iOS 15.
- **One badge per app.** The icon shows the last number written: by SallaPush, another SDK, a push's own `badge` or
  your app. The next SallaPush notification sets SallaPush's count again.
- **iOS 15.** Setting the badge to 0 there also removes the app's delivered notifications, other SDKs' included, so
  the default `autoClearBadge` removes them at almost every activation: apps that must keep them set
  `autoClearBadge = false`. `clearAll()` still removes only SallaPush's notifications (`badge.zero_skipped`).
- **Consent.** While consent is required and not given, SallaPush neither counts nor clears.

## The user

### Login and logout

- **`SallaPush.login(externalId:identityToken:)`** links the device to the customer. `externalId` is the customer's
  id as Salla knows it (1 to 128 characters), and `identityToken` the customer token your app received at sign-in,
  without a `Bearer ` prefix. The device is linked only when the token belongs to that customer.
- **Call `login`** after the customer signs in, at each app launch while they're signed in, and again when your app
  refreshes their token. It sends nothing when the device is already linked to that customer.
- **Call `logout()`** after every sign-out, the forced ones too, such as an expired session. It works offline and
  without a token. The device stays registered as a guest.
- **Also call `logout()` at each app launch while nobody is signed in.** After a reinstall, it unlinks the customer of
  the earlier install. It sends nothing when the device isn't linked.
- **An account switch** is a `login` for another customer. With `clearTagsOnLogout` (the default), SallaPush first
  deletes the device's tags, so set the new customer's tags after `login`.
- **`SallaPush.User.isLoggedIn` and `externalId`** reflect your last `login` or `logout` as soon as it returns, and
  `SallaPush.User.addObserver` reports their changes.

### Login failures

<!-- snippet:ReadmeSnippets/Identity.swift#login-failures -->
```swift
loginFailures = SallaPush.User.addLoginFailureHandler { failure in
    if failure == .tokenRejected {
        // Salla refused this token for this customer id: log in again once the app has a current token.
        Telemetry.report(source: "sallapush", code: "token_rejected", message: "Login refused", metadata: [:])
    }
}
```

| Failure | Meaning | What to do |
|---|---|---|
| `.tokenRejected` | Salla didn't accept the token for that customer (`login.rejected`): it expired, it belongs to another customer, or it has a `Bearer ` prefix. | Call `login` again once your app has a current token. Check that `externalId` is the id of the token's customer, written as Salla writes it (`"42"`, not `"customer_42"`). |
| `.invalidRequest` | The login was refused as invalid (`identity.client_error`). | Contact the Salla team with your app id. |

A `login` with the same id and token less than 5 minutes after a refusal sends nothing, so a handler that calls
`login` again can't loop. Keep the returned `SallaPushObservation`: the handler lives until you call `cancel()` or
release it. `SallaPushUserObserver.onLoginFailure(_:)` is the protocol form.

### Tags

<!-- snippet:ReadmeSnippets/User.swift#remove-tags -->
```swift
SallaPush.User.removeTags(["total_cart_amount", "cart_items"])
```

- **Keys** are trimmed and lowercased, then must be 1 to 64 characters of `a-z`, `0-9` and `_`, or they are dropped
  (`tags.invalid_key`).
- **Values** longer than 255 characters are truncated (`tags.value_truncated`). An empty value removes the tag.
- **At most 100 tags.** Additions beyond that are dropped (`tags.limit`). At 100 tags, a change of an existing tag's
  value can be refused too (`tags.rejected_key`): remove a tag first.
- **`getTags()`** returns the tags with your latest changes applied, also before they are sent.
- **A logout and an account switch** delete the device's tags while `clearTagsOnLogout` is on (the default).

### Language

<!-- snippet:ReadmeSnippets/User.swift#language -->
```swift
SallaPush.User.setLanguage(code)
```

Pass your app's language code, such as `ar`, whenever it changes; nil means the device language.

### Push subscription

<!-- snippet:ReadmeSnippets/User.swift#opt-out -->
```swift
if isOn {
    SallaPush.User.pushSubscription.optIn()
} else {
    SallaPush.User.pushSubscription.optOut()
}
```

- **`optOut()`** stops SallaPush notifications on this device, which stays registered. **`optIn()`** undoes it, and
  shows the permission prompt when the app never asked.
- **`optedIn`** is true when notifications are allowed, the user didn't opt out, and the device has a token.
- **`id`** is the SallaPush device id. **`token`** is the APNs token in lowercase hex: keep it private.
- **`addObserver`** reports changes, on the main thread. An observer added while the device is registered gets one
  call right away, with `previous` equal to `current`. Keep the returned `SallaPushObservation`: the observer lives
  until you call `cancel()` or release it. Protocol observers (`SallaPushSubscriptionObserver`,
  `SallaPushUserObserver`, `SallaPushPermissionObserver`) are held weakly.

### The getters at launch

Right after a launch, until SallaPush has loaded what earlier launches saved, the getters show only what this launch's
calls did: `pushSubscription.id` and `token` are nil, `optedIn` is false, and `getTags()` holds only the tags set
since launch. So don't read them at launch to decide anything: read them in the subscription observer, as the example
app does.

## Consent

For apps that need the user's consent first (PDPL), require it before `initialize` at every launch, as the
[README](../README.md#consent) shows, then record the user's choice whenever they make it:

<!-- snippet:ReadmeSnippets/Consent.swift#consent-given -->
```swift
func privacyChoiceChanged(allowsNotifications: Bool) {
    SallaPush.setConsentGiven(allowsNotifications)
}
```

- **Consent is required** after `setConsentRequired(true)`, which isn't saved, or with `requiresUserConsent` in the
  [configuration](#configuration).
- **Until consent is given,** SallaPush sends nothing, saves nothing but the answer, and doesn't register for remote
  notifications. Your calls wait in memory (up to 100 tag, language and opt-in calls; logins and logouts are always
  kept) and run in order once consent is given. A launch that ends before that drops them.
- **`setConsentGiven(true)`** is saved, and SallaPush starts.
- **`setConsentGiven(false)`** while consent is required withdraws it: SallaPush drops what it hasn't sent, forgets
  the customer's id and the tags (`externalId` turns nil and `getTags()` empty), opts the device out, deletes its tags
  and logs it out, then does nothing more until consent is given again (`consent.revoked`). While consent isn't
  required, it only saves the answer.

## Configuration

`initialize` has a second form that takes a `SallaPushConfiguration`:

<!-- snippet:ReadmeSnippets/Configuration.swift#configuration -->
```swift
let configuration = SallaPushConfiguration()
configuration.logLevel = .info
configuration.openLaunchURLs = true
SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions, configuration: configuration)
```

| Property | Default | Meaning |
|---|---|---|
| `appGroupIdentifier` | Info.plist `SallaPushAppGroup` | The App Group shared with the extension; blank means none |
| `logLevel` | Info.plist `SallaPushLogLevel`, else `.warn` | The console log level ([Logging](LOGGING.md#logging)) |
| `apnsEnvironment` | `.automatic` | Read from the provisioning profile: development profiles and the simulator are sandbox; App Store, TestFlight, ad hoc and enterprise builds are production. Set `.sandbox` or `.production` to override. |
| `appVersion` | `CFBundleShortVersionString` | The app version SallaPush reports |
| `autoClearBadge` | `true` | Set the badge to 0 whenever the app becomes active ([Badges](#badges)) |
| `autoUpdateBadge` | `true` | Count SallaPush notifications on the badge ([Badges](#badges)) |
| `clearTagsOnLogout` | `true` | Delete the device's tags on a logout and an account switch ([Tags](#tags)) |
| `registerForRemoteNotificationsOnInit` | `true` | Call `registerForRemoteNotifications()` when SallaPush starts, and after a grant through `requestPermission`. Turn it off only if your app calls `registerForRemoteNotifications()` itself at every launch, or SallaPush gets no APNs token (`token.missing`). |
| `openLaunchURLs` | `false` | Open https launch URLs on tap |
| `requiresUserConsent` | `false` | Wait for `setConsentGiven(true)` ([Consent](#consent)) |

- **`initialize` copies the configuration**, so later changes to the object do nothing.
- **A second `initialize`** with the same app id changes nothing; one with another app id switches to it.
- **An invalid app id** (anything but 1 to 64 characters of letters, digits, `_` and `-`) logs `init.invalid_app_id`.
  In the first `initialize`, it disables SallaPush until the app is launched again; after a valid `initialize`, it is
  ignored.
- **`launchOptions`** is accepted and not used.
- **`SallaPush.isInitialized`, `SallaPush.appId` and `SallaPush.sdkVersion`** report the state.

## Info.plist keys

| Key | In | Value |
|---|---|---|
| `SallaPushAppGroup` | the app and the extension | The App Group both targets share. Leave it out when you have none. |
| `SallaPushLogLevel` | the app and the extension | `off`, `error`, `warn` (the default), `info`, `debug` or `verbose`. The extension reads only its own: set it to `info` there to see why it doesn't report `received` (`nse.received_deferred`) or count the badge (`nse.badge_skipped`). |
| `SallaPushLogFullIdentifiers` | the app; debug builds only | `YES` shows the full push token and the customer's id in the info status lines `status.launch` and `status.changed`, in the APNs sandbox only (the simulator, and builds signed with a development profile). Never set it in a release build. |

Every key is optional, and a value set in a [`SallaPushConfiguration`](#configuration) wins over the Info.plist. The
example project sets its keys from build settings such as `$(SALLAPUSH_APP_GROUP)`, so that one setting serves both
targets.

## Privacy and size

- **Privacy manifests.** Each library ships one, and Xcode adds them to your app's privacy report. Both declare no
  tracking, no tracking domains and no required-reason APIs, and the same data, linked to the user: Device ID and
  User ID, for app functionality, and Product Interaction (notification events), for analytics and app functionality.
- **Binary size.** SallaPush adds 1,192,060 bytes (1.14 MiB) to an app, measured for 1.1.0 in a Release archive with
  Xcode 26.4, and a Notification Service Extension links 448,919 bytes of `SallaPushCore` and `SallaPushExtension`.
