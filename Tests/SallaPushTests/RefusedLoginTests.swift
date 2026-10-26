import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// A link push-service refused (`403 invalid_identity_token`, `400`) is reported once. A `login` of that customer with
/// that token, made less than 5 minutes after the refusal, sends nothing and reports nothing, so an app that calls
/// `login` again from its login failure handler never makes SallaPush loop. After the 5 minutes the same token goes
/// again (push-service also answers 403 when it couldn't check a token), and a refusal of it is not reported again. A
/// new token, another customer and a `logout()` end the wait at once.
final class RefusedLoginTests: XCTestCase {
    /// A login failure handler that calls `login` again with the refused customer and token on every report.
    private func loggingInAgain(_ h: Harness, externalId: String, token: String) -> SallaPushObservation {
        let runtime = h.runtime
        return runtime.observers.addLoginFailureHandler { [weak runtime] _ in
            runtime?.login(externalId: externalId, identityToken: token)
        }
    }

    func test_aHandlerThatLogsInAgainWithTheRefusedToken_getsOneReport_andSendsNoOtherLink() {
        let h = Harness()
        let failures = FailureRecorder(h)
        let retrying = loggingInAgain(h, externalId: "cust_a", token: "eyJ.expired")
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        for _ in 0..<600 {
            h.advance(1)
        }
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        XCTAssertEqual(h.logs.all.last { $0.code == "login.rejected" }?.message,
                       "The SallaPush server refused this identity token for this customer 0 s ago; it is not sent "
                           + "again now. Call login(externalId:identityToken:) with a new token.")
        h.login(customer: "cust_a")
        XCTAssertEqual(h.server.requests("link").count, 1, "a new token waits the debounce, as any login")
        h.advance(1)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        retrying.cancel()
    }

    /// `400 invalid_request` is final as well: the same customer and token wait the same way.
    func test_aLinkRefusedAsInvalid_holdsTheSameTokenBackTheSameWay() {
        let h = Harness()
        let failures = FailureRecorder(h)
        let retrying = loggingInAgain(h, externalId: "cust_a", token: FakeServer.token(for: "cust_a"))
        h.registered()
        h.server.script("link", times: nil) { _ in FakeServer.error(400, "invalid_request") }
        h.login(customer: "cust_a")
        for _ in 0..<600 {
            h.advance(1)
        }
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(failures.failures.current, [.invalidRequest])
        retrying.cancel()
    }

