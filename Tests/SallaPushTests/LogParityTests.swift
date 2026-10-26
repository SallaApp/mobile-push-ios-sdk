import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// Log parity with Android. Failure entries carry the app id and `net.rate_limited`
/// the attempt; a failure's console line names its request id; refusals decided locally cite no HTTP answer; a corrupt
/// `events.json` is reported.
final class LogParityTests: XCTestCase {
    func test_failureEntries_carryTheAppId_andRateLimitedTheAttempt() throws {
        let h = Harness()
        h.registered()
        h.server.script("update", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "60"]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        let limited = try XCTUnwrap(h.logs.all.first { $0.code == "net.rate_limited" })
        XCTAssertEqual(limited.metadata["attempt"], "1")
        XCTAssertEqual(limited.metadata["delay_s"], "60")
        XCTAssertEqual(limited.metadata["app_id"], "st_42_ios")
        h.advance(61)
        h.server.script("update", times: 1) { _ in FakeServer.error(503, "server_error") }
        h.server.script("update", times: 1) { _ in FakeServer.error(400, "invalid_request") }
        h.submit(.setLanguage("fr"))
        h.advance(10)
        XCTAssertTrue(h.logs.contains("net.retry"))
        XCTAssertTrue(h.logs.contains("net.client_error"))
        let failures = h.logs.all.filter { $0.metadata["http_status"] != nil }
        XCTAssertGreaterThanOrEqual(failures.count, 3)
        for entry in failures {
            XCTAssertEqual(entry.metadata["app_id"], "st_42_ios", entry.code)
        }
    }

    func test_failureConsoleLines_nameTheRequestId_andTheStatusAndCodeTheMessageLacks() throws {
        let h = Harness()
        h.registered()
        h.server.script("link", times: 1) { _ in
            FakeServer.error(403, "invalid_identity_token", headers: ["x-request-id": "req-abc"])
        }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.logs.console.first { $0.contains("login.rejected") },
                       "[SallaPush] WARN login.rejected: The identity token was rejected (403 invalid_identity_token); this "
                           + "device is not linked to the customer. Call login(externalId:identityToken:) with a fresh token. "
                           + "[request req-abc]")
        h.server.script("update", times: 1) { _ in
            FakeServer.error(429, "rate_limited", headers: ["retry-after": "60", "x-request-id": "req-def"])
        }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.logs.console.first { $0.contains("net.rate_limited") },
                       "[SallaPush] WARN net.rate_limited: Rate limited (429); retry in 60 s. [rate_limited, request req-def]")
        let entry = try XCTUnwrap(h.logs.all.first { $0.code == "login.rejected" })
        XCTAssertFalse(entry.message.contains("req-abc"), "the handler's message stays as is; the id is in its metadata")
        XCTAssertEqual(entry.metadata["request_id"], "req-abc")
    }

    /// A login refused on the caller thread cites no answer of the push service.
    func test_localRefusals_citeNoAnswerOfThisCall() throws {
        let h = Harness()
        h.registered()
        h.login(externalId: "", token: "eyJ.x")
        h.login(externalId: "cust_a", token: "")
        let refusals = h.logs.all.filter { $0.code == "api.invalid_argument" }
        XCTAssertEqual(refusals.map(\.message), ["login ignored: the external id must be 1-128 characters.",
                                                  "login ignored: the identity token must be 1-4096 characters."])
        XCTAssertTrue(refusals.allSatisfy { $0.metadata.isEmpty })
        XCTAssertTrue(h.server.requests("link").isEmpty)
    }

    func test_corruptEventsFile_isSetAside_andReportedAsAStateReset() throws {
        let h = Harness()
        h.registered()
        let folder = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)")
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("events.json"))
        let next = h.relaunch()
        next.initialize()
        let reset = try XCTUnwrap(next.logs.all.first { $0.code == "storage.state_reset" })
        XCTAssertEqual(reset.level, .error)
        XCTAssertEqual(reset.message, "SallaPush pending events were corrupt; they were reset (the events were dropped).")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("events.corrupt.json").path))
    }
}
