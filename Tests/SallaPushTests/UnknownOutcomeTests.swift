import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// Android's rule: once a request of a login op may have been
/// applied (it failed in transit, timed out, was cancelled, or got an unreadable 2xx), that sticks across later
/// answered errors; an answered error that applied nothing (5xx, 429, 3xx, 4xx) restores `sent` to its value before that
/// request. A dropped or superseded login that may have applied makes the next logout unlink and be confirmed 60 s
/// later; one that never could have makes no request at all.
final class UnknownOutcomeTests: XCTestCase {
    private func identityOp(_ h: Harness) -> [String: Any] {
        h.identityOps().first ?? [:]
    }

    /// The same rule as the Android SDK.
    func test_unknownOutcomeLogin_answeredWithA503OnItsRetry_thenReplaced_logoutIsStillConfirmed() {
        let h = Harness()
        h.registered()
        let attempts = Locked(0)
        h.server.script("link", times: nil) { _ in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            return attempt == 1 ? .failure(.timeout) : FakeServer.error(503, "server_error")
        }
        h.login("customer.token.a")
        h.advance(1.5)
        h.reachability.restoreAll()
        h.advance(3)
        XCTAssertGreaterThanOrEqual(attempts.current, 2)
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, true, "a 503 on the retry does not undo the timeout")
        let loginCalls = h.server.requests("link").count
        // The 503 answered only the retry: the first request may still reach the server. Another account replaces the
        // login and the app signs out, so the logout unlinks and is confirmed 60 s later.
        h.server.clearScripts()
        h.runtime.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        h.runtime.logout()
        h.settle()
        h.advance(5)
        XCTAssertEqual(h.server.requests("link").count, loginCalls)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// The link times out (the server applies it late), its retry is answered 503, then logout().
    /// The logout unlinks and is confirmed, so the late link is removed.
    func test_timedOutLogin_retryAnswered503_thenLogout_isConfirmed_andTheLateLinkIsRemoved() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.server.script("link", times: 1) { _ in FakeServer.error(503, "server_error") }
        h.login("customer.token.a")
        h.advance(1.5)
        h.advance(5)
        XCTAssertEqual(h.server.requests("link").count, 2)
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertFalse(h.logs.contains("logout.skipped"))
        h.server.mutate(h.deviceId) { $0.externalId = "cust_late" }
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the confirmation removes the late link")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.server.requests("link").count, 2, "the signed-out login is never sent again")
    }

    /// The reverse case: a login answered 503 applied nothing, so the next logout() of a device the server reports
    /// unlinked sends nothing, as on the Android SDK.
    func test_loginAnswered503_thenLogout_sendsNothing() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.login("customer.token.a")
        h.advance(1.5)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, false, "an answered 503 applied nothing")
        h.logout()
        h.advance(120)
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
        XCTAssertTrue(h.logs.contains("logout.skipped"))
        XCTAssertEqual(h.server.requests("link").count, 1, "the logout removed the login")
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// The same rule as the Android SDK.
    func test_aLogoutAnsweredWithAnError_isNoLongerSent_aTransportFailureKeepsItSent() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.server.script("unlink", times: 1) { _ in FakeServer.error(503, "server_error") }
        h.logout()
        h.advance(1.5)
        XCTAssertEqual(identityOp(h)["kind"] as? String, "logout")
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, false)
        h.server.script("unlink", times: 1) { _ in .failure(.network("offline")) }
        h.advance(3)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, true, "no answer: the request may have been applied")
    }

    /// A 2xx whose body cannot be read was applied by the server: the link may have linked the device.
    func test_loginAnsweredWithAnUnreadable2xx_thenReplacedAndLoggedOut_isConfirmed() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .raw(200, Data("<html>captive</html>".utf8), [:]) }
        h.login("customer.token.a")
        h.advance(1.5)
        XCTAssertTrue(h.logs.contains("net.invalid_response"))
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, true)
        h.runtime.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        h.runtime.logout()
        h.settle()
        h.advance(5)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
    }

    /// A login whose first request timed out is on the wire again when the app logs out; that retry is answered 503.
    /// The superseded login is not retried, and the first request may still apply: the logout is confirmed.
    func test_retryOnTheWireAnswered503_afterATimeout_supersededByALogout_isConfirmed() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(1.5)
        h.advance(5)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.server.releaseHeld(FakeServer.error(503, "server_error"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        h.advance(60)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertEqual(h.server.requests("link").count, 2, "the superseded login is not retried")
    }

    /// As in Android's `Identity.kt`, the logout is sent and one logout_confirm is scheduled 60 s later: the
    /// confirmation goes 60 s after the logout is answered, not 60 s after `logout()` was called. Here the logout first
    /// waits out a 429 of 120 s; the confirmation still waits its minute.
    func test_logoutConfirm_goes60sAfterTheLogoutIsAnswered_evenWhenTheLogoutWaited() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(1.5)
        h.server.script("unlink", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "120"]) }
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1, "answered 429")
        XCTAssertFalse(h.identityOps().contains { $0["kind"] as? String == "logout_confirm" }, "nothing to confirm yet")
        h.advance(120)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "the logout, sent again after its wait")
        XCTAssertEqual(h.identityOps().map { $0["kind"] as? String }, ["logout_confirm"])
        h.advance(55)
        XCTAssertEqual(h.server.requests("unlink").count, 2, "no confirmation within the minute after the answer")
        h.advance(10)
        XCTAssertEqual(h.server.requests("unlink").count, 3, "one confirmation, 60 s after the logout was answered")
        h.advance(600)
        XCTAssertEqual(h.server.requests("unlink").count, 3)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// The everyday case: the phone is offline when the app signs out. The logout goes once the network is back, and its
    /// confirmation 60 s after that answer.
    func test_logoutConfirm_afterAnOfflineLogout_goes60sAfterTheLogoutIsAnswered() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in .failure(.timeout) }
        h.login("customer.token.a")
        h.advance(1.5)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(90)
        let offline = h.server.requests("unlink").count
        XCTAssertGreaterThanOrEqual(offline, 2)
        h.server.clearScripts()
        h.reachability.restoreAll()
        h.advance(3)
        XCTAssertEqual(h.server.requests("unlink").count, offline + 1, "sent once the network is back")
        h.advance(55)
        XCTAssertEqual(h.server.requests("unlink").count, offline + 1, "the confirmation waits its minute")
        h.advance(10)
        XCTAssertEqual(h.server.requests("unlink").count, offline + 2)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A logout answered 429 (applied nothing) is restored to unsent, and a repeated logout() still keeps its wait and
    /// adds no request: the covering rule looks at the op before unsent ops go (as on Android).
    func test_logoutAnswered429_isUnsent_andARepeatedLogoutKeepsItsWait() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "60"]) }
        h.logout()
        h.advance(2)
        XCTAssertEqual(identityOp(h)["sent"] as? Bool, false)
        h.logout()
        h.advance(50)
        XCTAssertEqual(h.server.requests("unlink").count, 1, "the 429 wait is kept")
        XCTAssertEqual(h.identityOps().count, 1)
        h.advance(15)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }
}