    /// The wait runs from the last refusal: 5 minutes after it, the app's `login` sends the token again, and a refusal
    /// of it is not reported again and starts the wait again.
    func test_theSameToken_goesAgainFiveMinutesAfterTheRefusal_andItsNextRefusalIsNotReported() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        h.advance(297)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 1, "4 min 58 s after the refusal")
        h.advance(60)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2, "6 min after the refusal")
        XCTAssertEqual(failures.failures.current, [.tokenRejected], "the app was told of this token already")
        XCTAssertTrue(h.identityOps().isEmpty)
        h.advance(10)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2, "the second refusal started the wait again")
    }

    /// push-service answers 403 when it couldn't check the token with Salla too: once it can again, the app's next
    /// `login` after the wait links the device with the same token.
    func test_aTokenRefusedDuringAnOutage_linksAfterTheWait_oncePushServiceChecksItAgain() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.customers = { token in .linked(FakeServer.defaultCustomer(of: token)) }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId, "held back during the wait")
        h.advance(300)
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, h.server.customer(of: "customer.token.a"))
        XCTAssertTrue(h.logs.contains("login.ok"))
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
    }

    /// A link that succeeds ends the wait: a later refusal of the same token, here of the link after a re-registration,
    /// is news to the app, so it is reported.
    func test_aSuccessfulLink_endsTheWait() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login("customer.token.a")
        h.advance(302)
        h.server.customers = { token in .linked(FakeServer.defaultCustomer(of: token)) }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, h.server.customer(of: "customer.token.a"))
        h.server.customers = { _ in .rejected }
        h.server.purge(h.deviceId)
        h.submit(.setLanguage("en"))
        h.advance(15)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertEqual(h.server.requests("link").count, 3)
        XCTAssertEqual(failures.failures.current, [.tokenRejected, .tokenRejected])
    }

    /// A login held back by the wait forgets its token again: a re-registration meanwhile does not send it.
    func test_aLoginHeldBackByTheWait_leavesNoTokenForTheLinkAfterAReRegistration() {
        let h = Harness()
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.server.purge(h.deviceId)
        h.submit(.setLanguage("en"))
        h.advance(15)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(h.logs.count("identity.token_needed"), 1)
    }

    /// A clock set back ends the wait instead of stretching it.
    func test_aClockSetBack_endsTheWait() {
        let h = Harness()
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.clock.set(h.clock.now() - 3_600)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2)
    }

    /// A `logout()` ends the wait: the next sign-in sends the token, and its refusal is reported.
    func test_aLogout_endsTheWait() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.logout()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(failures.failures.current, [.tokenRejected, .tokenRejected])
    }

    /// A login of another customer ends the wait: switching back before that login went sends the token again.
    func test_aLoginOfAnotherCustomer_endsTheWait() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.login(customer: "cust_b")
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").map { $0.json["external_id"] as? String }, ["cust_a", "cust_a"])
        XCTAssertEqual(failures.failures.current, [.tokenRejected, .tokenRejected])
    }

    /// A refusal of a login the app had already replaced is not reported, and leaves no wait behind: the app's next
    /// login with that token goes, and its refusal is reported.
    func test_aRefusalOfALoginTheAppReplaced_holdsNothingBack() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.logout()
        h.server.releaseHeld(FakeServer.error(403, "invalid_identity_token"))
        h.advance(5)
        XCTAssertTrue(failures.failures.current.isEmpty)
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
    }

    /// A login held back by the wait sends nothing, so it releases no failed request either: the update keeps its
    /// backoff.
    func test_aLoginHeldBackByTheWait_releasesNoFailedRequest() {
        let h = Harness()
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(1.5)
        h.advance(2.1)
        h.advance(4.1)
        XCTAssertEqual(h.server.requests("update").count, 3, "the next retry is 8 s after the third")
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(5)
        XCTAssertEqual(h.server.requests("update").count, 3, "the login released nothing")
        XCTAssertEqual(h.server.requests("link").count, 1)
    }
}

// MARK: - A refused account switch

