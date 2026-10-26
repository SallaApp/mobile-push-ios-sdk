import SallaPush
import UIKit

// docs/REFERENCE.md "Configuration".

final class ConfiguredAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // snippet:configuration
        let configuration = SallaPushConfiguration()
        configuration.logLevel = .info
        configuration.openLaunchURLs = true
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions, configuration: configuration)
        // end-snippet
        return true
    }
}

// docs/REFERENCE.md "Badges".

final class BadgeSettingsAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // snippet:badges
        let configuration = SallaPushConfiguration()
        // Keep the badge when the app opens: it then counts the SallaPush notifications still in Notification Center.
        configuration.autoClearBadge = false
        // Never set a number: the badge is left to your app and to the push's own badge.
        configuration.autoUpdateBadge = false
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions, configuration: configuration)
        // end-snippet
        return true
    }
}
