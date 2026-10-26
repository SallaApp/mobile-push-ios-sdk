import Foundation
import SallaPushCore

/// The customer and identity token of the last link push-service refused, as the app was told of it (memory only).
struct RefusedLogin: Sendable {
    let externalId: String
    let token: SecretString
    /// When push-service last refused them.
    var at: Double
}

/// A refused link is reported once. The app's `login` with the same customer and token sends nothing for 5 minutes, so
/// an app that calls `login` again from its login failure handler never makes SallaPush loop; after that the token goes
/// again, since push-service also refuses a token it couldn't check, and a refusal of it is not reported again. A new
/// token, another customer, a `logout()` and a successful link end the wait.
extension Engine {
    /// How long after push-service refused a link a `login` with the same customer and token sends nothing.
    static let refusedLoginWait: Double = 300

    /// A login of the customer and token push-service refused less than 5 minutes ago sends nothing and reports
    /// nothing, and the token is forgotten again. Returns whether the call was settled so.
    func skipsRefusedLogin(externalId: String, token: SecretString, now: Double) -> Bool {
        guard let refused = refusedLogin, refused.externalId == externalId, refused.token == token,
              now >= refused.at, now - refused.at < Self.refusedLoginWait
        else { return false }
        identityToken = nil
        let seconds = Int(now - refused.at)
        logger.log(.loginRejected, "The SallaPush server refused this identity token for this customer \(seconds) s "
                       + "ago; it is not sent again now. Call login(externalId:identityToken:) with a new token.")
        return true
    }

    /// Remembers the refusal of the app's current login and returns whether to report it: a refusal of the customer and
    /// token the app was already told of is not reported again, and the wait starts again from it.
    func rememberRefusal(of op: IdentityOp, token: SecretString, now: Double) -> Bool {
        guard let externalId = op.externalId else { return true }
        if var refused = refusedLogin, refused.externalId == externalId, refused.token == token {
            refused.at = now
            refusedLogin = refused
            return false
        }
        refusedLogin = RefusedLogin(externalId: externalId, token: token, at: now)
        return true
    }
}