/// An account switch relies on the new customer's link to replace the previous customer's. When push-service refuses
/// that link for good, SallaPush unlinks the device from the previous customer, whose notifications would otherwise
/// keep reaching it. The getters keep the customer the app logged in, and a link SallaPush can't name is left as it is.
extension RefusedLoginTests {
    /// The previous customer's tags go, the link is refused, then the unlink goes. The refusal is reported once, and
    /// the app's next `login` of the customer links the device.
    func test_aRefusedSwitch_unlinksThePreviousCustomer_andTheNextLoginLinksTheNewOne() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let before = h.server.requests.count
        h.login(externalId: "cust_b", token: "eyJ.expired")
        h.advance(3)
        XCTAssertEqual(h.server.requests.dropFirst(before).map(\.template), ["tags", "link", "unlink"])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.isLoggedIn)
        XCTAssertEqual(h.snapshot.externalId, "cust_b")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        XCTAssertEqual(h.logs.all.last { $0.code == "logout.queued" }?.message,
                       "The new customer's link was refused; the device is unlinked from the previous customer, whose "
                           + "notifications would otherwise keep reaching it.")
        h.login(customer: "cust_b")
        h.advance(2)
        XCTAssertEqual(h.server.requests.dropFirst(before).map(\.template), ["tags", "link", "unlink", "link"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A switch refused as invalid (`400`) unlinks the previous customer the same way.
    func test_aSwitchRefusedAsInvalid_unlinksThePreviousCustomer() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("link") { _ in FakeServer.error(400, "invalid_request") }
        h.login(customer: "cust_b")
        h.advance(3)
        XCTAssertEqual(h.server.templates.filter { $0 == "link" || $0 == "unlink" }, ["link", "link", "unlink"])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.snapshot.externalId, "cust_b")
        XCTAssertEqual(failures.failures.current, [.invalidRequest])
    }

    /// A refused switch the app already replaced with another customer's `login`: that login's link replaces the
    /// previous customer's, so no unlink goes.
    func test_aRefusedSwitchTheAppReplaced_sendsNoUnlink_andTheNextCustomerIsLinked() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("link") { _ in .hold }
        h.login(externalId: "cust_b", token: "eyJ.expired")
        h.advance(2)
        h.login(customer: "cust_c")
        h.server.releaseHeld()
        h.advance(3)
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
        XCTAssertEqual(h.server.requests("link").map { $0.json["external_id"] as? String },
                       ["cust_a", "cust_b", "cust_c"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_c")
        XCTAssertTrue(failures.failures.current.isEmpty)
    }

    /// After a reinstall SallaPush can't name the customer the device is linked to: a refused login leaves that link as
    /// it is.
    func test_aRefusedLoginAfterAReinstall_sendsNoUnlink() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        try? FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        let failures = FailureRecorder(next)
        next.initialize()
        next.login(externalId: "cust_a", token: "eyJ.expired")
        next.sendToken()
        next.advance(5)
        XCTAssertEqual(next.server.requests("link").count, 2)
        XCTAssertTrue(next.server.requests("unlink").isEmpty)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
    }

    /// A switch whose link may have reached push-service before it was refused: the unlink is confirmed 60 s
    /// after its answer, so a late link is removed too.
    func test_aRefusedSwitchWhoseLinkMayHaveApplied_isConfirmed() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.server.script("link", times: 1) { _ in FakeServer.error(403, "invalid_identity_token") }
        h.login(customer: "cust_b")
        h.advance(1.5)
        h.advance(5)
        XCTAssertEqual(h.server.requests("link").count, 3)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.server.mutate(h.deviceId) { $0.externalId = "cust_b" }
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the confirmation removes the late link")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// An app that signs the customer out when their token is refused sends one unlink: the `logout()` is covered by
    /// the unlink of the refused switch.
    func test_aLogoutFromTheFailureHandler_afterARefusedSwitch_sendsOneUnlink() {
        let h = Harness()
        let runtime = h.runtime
        let signingOut = runtime.observers.addLoginFailureHandler { [weak runtime] _ in runtime?.logout() }
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.login(externalId: "cust_b", token: "eyJ.expired")
        h.advance(5)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertTrue(h.logs.all.contains { entry in
            entry.code == "logout.queued" && entry.message.hasPrefix("Logout already queued")
        })
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertFalse(h.snapshot.isLoggedIn)
        XCTAssertTrue(h.identityOps().isEmpty)
        signingOut.cancel()
    }

    /// A switch refused during a consent withdrawal leaves the unlink to the withdrawal, whose requests count as done
    /// once consent is given again: no unlink goes then, also when the withdrawal's own was refused.
    func test_aSwitchRefusedDuringAConsentWithdrawal_leavesTheUnlinkToTheWithdrawal() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("link") { _ in .hold }
        h.login(externalId: "cust_b", token: "eyJ.expired")
        h.advance(2)
        h.runtime.setConsentGiven(false)
        h.advance(3)
        h.server.script("unlink") { _ in FakeServer.error(400, "invalid_request") }
        h.server.releaseHeld()
        h.advance(5)
        XCTAssertEqual(h.server.requests("unlink").count, 1, "the withdrawal's")
        h.runtime.setConsentGiven(true)
        h.advance(5)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertTrue(h.identityOps().isEmpty)
    }
}
