import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// A warning's advice fits the app's situation. `identity.token_needed` tells
/// an app whose signed-in customer SallaPush cannot link (the identity token is kept in memory only) to call `login` at
/// every launch, and `token.missing` names the failure the OS reported instead of advising to forward a token the OS
/// never gave.
final class LogAdviceTests: XCTestCase {
    private let tokenNeeded = "SallaPush keeps the identity token in memory only and has none for the signed-in customer, "
        + "so this device is not linked to them; call login(externalId:identityToken:) at every launch while the customer "
        + "is signed in."

    /// A link left from the previous launch, whose token is gone, and no launch login: said once.
    func test_tokenNeeded_saysWhatTheAppCanDo() throws {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        h.login(customer: "cust_a")
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(2)
        let needed = next.logs.all.filter { $0.code == "identity.token_needed" }
        XCTAssertEqual(needed.map(\.message), [tokenNeeded])
        XCTAssertEqual(needed.first?.level, .warn)
    }

    /// A re-registration with no token in memory (a relaunch without the launch login) says it too, once per launch.
    func test_tokenNeeded_afterAReRegistration_withoutATokenInMemory() throws {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(3)
        let next = h.relaunch()
        next.initialize()
        next.server.purge(next.deviceId)
        next.submit(.setLanguage("en"))
        next.advance(3)
        XCTAssertEqual(next.logs.all.filter { $0.code == "identity.token_needed" }.map(\.message), [tokenNeeded])
        XCTAssertTrue(next.server.requests("link").count == 1, "no link without a token")
        next.server.purge(next.deviceId)
        next.submit(.setLanguage("fr"))
        next.advance(3)
        XCTAssertEqual(next.logs.count("identity.token_needed"), 1, "once per launch")
    }

    /// A rejected token says no more than `login.rejected`, which already asks for the app's next `login`.
    func test_aRejectedToken_saysNoMoreThanLoginRejected() {
        let h = Harness()
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        XCTAssertTrue(h.logs.contains("login.rejected"))
        XCTAssertFalse(h.logs.contains("identity.token_needed"))
    }

    func test_tokenMissing_afterARegistrationFailure_namesTheFailure() throws {
        let h = Harness()
        h.initialize()
        h.submit(.registrationFailed("APNs 3000, no valid aps-environment entitlement"))
        h.advance(31)
        let missing = try XCTUnwrap(h.logs.all.first { $0.code == "token.missing" })
        XCTAssertEqual(missing.message, "No push token 30 s after the app came to the foreground: the OS could not register "
                           + "for remote notifications (APNs 3000, no valid aps-environment entitlement). Check the app's "
                           + "Push Notifications capability (the aps-environment entitlement).")
        let recovered = Harness()
        recovered.initialize()
        recovered.submit(.registrationFailed("APNs 3000, temporary"))
        recovered.sendToken()
        recovered.advance(60)
        XCTAssertFalse(recovered.logs.contains("token.missing"), "a token that came after the failure clears it")
    }

    func test_tokenMissing_withoutAFailure_asksToForwardTheToken() throws {
        let h = Harness()
        h.initialize()
        h.advance(31)
        let missing = try XCTUnwrap(h.logs.all.first { $0.code == "token.missing" })
        XCTAssertEqual(missing.message, "No push token 30 s after the app came to the foreground. Call "
                           + "SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken:) from your app "
                           + "delegate, and from any other SDK that receives the token in your app's place.")
    }
}
