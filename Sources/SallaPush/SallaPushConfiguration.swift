import Foundation
import SallaPushCore

/// Options for `SallaPush.initialize(_:withLaunchOptions:configuration:)`. `initialize` copies it, so later changes
/// to this object have no effect.
@objc public final class SallaPushConfiguration: NSObject, NSCopying {
    /// The App Group shared with the Notification Service Extension, used to report `received` events.
    /// nil reads Info.plist `SallaPushAppGroup`; a blank value means no App Group.
    @objc public var appGroupIdentifier: String?
    /// The console log level. Setting it overrides Info.plist `SallaPushLogLevel`; `Debug.logLevel` overrides both.
    @objc public var logLevel: SallaPushLogLevel {
        get { storedLogLevel }
        set {
            storedLogLevel = newValue
            logLevelIsExplicit = true
        }
    }
    /// The APNs environment of this build. `.automatic` reads it from the provisioning profile.
    @objc public var apnsEnvironment: SallaPushAPNsEnvironment = .automatic
    /// The app version sent to SallaPush. nil sends `CFBundleShortVersionString`.
    @objc public var appVersion: String?
    /// Sets the app icon badge, and SallaPush's count of its notifications, to 0 every time the app becomes active; a
    /// SallaPush notification shown while the app is in the foreground then doesn't change the badge. `false` keeps the
    /// badge: with `autoUpdateBadge` on, it counts the SallaPush notifications still in Notification Center. On iOS 15,
    /// a badge set to 0 also removes the app's delivered notifications, other SDKs' included. Default true.
    @objc public var autoClearBadge = true
    /// SallaPush counts its notifications on the app icon badge: the Notification Service Extension adds 1 for each
    /// SallaPush notification, in place of a badge the push carries, and opening one lowers it. Counting needs the
    /// extension and the same App Group in the app and the extension. `false`: SallaPush never sets a number, except
    /// `autoClearBadge`'s 0, and a push's own badge applies. Default true.
    @objc public var autoUpdateBadge = true
    /// Deletes the device's tags on logout, and when a login switches to another customer. After a reinstall, the launch
    /// `logout()` or `login` deletes the earlier install's tags too, and keeps those set earlier in that launch.
    /// Default true.
    @objc public var clearTagsOnLogout = true
    /// Calls `registerForRemoteNotifications()` (on main) when SallaPush starts. Default true.
    /// Skipped while consent is required and not given.
    @objc public var registerForRemoteNotificationsOnInit = true
    /// Opens https launch URLs on tap. Default false: SallaPush hands URLs to your click listeners and never opens them.
    @objc public var openLaunchURLs = false
    /// Requires `SallaPush.setConsentGiven(true)` before SallaPush sends anything or stores anything but the consent
    /// answer. Default false.
    @objc public var requiresUserConsent = false

    private var storedLogLevel: SallaPushLogLevel = .warn
    /// Whether `logLevel` was set explicitly.
    private(set) var logLevelIsExplicit = false
    /// The server URL of the SDK's own tests; nil, as in every app, uses the built-in production URL. Internal and not
    /// `@objc`, so an app can't set it.
    var apiBaseURL: URL?

    /// Forgets an explicitly set log level (used when it was not a declared level).
    func resetLogLevel() {
        storedLogLevel = .warn
        logLevelIsExplicit = false
    }

    /// Creates a configuration with the defaults.
    @objc public override init() {
        super.init()
    }

    /// A copy with the same values.
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = SallaPushConfiguration()
        copy.apiBaseURL = apiBaseURL
        copy.appGroupIdentifier = appGroupIdentifier
        copy.storedLogLevel = storedLogLevel
        copy.logLevelIsExplicit = logLevelIsExplicit
        copy.apnsEnvironment = apnsEnvironment
        copy.appVersion = appVersion
        copy.autoClearBadge = autoClearBadge
        copy.autoUpdateBadge = autoUpdateBadge
        copy.clearTagsOnLogout = clearTagsOnLogout
        copy.registerForRemoteNotificationsOnInit = registerForRemoteNotificationsOnInit
        copy.openLaunchURLs = openLaunchURLs
        copy.requiresUserConsent = requiresUserConsent
        return copy
    }
}
