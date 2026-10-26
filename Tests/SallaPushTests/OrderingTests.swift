import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class OrderingTests: XCTestCase {
    func test_logoutDuringLoginInFlight_sentAfter() {
        let h = Harness()
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.advance(2)
        XCTAssertTrue(h.server.requests("unlink").isEmpty, "the logout waits behind the login in flight")
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertEqual(h.server.templates.suffix(2), ["link", "unlink"])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }

    /// The answer of a link that was in flight when logout() came never shows the customer again.
    func test_logoutDuringLoginInFlight_externalIdStaysNil() throws {
        let h = Harness()
        let seen = Locked<[String?]>([])
        let observation = h.runtime.observers.addUserHandler { change in seen.withLock { $0.append(change.current.externalId) } }
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.server.releaseHeld()
        h.settle()
        XCTAssertNil(h.snapshot.externalId, "not the signed-out customer's id")
        h.advance(2)
        XCTAssertEqual(h.server.templates.suffix(2), ["link", "unlink"])
        XCTAssertFalse(h.snapshot.isLoggedIn)
        XCTAssertNil(h.snapshot.externalId)
        XCTAssertTrue(h.file("identity.json")["desired_external_id"] is NSNull)
        XCTAssertEqual(seen.current, [h.server.customer(of: "customer.token.a"), nil],
                       "the id at the login, nil from the logout on")
        observation.cancel()
    }

    func test_twoLogouts_oneRequest() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.logout()
        h.logout()
        h.advance(2)
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
    }

    func test_unsentLoginLogoutLogin_collapses() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.logout()
        h.login("customer.token.b")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").map { $0.json["identity_token"] as? String }, ["customer.token.b"])
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
    }

    func test_unknownOutcomeLogin_thenLogout_sendsConfirmAfter60s() {
        let h = Harness()
        h.registered()
        h.server.script("link") { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(1.5)
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.advance(30)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.advance(40)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "one confirming logout 60 s later")
        h.advance(600)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertEqual(h.server.requests("link").count, 1, "the superseded login is never retried")
    }

    /// Going to the background flushes debounced work, never the 60 s `logout_confirm`.
    func test_backgroundFlush_keepsTheLogoutConfirmAt60s() {
        let h = Harness()
        h.registered()
        h.server.script("link") { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(2)
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.send(.didEnterBackground)
        h.advance(30)
        XCTAssertEqual(h.server.requests("unlink").count, 1, "the confirmation keeps its 60 s")
        h.advance(35)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
    }

    // MARK: - Collapse rules: a repeated call keeps the queued op and its waits

    /// A login answered `429 Retry-After 60`, then `login(same)` 2 s later: no login before the 60 s.
    func test_repeatedLogin_sameToken_keepsThe429Wait() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "60"]) }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 1)
        h.login("customer.token.a")
        h.advance(50)
        XCTAssertEqual(h.server.requests("link").count, 1, "a trigger never shortens a 429 wait")
        XCTAssertTrue(h.logs.all.contains { $0.code == "login.queued" && $0.message.hasPrefix("Login already queued") })
        h.advance(15)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertNotNil(h.snapshot.externalId)
    }

    /// A link answered with a client error other than `400` and `403 invalid_identity_token` sleeps 24 h
    /// (`identity.client_error`); `login(same)` keeps that wait.
    func test_repeatedLogin_sameToken_keepsThe24hClientErrorWait() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in FakeServer.error(409, "conflict") }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertTrue(h.logs.contains("identity.client_error"))
        h.login("customer.token.a")
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("link").count, 1)
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("link").count, 2, "retried after the day")
    }

    /// `login(same)` while the first link is on the wire sends nothing more.
    func test_sameLoginWhileTheFirstIsInFlight_sendsOneLogin() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.login("customer.token.a")
        h.server.releaseHeld()
        h.advance(30)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertNotNil(h.snapshot.externalId)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A logout answered `429 Retry-After 60`, then `logout()` again: that logout keeps its wait, and the two
    /// calls cost one request.
    func test_repeatedLogout_keepsThe429Wait_andAddsNoRequest() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "60"]) }
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.logout()
        h.advance(50)
        XCTAssertEqual(h.server.requests("unlink").count, 1, "a trigger never shortens a 429 wait")
        XCTAssertEqual(h.identityOps().count, 1, "the attempted logout stays; nothing is added")
        XCTAssertTrue(h.logs.all.contains { $0.code == "logout.queued" && $0.message.hasPrefix("Logout already queued") })
        h.advance(15)
        h.advance(120)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the same logout, sent again after its wait")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A new login removes only never-sent logins: a sent logout ahead of it keeps its place, so the logout still goes
    /// first and the login after it.
    func test_loginAfterAnAttemptedLogout_staysBehindIt() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "60"]) }
        h.logout()
        h.advance(2)
        h.login("customer.token.b")
        h.advance(30)
        XCTAssertEqual(h.server.requests("link").count, 1, "the login waits behind the logout")
        h.advance(40)
        XCTAssertEqual(h.server.templates.suffix(2), ["unlink", "link"])
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId)
    }

    // MARK: - Triggers: an identity call releases failed requests only when it changes the identity or queues a request

    /// During a 503 outage, a `login` of the customer the device is linked to sends nothing and releases nothing: the
    /// update keeps its backoff. A login of another customer, and a sign-out, change the identity, so each releases it.
    func test_aLoginOfTheLinkedCustomer_releasesNoFailedRequest_whileASwitchAndASignOutDo() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(1.5)
        h.advance(2.1)
        h.advance(4.1)
        XCTAssertEqual(h.server.requests("update").count, 3, "the next retry is 8 s after the third")
        h.login(customer: "cust_a")
        XCTAssertEqual(h.logs.count("login.skipped_same"), 1)
        h.advance(5)
        XCTAssertEqual(h.server.requests("update").count, 3, "the login released nothing")
        h.login(customer: "cust_b")
        h.advance(1)
        XCTAssertEqual(h.server.requests("update").count, 4, "a login of another customer is a trigger")
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 5, "so is a sign-out")
    }

    /// During a 503 outage, a `login` of the customer whose link waits its retry adds no request: the link and the
    /// update keep their backoff.
    func test_aRepeatedLogin_whileItsLinkWaitsItsRetry_releasesNoFailedRequestEarly() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.login(customer: "cust_a")
        h.submit(.setLanguage("en"))
        h.advance(7.5)
        XCTAssertEqual(h.server.requests("link").count, 3)
        XCTAssertEqual(h.server.requests("update").count, 3)
        h.login(customer: "cust_a")
        XCTAssertTrue(h.logs.all.contains { $0.code == "login.queued" && $0.message.hasPrefix("Login already queued") })
        h.advance(7)
        XCTAssertEqual(h.server.requests("link").count, 3, "the link keeps its 8 s backoff")
        XCTAssertEqual(h.server.requests("update").count, 3, "and so does the update")
        h.advance(1)
        XCTAssertEqual(h.server.requests("link").count, 4)
        XCTAssertEqual(h.server.requests("update").count, 4)
    }

    /// A repeated `logout()` while the first one's unlink has used up its attempts in a 503 outage adds no request and
    /// releases nothing: the unlink waits for the next trigger, here a foreground.
    func test_aRepeatedLogout_afterTheUnlinkRanOutOfAttempts_sendsNoUnlinkUntilAForeground() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.logout()
        h.advance(200)
        XCTAssertEqual(h.server.requests("unlink").count, 6)
        XCTAssertTrue(h.logs.contains("net.retry_exhausted"))
        h.logout()
        XCTAssertEqual(h.logs.all.last { $0.code == "logout.queued" }?.message,
                       "Logout already queued; it is retried until the server answers it.")
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("unlink").count, 6, "a repeated logout() is no trigger")
        h.send(.willEnterForeground)
        h.advance(3)
        XCTAssertEqual(h.server.requests("unlink").count, 7, "a foreground is")
        XCTAssertEqual(h.identityOps().count, 1, "the unlink is kept until the server answers it")
    }

    /// A guest's `logout()` that queues a request, here the unlink of a link SallaPush doesn't know, is a trigger: the
    /// update waiting its backoff goes before its retry time.
    func test_aGuestsLogout_thatQueuesAnUnlink_releasesFailedRequests() throws {
        let h = Harness()
        h.registered()
        h.logout()
        let next = h.relaunch()
        let url = next.root.appendingPathComponent("st_42_ios/\(next.hostTag)/identity.json")
        var identity = next.file("identity.json")
        XCTAssertEqual(identity["desired"] as? String, "guest")
        identity["server_link"] = "unknown"
        try JSONSerialization.data(withJSONObject: identity).write(to: url)
        next.initialize()
        next.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        next.submit(.setLanguage("en"))
        next.advance(1.5)
        next.advance(2.1)
        next.advance(4.1)
        XCTAssertEqual(next.server.requests("update").count, 3, "the next retry is 8 s after the third")
        next.logout()
        next.advance(2)
        XCTAssertEqual(next.server.requests("unlink").count, 1)
        XCTAssertEqual(next.server.requests("update").count, 4, "the logout queued an unlink, so it is a trigger")
    }

    // MARK: - An unknown-outcome login is not forgotten when another login replaces it

    /// A link times out but the server links the device late; the app calls `login(same)` again, then
    /// `logout()`. The logout unlinks and is confirmed 60 s later.
    func test_unknownOutcomeLogin_sameLoginAgain_thenLogout_unlinksAndConfirms() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(1.5)
        XCTAssertEqual(h.server.requests("link").count, 1)
        h.server.mutate(h.deviceId) { $0.externalId = "cust_late" }
        h.runtime.login(externalId: h.server.customer(of: "customer.token.a"), identityToken: "customer.token.a")
        h.runtime.logout()
        h.settle()
        h.advance(120)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the logout and its confirmation")
        XCTAssertFalse(h.logs.contains("logout.skipped"))
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }

    /// The same with another customer's login, which replaces the timed-out one before the logout.
    func test_unknownOutcomeLogin_replacedByAnotherLogin_thenLogout_unlinksAndConfirms() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(1.5)
        h.server.mutate(h.deviceId) { $0.externalId = "cust_late" }
        h.runtime.login(externalId: "cust_a2", identityToken: FakeServer.token(for: "cust_a2"))
        h.runtime.logout()
        h.settle()
        h.advance(30)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertEqual(h.server.requests("link").count, 1, "the replaced login is never sent again")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        // The login may still be processed late: the confirmation 60 s after the logout covers it.
        h.server.mutate(h.deviceId) { $0.externalId = "cust_later" }
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        h.advance(600)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "one confirmation only")
    }

    /// The link still on the wire: the app logs in another customer, then the first link fails in transit. It is
    /// superseded, so it is not retried (and no "token needed" warning); the next logout still unlinks and is confirmed.
    func test_loginOnTheWire_supersededByAnotherLogin_failsInTransit_isDropped_andTheNextLogoutConfirms() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.login("customer.token.b")
        h.server.releaseHeld(.failure(.network("timed out")))
        h.advance(30)
        XCTAssertEqual(h.server.requests("link").map { $0.json["identity_token"] as? String },
                       ["customer.token.a", "customer.token.b"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertFalse(h.logs.contains("identity.token_needed"))
        XCTAssertFalse(h.logs.contains("net.retry"), "a superseded link is not retried")
        h.logout()
        h.advance(120)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the unlink and its confirmation")
    }

    /// The login on the wire is superseded by a logout and a login again, then fails in transit. The confirming
    /// logout goes right after the logout, before the new login, so it never signs out the customer who logged in again.
    func test_loginOnTheWire_thenLogoutAndLoginAgain_failsInTransit_theConfirmationNeverUndoesTheNewLogin() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        h.logout()
        h.login("customer.token.b")
        h.server.releaseHeld(.failure(.network("timed out")))
        h.advance(130)
        XCTAssertEqual(h.server.templates.suffix(4), ["link", "unlink", "unlink", "link"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.snapshot.externalId, "cust_b")
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A link superseded by a logout and then answered with a client error never holds the logout back for the 24 h
    /// client-error wait; the server rejected it, so the device is known to be unlinked: no unlink, no confirmation.
    func test_loginOnTheWire_supersededByALogout_clientError_neverHoldsTheLogoutBack() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        h.logout()
        h.server.releaseHeld(FakeServer.error(409, "conflict"))
        h.advance(3)
        XCTAssertFalse(h.logs.contains("identity.client_error"))
        h.advance(120)
        XCTAssertTrue(h.server.requests("unlink").isEmpty, "the server rejected the link")
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    func test_loginAfterFailedLogout_retriesLogoutImmediately() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: 3) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(2)
        h.advance(3)
        h.advance(5)
        let failed = h.server.requests("unlink").count
        XCTAssertGreaterThanOrEqual(failed, 2)
        h.login("customer.token.b")
        h.advance(2.5)
        XCTAssertGreaterThan(h.server.requests("unlink").count, failed, "the trigger made the logout ready at once")
        XCTAssertEqual(h.server.templates.last, "link")
    }

    func test_tagsHeldWhileAnyIdentityOpIsPending() {
        let h = Harness()
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login("customer.token.a")
        h.submit(.addTags(["a": "1"]))
        h.advance(30)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").count, 1)
    }

    func test_foregroundAfterLogout_sendsNoLogin() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.logout()
        h.advance(2)
        h.sendToken()
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.advance(86_400)
        h.send(.willEnterForeground)
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 1)
    }

    /// A link left from the previous launch without its token is dropped at once, so update and events go.
    func test_updateAndEvents_go_whenALinkHasNoToken() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        h.login("customer.token.a")
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.submit(.setLanguage("en"))
        next.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: next.clock.now(), actionId: nil)]))
        next.advance(6)
        XCTAssertEqual(next.server.requests("update").count, 1)
        XCTAssertEqual(next.server.requests("events").count, 1)
        XCTAssertTrue(next.identityOps().isEmpty, "no token: the pending link is removed")
    }
}
