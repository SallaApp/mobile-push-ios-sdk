import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The answers of push-service are matched on the error code as well as the
/// status. A JSON 4xx without an error code, such as a Cloudflare block (error 1020 is an HTTP 403, and with
/// `Accept: application/json` it is RFC 9457 JSON without an `error` member), is no answer of the push service: it is
/// retried with backoff and loses nothing, as on Android.
final class AnswerClassificationTests: XCTestCase {
    /// A JSON error an edge writes, without the push service's `error` envelope.
    static func edgeError(_ status: Int) -> FakeServer.Reply {
        .json(status, ["type": "https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/",
                       "title": "Error 1020: Access denied", "status": status, "error_code": 1020,
                       "ray_id": "9f140b785e57c458", "cloudflare_error": true],
              ["content-type": "application/problem+json"])
    }

    // MARK: - Link

    func test_codelessJSON403OnLink_isRetried_andLinks_withoutRejectingTheToken() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link", times: 1) { _ in Self.edgeError(403) }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertFalse(h.logs.contains("login.rejected"))
        XCTAssertTrue(h.logs.contains("net.retry"))
        h.advance(10)
        XCTAssertEqual(h.server.requests("link").count, 2, "the same token is sent again after the backoff")
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertNotNil(h.snapshot.externalId)
        XCTAssertTrue(failures.failures.current.isEmpty)
    }

    func test_codelessJSON400OnLink_isRetried_andLinks_withoutReportingAnInvalidRequest() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link", times: 1) { _ in .json(400, ["message": "Bad Request"], [:]) }
        h.login("customer.token.a")
        h.advance(12)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertTrue(failures.failures.current.isEmpty, "no .invalidRequest for an answer without a code")
    }

    /// Only `400` and `403 invalid_identity_token` are final. Another code is a client error: 24 h, then the link goes
    /// again.
    func test_another409Code_onLink_isAClientError_retriedAfter24h() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link", times: 1) { _ in FakeServer.error(409, "subscription_conflict") }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertTrue(h.logs.contains("identity.client_error"))
        XCTAssertTrue(failures.failures.current.isEmpty)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("link").count, 1)
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId)
    }

    /// Only `invalid_identity_token` rejects the token; another 403 code is a client error.
    func test_another403Code_onLink_isAClientError_neverRejectsTheToken() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link", times: 1) { _ in FakeServer.error(403, "forbidden") }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertTrue(h.logs.contains("identity.client_error"))
        XCTAssertFalse(h.logs.contains("login.rejected"))
        XCTAssertTrue(failures.failures.current.isEmpty)
    }

    func test_theContractsCodes_stillDecide() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link", times: 1) { _ in FakeServer.error(403, "invalid_identity_token") }
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("link", times: 1) { _ in FakeServer.error(400, "invalid_request") }
        h.login("customer.token.b")
        h.advance(2)
        XCTAssertEqual(failures.failures.current, [.tokenRejected, .invalidRequest])
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    // MARK: - Register

    func test_codelessJSON404OnRegister_isRetried_neverDormant() {
        let h = Harness()
        h.initialize()
        h.server.script("register", times: 1) { _ in Self.edgeError(404) }
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertFalse(h.logs.contains("register.dormant"))
        h.advance(10)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertNotNil(h.deviceId)
        XCTAssertEqual((h.file("state.json")["registration"] as? [String: Any])?["status"] as? String, "registered")
    }

    func test_codelessJSON400OnRegister_isRetried_neverDormant() {
        let h = Harness()
        h.initialize()
        h.server.script("register", times: 1) { _ in .json(400, ["message": "Bad Request"], [:]) }
        h.sendToken()
        h.advance(12)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertFalse(h.logs.contains("net.client_error"))
        XCTAssertNotNil(h.deviceId)
    }

    /// An enveloped 4xx with a code the contract does not list (here 422, or 404 with another code) is dormant 24 h with
    /// `invalid_request`, as on Android; `unknown_app` keeps its own reason.
    func test_otherClientErrorsOnRegister_areDormant24h_asInvalidRequest() {
        for reply in [FakeServer.error(422, "unprocessable"), FakeServer.error(404, "no_such_route")] {
            let h = Harness()
            h.initialize()
            h.server.script("register", times: 1) { _ in reply }
            h.sendToken()
            h.advance(2)
            let registration = h.file("state.json")["registration"] as? [String: Any]
            XCTAssertEqual(registration?["dormant_reason"] as? String, "invalid_request")
            XCTAssertTrue(h.logs.contains("net.client_error"))
            h.advance(3_600)
            XCTAssertEqual(h.server.requests("register").count, 1)
            h.advance(86_400)
            XCTAssertEqual(h.server.requests("register").count, 2)
        }
        let unknown = Harness()
        unknown.initialize()
        unknown.server.script("register", times: 1) { _ in FakeServer.error(404, "unknown_app") }
        unknown.sendToken()
        unknown.advance(2)
        let registration = unknown.file("state.json")["registration"] as? [String: Any]
        XCTAssertEqual(registration?["dormant_reason"] as? String, "unknown_app")
        XCTAssertTrue(unknown.logs.contains("register.dormant"))
    }

    // MARK: - Tags and events

    func test_codelessJSON400OnTags_isRetried_andNoTagIsDropped() {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: 1) { _ in Self.edgeError(400) }
        h.submit(.addTags(["a": "1", "b": "2", "c": "3"]))
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertFalse(h.logs.contains("tags.rejected_key"))
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").count, 2)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1", "b": "2", "c": "3"])
        XCTAssertEqual(h.snapshot.tags, ["a": "1", "b": "2", "c": "3"])
    }

    /// An enveloped 422 is a client error like Android's: the tags wait 24 h and are all kept; only a coded 400 starts
    /// the per-key rejection.
    func test_enveloped422OnTags_waits24h_andKeepsEveryTag() {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: 1) { _ in FakeServer.error(422, "unprocessable") }
        h.submit(.addTags(["a": "1", "b": "2"]))
        h.advance(11)
        XCTAssertTrue(h.logs.contains("net.client_error"))
        XCTAssertFalse(h.logs.contains("tags.rejected_key"))
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("tags").count, 2)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1", "b": "2"])
    }

    func test_codelessJSON400OnEvents_isRetried_andTheBatchIsKept() {
        let h = Harness()
        h.registered()
        h.server.script("events", times: 1) { _ in Self.edgeError(400) }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(30)
        let batches = h.server.requests("events").map { request in
            ((request.json["events"] as? [[String: Any]]) ?? []).compactMap { $0["notification_id"] as? String }
        }
        XCTAssertEqual(batches, [["msg_ab"], ["msg_ab"]], "the same event, sent again after the backoff")
        XCTAssertFalse(h.logs.contains("net.client_error"))
        XCTAssertTrue(h.logs.contains("events.flushed"))
    }

    /// push-service's `500 server_error` is transient: the batch is kept and sent again after the backoff.
    func test_serverErrorOnEvents_isRetried_andTheBatchIsKept() {
        let h = Harness()
        h.registered()
        h.server.script("events", times: 1) { _ in FakeServer.error(500, "server_error") }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(30)
        XCTAssertEqual(h.server.requests("events").count, 2)
        XCTAssertTrue(h.logs.contains("net.retry"))
        XCTAssertFalse(h.logs.contains("net.client_error"))
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
    }

    /// Any enveloped client error drops the batch, as on Android; the next events still go.
    func test_envelopedClientErrorOnEvents_dropsTheBatch() throws {
        let h = Harness()
        h.registered()
        h.server.script("events", times: 1) { _ in FakeServer.error(409, "conflict") }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        h.advance(60)
        XCTAssertEqual(h.server.requests("events").count, 1)
        let dropped = try XCTUnwrap(h.logs.all.first { $0.code == "net.client_error" })
        XCTAssertTrue(dropped.message.hasSuffix("1 event was dropped."), dropped.message)
        h.submit(.events([EventRecord(messageId: "msg_cd", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        XCTAssertEqual(h.server.requests("events").count, 2)
    }
}
