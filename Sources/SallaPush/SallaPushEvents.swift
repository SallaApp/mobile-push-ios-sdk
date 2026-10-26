import Foundation
import SallaPushCore

/// What the user tapped.
@objc public final class SallaPushClickResult: NSObject, @unchecked Sendable {
    /// The action identifier of a custom action button; nil for a tap on the notification itself.
    @objc public let actionId: String?
    /// The notification's launch URL, if any. SallaPush does not open it unless `openLaunchURLs` is set.
    @objc public let url: String?

    init(actionId: String?, url: String?) {
        self.actionId = actionId
        self.url = url
        super.init()
    }
}

/// A tap on a SallaPush notification, delivered on main to click listeners.
@objc public final class SallaPushClickEvent: NSObject, @unchecked Sendable {
    /// The notification that was tapped.
    @objc public let notification: SallaPushNotification
    /// The action and URL of the tap.
    @objc public let result: SallaPushClickResult

    init(notification: SallaPushNotification, result: SallaPushClickResult) {
        self.notification = notification
        self.result = result
        super.init()
    }
}

/// A SallaPush notification about to be shown in the foreground. Delivered synchronously on main;
/// call `preventDefault()` before your listener returns to stop it from being shown, and `notification.display()` to
/// show it later.
@objc public final class SallaPushWillDisplayEvent: NSObject {
    /// The notification about to be shown.
    @objc public let notification: SallaPushNotification
    private let prevented = Locked(false)

    /// Whether `preventDefault()` was called. Only a call made before the listener returned stops the notification.
    @objc public var isPrevented: Bool { prevented.current }

    init(notification: SallaPushNotification) {
        self.notification = notification
        super.init()
    }

    /// Stops the notification from being shown now. Call it before your listener returns: SallaPush decides when
    /// the listeners return, and a later call changes nothing.
    @objc public func preventDefault() {
        prevented.set(true)
    }
}

extension SallaPushNotification {
    /// Shows a foreground notification that a listener prevented (`preventDefault()` before it returned), as a local
    /// copy without its attachment and action buttons. Works once per notification, within 10 minutes of the
    /// will-display event, also from inside the listener; any other call does nothing and logs why (WARN
    /// `notif.display_failed`). The copy counts as the notification's display, and a tap on it as its open (`displayed`
    /// and `opened` events).
    @objc public func display() {
        Runtime.shared.router.display(self)
    }
}

/// The push subscription at one moment.
@objc public final class SallaPushSubscriptionState: NSObject, @unchecked Sendable {
    /// The SallaPush device id; nil until the device is registered.
    @objc public let id: String?
    /// The APNs token in lowercase hex; nil until the app forwards one.
    @objc public let token: String?
    /// Permission granted, not opted out, and a token present.
    @objc public let optedIn: Bool

    init(id: String?, token: String?, optedIn: Bool) {
        self.id = id
        self.token = token
        self.optedIn = optedIn
        super.init()
    }
}

/// A change of the push subscription.
@objc public final class SallaPushSubscriptionChangedState: NSObject, @unchecked Sendable {
    /// The state before the change.
    @objc public let previous: SallaPushSubscriptionState
    /// The state after the change.
    @objc public let current: SallaPushSubscriptionState

    init(previous: SallaPushSubscriptionState, current: SallaPushSubscriptionState) {
        self.previous = previous
        self.current = current
        super.init()
    }
}

/// The user (customer link) at one moment.
@objc public final class SallaPushUserState: NSObject, @unchecked Sendable {
    /// The external id the app logged in with; nil for guests.
    @objc public let externalId: String?
    /// Whether `login(externalId:identityToken:)` was called and no `logout()` since.
    @objc public let isLoggedIn: Bool

    init(externalId: String?, isLoggedIn: Bool) {
        self.externalId = externalId
        self.isLoggedIn = isLoggedIn
        super.init()
    }
}

/// A change of the user.
@objc public final class SallaPushUserChangedState: NSObject, @unchecked Sendable {
    /// The state before the change.
    @objc public let previous: SallaPushUserState
    /// The state after the change.
    @objc public let current: SallaPushUserState

    init(previous: SallaPushUserState, current: SallaPushUserState) {
        self.previous = previous
        self.current = current
        super.init()
    }
}

/// Why a login did not link the device.
@objc public enum SallaPushLoginFailure: Int, Sendable {
    /// Salla refused the token: it expired, or it belongs to another customer. Call `login(externalId:identityToken:)`
    /// again with a current token.
    case tokenRejected
    // Raw values 1 and 2 are retired: never reuse them.
    /// The login was refused as invalid, and is not sent again.
    case invalidRequest = 3
}

/// Observes the user. Callbacks run on main.
@objc public protocol SallaPushUserObserver: AnyObject {
    /// The external id or the logged-in state changed.
    @MainActor func onUserStateDidChange(state: SallaPushUserChangedState)
    /// A login did not link the device.
    @MainActor @objc optional func onLoginFailure(_ failure: SallaPushLoginFailure)
}

/// Observes the push subscription. Callbacks run on main.
@objc public protocol SallaPushSubscriptionObserver: AnyObject {
    /// The device id, token or opted-in state changed. Added while registered, an observer gets one replay
    /// with `previous == current`.
    @MainActor func onPushSubscriptionDidChange(state: SallaPushSubscriptionChangedState)
}

/// Observes the notification permission. Callbacks run on main.
@objc public protocol SallaPushPermissionObserver: AnyObject {
    /// The permission changed.
    @MainActor func onNotificationPermissionDidChange(_ permission: Bool)
}

/// Receives taps on SallaPush notifications on main. Taps that arrive before the first listener is added
/// (a cold start) are kept for 5 minutes and delivered to it once.
@objc public protocol SallaPushClickListener: AnyObject {
    /// A SallaPush notification was tapped.
    @MainActor func onClick(event: SallaPushClickEvent)
}

/// Decides, synchronously on main, whether a SallaPush notification is shown in the foreground.
@objc public protocol SallaPushForegroundLifecycleListener: AnyObject {
    /// A SallaPush notification is about to be shown; call `event.preventDefault()` to stop it.
    @MainActor func onWillDisplay(event: SallaPushWillDisplayEvent)
}
