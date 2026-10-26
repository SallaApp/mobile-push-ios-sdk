import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class RetryTests: XCTestCase {
    private func updateCount(_ h: Harness) -> Int {
        h.server.requests("update").count
    }

    /// A final answer is not re-posted at every foreground: `404 unknown_app` is dormant 24 h, then retried.
    func test_unknownApp_dormant24h() {
        let h = Harness()
        h.server.script("register") { _ in FakeServer.error(404, "unknown_app") }
        h.registered()
        XCTAssertEqual(h.logs.count("register.dormant"), 1)
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("register").count, 1)
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertNotNil(h.deviceId)
    }

    func test_429_waitsForRetryAfterSeconds_andTriggersDoNotShortenIt() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "120"]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(updateCount(h), 1)
        XCTAssertTrue(h.logs.contains("net.rate_limited"))
        h.advance(30)
        h.send(.willEnterForeground)
        h.advance(30)
        XCTAssertEqual(updateCount(h), 1)
        h.advance(65)
        XCTAssertEqual(updateCount(h), 2)
    }

    func test_429_withHTTPDate() {
        let h = Harness()
        h.registered()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date(timeIntervalSince1970: h.clock.now() + 1 + 300))
        h.server.script("update") { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": date]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(250)
        XCTAssertEqual(updateCount(h), 1)
        h.advance(60)
        XCTAssertEqual(updateCount(h), 2)
    }

    func test_5xx_backsOff_exponentially_withinBounds() throws {
        // Jitter is pinned to its upper bound, so the delays are exactly 2, 4 and 8 s.
        let h = Harness()
        h.registered()
        h.server.script("update", times: 3) { _ in FakeServer.error(503, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(1.5)
        XCTAssertEqual(updateCount(h), 1, "sent after the 1 s debounce")
        h.advance(1.4)
        XCTAssertEqual(updateCount(h), 1)
        h.advance(0.2)
        XCTAssertEqual(updateCount(h), 2, "first retry 2 s later")
        h.advance(3.8)
        XCTAssertEqual(updateCount(h), 2)
        h.advance(0.2)
        XCTAssertEqual(updateCount(h), 3, "second retry 4 s later")
        let ops = h.file("state.json")["ops"] as? [[String: Any]] ?? []
        XCTAssertEqual(ops.first?["attempts"] as? Int, 3, "attempts are persisted")
        XCTAssertEqual(ops.first?["last_failure"] as? String, "server")
        h.advance(8)
        XCTAssertEqual(updateCount(h), 4, "third retry 8 s later succeeds")
        XCTAssertTrue((h.file("state.json")["ops"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue(h.logs.contains("net.retry"))
    }

    func test_503RetryAfter_isHonoured() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(503, "schema_not_ready", headers: ["retry-after": "30"]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(25)
        XCTAssertEqual(updateCount(h), 1)
        h.advance(6)
        XCTAssertEqual(updateCount(h), 2)
    }

    func test_nonJSON502_isRetried() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in .raw(502, Data("<html><body>Bad gateway</body></html>".utf8), [:]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(3)
        XCTAssertEqual(updateCount(h), 2)
    }

    func test_connectivityRestored_retriesAtOnce_andStopsTheMonitor() {
        let h = Harness()
        h.registered()
        h.server.script("update", times: 4) { _ in .failure(.network("offline")) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(2.1)
        h.advance(4.1)
        h.advance(8.1)
        XCTAssertEqual(updateCount(h), 4)
        XCTAssertEqual(h.reachability.activeCount, 1, "the monitor runs only after a network failure")
        h.reachability.restoreAll()
        h.settle()
        h.advance(2.1)
        XCTAssertEqual(updateCount(h), 5, "connectivity made the update ready again")
        XCTAssertEqual(h.reachability.activeCount, 0)
    }

    func test_noMonitor_withoutNetworkFailures() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(503, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(10)
        XCTAssertEqual(h.reachability.monitors.current.count, 0)
    }

    func test_redirect_isNotFollowed_andLoggedOnce() {
        let h = Harness()
        h.registered()
        h.server.script("update", times: 2) { _ in .raw(302, Data(), ["location": "https://evil.example/steal"]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(3)
        XCTAssertEqual(h.logs.count("net.redirect_refused"), 1)
        XCTAssertTrue(h.server.requests.allSatisfy { $0.host == "api.salla.dev" })
        h.advance(10)
        XCTAssertEqual(h.server.requests("update").count, 3)
    }

    func test_retryExhausted_afterSixAttempts_waitsForATrigger() {
        let h = Harness()
        h.registered()
        h.server.script("update", times: nil) { _ in FakeServer.error(500, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.advance(200)
        XCTAssertEqual(updateCount(h), 6)
        XCTAssertTrue(h.logs.contains("net.retry_exhausted"))
        h.advance(86_000)
        XCTAssertEqual(updateCount(h), 6, "no timer retries after six attempts in a process")
        h.send(.willEnterForeground)
        h.advance(3)
        XCTAssertEqual(updateCount(h), 7, "a trigger allows another attempt")
    }

    func test_invalid2xxBody_isRetried() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in .raw(200, Data("<html>captive portal</html>".utf8), [:]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertTrue(h.logs.contains("net.invalid_response"))
        h.advance(3)
        XCTAssertEqual(updateCount(h), 2)
    }

    /// Answers nested 10,000 levels deep, or 1 MB large, to a registration, a login and events, handled on the
    /// engine queue (a GCD thread with a 512 KB stack): nothing crashes, `net.invalid_response` says why, and each op
    /// backs off and then succeeds.
    func test_hostileAnswers_onTheEngineQueue_neverCrash_andAreRetried() throws {
        let deep = Data(("{\"error\":" + String(repeating: "{\"a\":", count: 10_000) + "1"
                         + String(repeating: "}", count: 10_000) + "}").utf8)
        let huge = Data(repeating: 0x20, count: 1_048_576)
        let h = Harness()
        h.server.script("register", times: 1) { _ in .raw(201, deep, [:]) }
        h.server.script("register", times: 1) { _ in .raw(503, huge, [:]) }
        h.registered()
        XCTAssertEqual(h.server.requests("register").count, 1)
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 2, "retried after 2 s")
        XCTAssertNil(h.deviceId)
        h.advance(5)
        XCTAssertEqual(h.server.requests("register").count, 3, "then 4 s")
        XCTAssertNotNil(h.deviceId)
        let invalid = h.logs.all.filter { $0.code == "net.invalid_response" }.map(\.message)
        XCTAssertEqual(invalid, [
            "POST /apps/{app_id}/devices returned an unexpected body (nested deeper than 32 levels); will retry.",
            "POST /apps/{app_id}/devices returned an answer SallaPush does not read (larger than 256 KB); will retry.",
        ])
        h.server.script("link", times: 1) { _ in .raw(200, deep, [:]) }
        h.login("customer.token.a")
        h.advance(2)
        h.advance(3)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertNotNil(h.snapshot.externalId)
        h.server.script("events", times: 1) { _ in .raw(202, huge, [:]) }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        h.advance(3)
        XCTAssertEqual(h.server.requests("events").count, 2)
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
        XCTAssertEqual(h.logs.count("net.invalid_response"), 4)
    }

    func test_clientError_onUpdate_isDormantForADay() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(400, "invalid_request") }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertTrue(h.logs.contains("net.client_error"))
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(updateCount(h), 1)
        h.advance(86_400)
        XCTAssertEqual(updateCount(h), 2)
    }

    func test_identityClientError_isNeverDropped_retriedAfterADay() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink") { _ in FakeServer.error(400, "invalid_request") }
        h.logout()
        h.advance(2)
        XCTAssertTrue(h.logs.contains("identity.client_error"))
        XCTAssertEqual(h.identityOps().count, 1)
        h.advance(86_401)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertTrue(h.identityOps().isEmpty)
    }
}
