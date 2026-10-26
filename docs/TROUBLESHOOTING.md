# SallaPush iOS SDK: troubleshooting

Common problems and how to fix them. For the short guide, see the [README](../README.md).

Other docs: [Reference](REFERENCE.md) · [Logging](LOGGING.md)

Turn on verbose logs first (`SallaPush.Debug.logLevel = .verbose`), and filter the Xcode console on `SallaPush`.

| You see | Fix |
|---|---|
| `No such module 'SallaPush'` or `No such module 'SallaPushExtension'` | Add the `SallaPush` library to the app target and `SallaPushExtension` to the Notification Service Extension target ([Installation](../README.md#installation)). With CocoaPods, declare `SallaPushCore` and the pod in that target's block, run `pod install`, and open the `.xcworkspace`. Never add `SallaPush` to the extension. |
| `token.missing`, and no `token.received` | Forward the APNs token from `didRegisterForRemoteNotificationsWithDeviceToken`, also when another SDK in your app takes over that method, and check the Push Notifications capability. With `registerForRemoteNotificationsOnInit` off, call `registerForRemoteNotifications()` at every launch. |
| `token.registration_failed` | `remote notifications are not supported in the simulator`: use a simulator with iOS 16 or later on a Mac with Apple silicon or a T2 chip, or a device. `no valid “aps-environment” entitlement string found for application`: add the Push Notifications capability, and use a provisioning profile that has it. |
| `register.ok`, but no notification arrives | Check that `SallaPush.User.pushSubscription.optedIn` is true: it is false while notifications aren't allowed, after `optOut()` and without a token. Builds signed with a development profile use the APNs sandbox; TestFlight and App Store builds use production. |
| No image, or `received` only once the app opens | Embed the extension with `SallaPushExtension`, and call SallaPush's `didReceive` directly from your extension's `didReceive`. Images must be https and at most 10 MB (`nse.attachment_failed`). Use the same App Group in both targets and in both `SallaPushAppGroup` keys, and open the app once with this version. Set `SallaPushLogLevel` to `info` in the extension's Info.plist: `nse.received_deferred` gives the reason. |
| The badge doesn't count SallaPush notifications, or always shows 1 | The extension isn't counting: add it, use the same App Group in both targets, open the app once with this version, with consent, and check that `autoUpdateBadge` is on. iOS doesn't run the extension while the app's alerts are off in Settings. Set `SallaPushLogLevel` to `info` in the extension's Info.plist: `nse.badge_skipped` gives the reason. |
| `register.dormant` | Check your app id. SallaPush tries again after 24 hours, or at once after the app is deleted and installed again. |
| `init.invalid_app_id` | The app id must be 1 to 64 characters of letters, digits, `_` and `-`. An invalid first `initialize` disables SallaPush until the next launch. |
| `api.invalid_argument` for `login` | Pass the customer's id (1 to 128 characters) and their token (at most 4,096 characters). |
| `login.rejected` | Salla refused the token for that customer. Pass the customer's current token, without a `Bearer ` prefix, and check that `externalId` is that customer's id ([Login failures](REFERENCE.md#login-failures)). |
| `identity.token_needed` | Call `login` at each launch while the customer is signed in. |
| `init.no_delegate` | Set your notification delegate in `didFinishLaunchingWithOptions`, or use the [ready-made one](REFERENCE.md#apps-without-a-notification-delegate). |
| `config.no_app_group`, or `storage.failed` about an App Group | Add the same App Group to the app and the extension, and put it in `SallaPushAppGroup` in both Info.plist files. |
| `net.retry` or `net.retry_exhausted` | Nothing is lost: SallaPush retries with backoff. If it doesn't clear, check the device's network, such as a VPN, a proxy or a captive portal. |
