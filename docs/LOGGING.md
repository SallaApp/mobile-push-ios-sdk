# SallaPush iOS SDK: logging

Log levels, the log handler, and every log code SallaPush writes. For the short guide, see the [README](../README.md).

Other docs: [Reference](REFERENCE.md) · [Troubleshooting](TROUBLESHOOTING.md)

## Contents

- [Logging](#logging)
- [Log code reference](#log-code-reference)

## Logging

SallaPush logs to the unified log under the subsystem `com.salla.push`, one line per entry:

```text
[SallaPush] WARN tags.invalid_key: Tag key "cart-items" is invalid after lowercasing (a-z, 0-9, _; max 64); dropped.
```

- **Levels:** `off`, `error`, `warn`, `info`, `debug` and `verbose`, from silent to most detailed. The default is
  `warn`.
- **Precedence:** `SallaPush.Debug.logLevel` at run time, then `SallaPushConfiguration.logLevel`, then the Info.plist
  key `SallaPushLogLevel`, then `warn`. For example:

  <!-- snippet:ReadmeSnippets/Logging.swift#log-level -->
  ```swift
  SallaPush.Debug.logLevel = .verbose
  ```

- **Status lines, at `info`.** `status.launch` sums up each launch in one line: the device id and its registration,
  the push token's last 6 characters, the APNs environment, the permission, `opted_in`, the customer's link (without
  their id), the language, and consent while it is withheld. Each later change logs `status.changed`, old → new.
- **Release builds log too:** secrets never reach a line ([What is never logged](#what-is-never-logged)).

### Forward entries to your telemetry

<!-- snippet:ReadmeSnippets/Logging.swift#log-handler -->
```swift
SallaPush.Debug.setLogHandler(level: .error) { entry in
    Telemetry.report(source: "sallapush", code: entry.code, message: entry.message, metadata: entry.metadata)
}
```

- **Its own level.** The handler receives the entries at or below its level (`.warn` when you leave it out), whatever
  the console level. Pass nil to remove it.
- **Off the main thread.** It runs on a private serial queue: call only thread-safe code from it, such as a
  `nonisolated` function, or hop to the main actor with `Task { @MainActor in … }`. When it falls behind, the oldest
  entries go, and one `log.dropped` entry says how many.
- **Early problems.** The first handler also receives the warnings and errors logged before it was set (up to 100), so
  set it right after `initialize` and it still sees an invalid app id. It must not throw.
- **An entry** has a `level`, a `category`, a stable `code`, a one-line `message`, a `date`, and `metadata` such as
  `http_status` and `reason`. Codes never change: match on them, not on messages.
- **Info entries describe the device** (`status.launch`, `status.changed`): don't forward them to third parties. A
  handler at `.warn`, the default, never receives them.

### What is never logged

The device secret, the identity token, request bodies and notification payload values. Every line shows at most the
push token's last 6 characters, and no customer identifier, except the status lines of a development build whose
Info.plist sets `SallaPushLogFullIdentifiers` to `YES` ([Info.plist keys](REFERENCE.md#infoplist-keys)).

### The extension's logs

The Notification Service Extension logs with the category `extension`, at the level of its own Info.plist
`SallaPushLogLevel`, `warn` by default. Set it to `info` there to see `nse.received_deferred` and `nse.badge_skipped`,
or to `debug` to see `nse.received_sent` and `nse.badge_set` too.

## Log code reference

Every code SallaPush logs on iOS, with its level. Codes are stable across releases.

<!-- log-codes:start -->
| Code | Level | Meaning |
|---|---|---|
| `init.started` | info | SallaPush started, with the app id, the APNs environment setting and the log level |
| `init.invalid_app_id` | error | The app id is invalid: in the first `initialize`, SallaPush is disabled until the next launch; after a valid one, it is ignored |
| `init.app_id_changed` | warn | `initialize` switched to another app id |
| `init.drain_started` | info | Finishing another app id's pending logout from an earlier launch |
| `init.buffer_full` | warn | Too many calls before SallaPush could take them; the oldest tag, language and opt-in calls or events were dropped |
| `init.no_delegate` | warn | No `UNUserNotificationCenter` delegate is set |
| `config.no_app_group` | info | No App Group: `received` is reported only from the app, and nothing is counted on the badge |
| `status.launch` | info | SallaPush's status at launch: the device id and its registration, the push token's last 6 characters, the APNs environment, the permission, `opted_in`, the customer's link, the language, and consent while it is withheld |
| `status.changed` | info | The status changed: each field that changed, old → new |
| `consent.waiting` | info | Waiting for `setConsentGiven(true)` |
| `consent.given` | info | Consent given; SallaPush starts |
| `consent.revoked` | info | Consent was withdrawn; SallaPush is idle |
| `api.invalid_argument` | warn | A call was ignored, or went ahead with a default, because of an argument; SallaPush is disabled by an invalid app id (logged once); or the Info.plist `SallaPushLogLevel` value isn't a level |
| `api.callback_repeated` | debug | A completion was called more than once; the extra calls were ignored |
| `token.received` | info | The APNs token reached SallaPush |
| `token.unchanged` | debug | The same token again |
| `token.invalid` | warn | The token passed to SallaPush is empty or malformed |
| `token.missing` | warn | No token 30 seconds after the app came to the foreground |
| `token.registration_failed` | warn | iOS couldn't register for remote notifications; the message gives the reason |
| `register.ok` | info | The device is registered |
| `register.reregistering` | info | Registering again, with the reason |
| `register.dormant` | error | Registration waits 24 hours: the app id is unknown, or registration is unavailable |
| `update.sent` | debug | The device's details were updated |
| `heartbeat.sent` | debug | The daily device refresh was sent |
| `permission.changed` | info | The notification permission changed |
| `subscription.opted_out` | info | `optOut()` was called |
| `subscription.opted_in` | info | `optIn()` was called |
| `login.queued` | debug | A login waits, for example for the registration |
| `login.ok` | info | The customer is linked |
| `login.skipped_same` | debug | Already linked to this customer; nothing to send |
| `login.switched` | info | An account switch, or a login after a reinstall; the message says what happened to the previous customer's tags |
| `login.rejected` | warn | Salla refused the customer's token, so the device isn't linked to the customer (`.tokenRejected`) |
| `logout.queued` | info | A logout waits, and is retried until it is done |
| `logout.ok` | info | The customer is unlinked |
| `logout.skipped` | debug | Not linked: the logout needs no request |
| `identity.token_needed` | warn | Linking the device waits for the customer's token: call `login` at each launch while the customer is signed in |
| `identity.client_error` | error | A login or a logout was refused as invalid (`.invalidRequest`) |
| `tags.flushed` | debug | Tags were sent |
| `tags.normalized` | debug | A tag key was lowercased |
| `tags.invalid_key` | warn | A tag key is invalid and was dropped |
| `tags.value_truncated` | warn | A tag value was longer than 255 characters and was truncated |
| `tags.limit` | warn | More than 100 tags; the extra additions were dropped |
| `tags.rejected_key` | warn | A tag was refused and dropped; the others were kept |
| `events.flushed` | debug | Events were sent |
| `events.dropped` | warn | Old events were dropped |
| `events.queue_full` | warn | The event queue is full: the oldest events are dropped, or the extension records no more `received` until the app is opened |
| `inbox.ingested` | debug | The app read the `received` events the extension recorded |
| `inbox.invalid_file` | debug | An unreadable record of the extension was removed |
| `net.retry` | info | A request failed and will be retried, with the delay |
| `net.retry_exhausted` | warn | A request failed 6 times; it is tried again at the next launch, foreground or network change |
| `net.rate_limited` | warn | SallaPush was asked to slow down |
| `net.client_error` | error | A request was refused |
| `net.redirect_refused` | error | A request was answered with a redirect, which SallaPush never follows |
| `net.invalid_response` | warn | An unexpected answer; the request will be retried |
| `net.routes_closed` | warn | The service is unavailable; pending work is kept and tried again later |
| `storage.keychain_locked` | warn | Data is unavailable until the first unlock; waiting |
| `storage.failed` | error | SallaPush data couldn't be read or written, or the App Group is unavailable |
| `storage.state_reset` | error | Saved data was unreadable and was reset |
| `notif.foreign` | verbose | Another SDK's notification was ignored |
| `notif.parse_failed` | warn | A SallaPush notification was only partly readable |
| `notif.unknown_version` | warn | A notification of a newer format, read with the current rules |
| `notif.off_main_thread` | warn | `willPresent` was forwarded off the main thread; the foreground listeners were skipped |
| `notif.display_failed` | warn | A notification couldn't be shown, with the reason |
| `notif.suppressed` | debug | A notification wasn't shown, because the user opted out |
| `notif.click_queued` | debug | A tap is kept until a click listener is added |
| `notif.click_delivered` | debug | A tap was delivered to the click listeners |
| `badge.cleared` | debug | The app became active, and SallaPush set the badge to 0 (`autoClearBadge`) |
| `badge.set` | debug | SallaPush set the badge to its count, after a tap, `clearAll()` or a change in Notification Center |
| `badge.zero_skipped` | debug | iOS 15: the badge was left as it is, because 0 would also remove another SDK's delivered notifications |
| `lifecycle.background_expired` | warn | Background time ran out; pending work was saved |
| `log.dropped` | warn | The log handler fell behind and entries were dropped |
| `nse.attachment_failed` | warn | The extension couldn't attach the image and delivered the notification without it |
| `nse.expired` | warn | The extension ran out of time and delivered its best attempt |
| `nse.replaced_request` | debug | A new notification arrived on the same extension instance; the previous one was delivered first |
| `nse.received_sent` | debug | The extension reported `received` itself |
| `nse.received_deferred` | info | The extension left `received` to the app, which reports it the next time it comes to the foreground; the message gives the reason, such as `no_credentials`, `main_thread` or `failed` |
| `nse.badge_set` | debug | The extension put SallaPush's count on a notification |
| `nse.badge_skipped` | info | The extension doesn't count notifications on the badge, with the reason: `no_app_group`, `no_app_bundle`, or `no_settings` (the app hasn't run this version with consent, or uses another App Group) |
<!-- log-codes:end -->
