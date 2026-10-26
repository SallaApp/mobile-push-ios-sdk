import SallaPush
import UIKit

// README "Tags and language" and "Push subscription", and docs/REFERENCE.md "The user".

@MainActor
final class UserSettings {
    private var subscriptionObserver: SallaPushObservation?

    func cartChanged(total: Int, items: Int) {
        // snippet:tags
        SallaPush.User.addTag(key: "add_to_cart", value: String(Int(Date().timeIntervalSince1970)))
        SallaPush.User.addTags(["total_cart_amount": String(total), "cart_items": String(items)])
        // end-snippet
    }

    func cartEmptied() {
        // snippet:remove-tags
        SallaPush.User.removeTags(["total_cart_amount", "cart_items"])
        // end-snippet
    }

    func languageChanged(to code: String) {
        // snippet:language
        SallaPush.User.setLanguage(code)
        // end-snippet
    }

    func pushToggleChanged(isOn: Bool) {
        // snippet:opt-out
        if isOn {
            SallaPush.User.pushSubscription.optIn()
        } else {
            SallaPush.User.pushSubscription.optOut()
        }
        // end-snippet
    }

    func observeSubscription() {
        // snippet:subscription-observer
        subscriptionObserver = SallaPush.User.pushSubscription.addObserver { state in
            SettingsScreen.shared.show(deviceId: state.current.id, optedIn: state.current.optedIn)
        }
        // end-snippet
    }
}
