import SallaPush
import UIKit

// README "Login and logout", and docs/REFERENCE.md "Login failures".

@MainActor
final class AuthEvents {
    private var loginFailures: SallaPushObservation?

    // snippet:sign-in-out
    func customerDidSignIn(customerId: String, token: String) {
        SallaPush.login(externalId: customerId, identityToken: token)
    }

    func customerDidSignOut() {
        SallaPush.logout()
    }
    // end-snippet

    func observeLoginFailures() {
        // snippet:login-failures
        loginFailures = SallaPush.User.addLoginFailureHandler { failure in
            if failure == .tokenRejected {
                // Salla refused this token for this customer id: log in again once the app has a current token.
                Telemetry.report(source: "sallapush", code: "token_rejected", message: "Login refused", metadata: [:])
            }
        }
        // end-snippet
    }
}
