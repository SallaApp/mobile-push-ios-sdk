import SallaPush
import UIKit

// README and docs/REFERENCE.md "Consent".

final class ConsentAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // snippet:consent-required
        SallaPush.setConsentRequired(true)
        SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)
        // end-snippet
        return true
    }

    // snippet:consent-given
    func privacyChoiceChanged(allowsNotifications: Bool) {
        SallaPush.setConsentGiven(allowsNotifications)
    }
    // end-snippet
}
