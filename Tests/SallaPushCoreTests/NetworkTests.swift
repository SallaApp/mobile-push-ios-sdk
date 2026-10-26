import Foundation
@testable import SallaPushCore
import XCTest

/// Records requests and answers with a scripted result, synchronously.
final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    let requests = Locked<[HTTPRequest]>([])
    var reply: HTTPResult = .response(status: 200, headers: [:], body: Data("{}".utf8))
    private let invalidated = Locked(false)

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) -> HTTPTaskHandle? {
        if invalidated.current { return nil }
        requests.withLock { $0.append(request) }
        completion(reply)
        return Handle()
    }

    func invalidate() {
        invalidated.set(true)
    }

    private struct Handle: HTTPTaskHandle {
        func cancel() {}
    }
}

final class APIClientTests: XCTestCase {
    private let transport = CapturingTransport()
    /// A base without a path, so a request's path is its route's; `production` has the default base, path included.
    private lazy var client = APIClient(base: Self.pathlessBase, transport: transport, clock: SystemClock())
    private lazy var production = APIClient(base: APIBase.production, transport: transport, clock: SystemClock())
    private static let pathlessBase = APIBase.validated(URL(string: "https://push.example.test")) ?? APIBase.production
    private let deviceId = "3f2a8c1e-0000-4000-8000-000000000001"
    private let secret = SecretString("c2VjcmV0")
    private let emptyUpdate = UpdateBody(pushToken: nil, apnsEnv: nil, optedIn: nil, metadata: nil)

    private func json(_ object: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> HTTPResult {
        .response(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func body(_ request: HTTPRequest?) -> [String: Any] {
        guard let data = request?.body else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func registerBody(pushToken: String? = "ab") -> RegisterBody {
        RegisterBody(pushToken: pushToken, apnsEnv: "sandbox", optedIn: true,
                     metadata: DeviceMetadata(appVersion: "5.0.38", sdkVersion: "1.2.0-beta.1", osVersion: "18.0.0",
                                              deviceModel: "iPhone15,2", language: "ar", timezone: nil))
    }

    /// The registration as push-service serves it: the device fields and nothing else, answered
    /// `201 {device_id, device_secret}`.
    func test_register_buildsTheContractRequest() {
        transport.reply = json(["device_id": deviceId.uppercased(), "device_secret": "c2VjcmV0"], status: 201,
                               headers: ["x-request-id": "req-1"])
        let result = Locked<APIResult<RegisterResponse>?>(nil)
        _ = production.register(appId: "st_42_ios", body: registerBody()) { result.set($0) }
        let request = transport.requests.current.first
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.salla.dev/notifications/v1/sallapush/apps/st_42_ios/devices")
        XCTAssertNil(request?.headers["Authorization"])
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
        let sent = body(request)
        XCTAssertEqual(Set(sent.keys), ["platform", "push_token", "apns_env", "opted_in", "app_version", "sdk_version",
                                        "os_version", "device_model", "language"], "no installation_id, previous_device_id or bundle_id")
        XCTAssertEqual(sent["platform"] as? String, "ios")
        XCTAssertEqual(sent["push_token"] as? String, "ab")
        XCTAssertEqual(sent["opted_in"] as? Bool, true)
        XCTAssertNil(sent["timezone"])
        guard case let .success(success)? = result.current else { return XCTFail("expected success") }
        XCTAssertEqual(success.value.deviceId, deviceId)
        XCTAssertEqual(success.value.deviceSecret, SecretString("c2VjcmV0"))
        XCTAssertFalse(success.value.isDisabled, "no status: active")
        XCTAssertFalse(success.value.adopted)
        XCTAssertFalse(success.value.linked)
        XCTAssertEqual(success.requestId, "req-1")
    }

    /// Only the device id (a UUID) and the secret (base64url) are required.
    func test_register_invalidBodies_areInvalidResponses() {
        let invalid: [[String: Any]] = [
            ["device_id": "nope", "device_secret": "c2VjcmV0"],
            ["device_id": deviceId, "device_secret": ""],
            ["device_id": deviceId, "device_secret": "not base64url!"],
            ["device_id": deviceId],
            ["device_secret": "c2VjcmV0"],
            [:],
        ]
        for object in invalid {
            transport.reply = json(object, status: 201)
            let result = Locked<APIResult<RegisterResponse>?>(nil)
            _ = client.register(appId: "st_42_ios", body: registerBody()) { result.set($0) }
            guard case let .failure(error)? = result.current else { return XCTFail("expected failure for \(object)") }
            XCTAssertEqual(error.kind, .invalidResponse)
            XCTAssertTrue(error.isTransient)
        }
    }

    func test_htmlBody_on200_isInvalid_andNon2xxHTML_isNonJSON() {
        transport.reply = .response(status: 200, headers: [:], body: Data("<html>captive</html>".utf8))
        let result = Locked<APIResult<UpdateResponse>?>(nil)
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .invalidResponse)

        transport.reply = .response(status: 502, headers: [:], body: Data("<html>bad gateway</html>".utf8))
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .failure(html)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(html.kind, .nonJSON)
        XCTAssertNil(html.code)
        XCTAssertTrue(html.isTransient)
    }

    /// An answer nested 10,000 levels deep is never parsed (`JSONSerialization` recursion would
    /// overflow the engine queue's 512 KB stack), on a 2xx or an error status, and is retried like any unreadable
    /// answer. Run on a 512 KB thread, the engine queue's stack size.
    func test_deeplyNestedAnswers_areNeverParsed_onASmallStack() throws {
        let deep = Data(("{\"error\":" + String(repeating: "{\"a\":", count: 10_000) + "1"
                         + String(repeating: "}", count: 10_000) + "}").utf8)
        let deepArray = Data((String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)).utf8)
        let hidden = Self.utf16HidingItsBrackets(levels: 10_000)
        let results = Locked<[APIError]>([])
        let done = expectation(description: "interpreted")
        let thread = Thread {
            let decode: ([String: Any]?) -> UpdateResponse? = { $0.map { _ in UpdateResponse(linked: nil) } }
            for (status, body) in [(200, deep), (503, deep), (201, deepArray), (400, deepArray), (200, hidden), (503, hidden)] {
                let result = APIClient.interpret(.response(status: status, headers: [:], body: body),
                                                 route: .update(deviceId: "x"), now: 0, decode: decode)
                if case let .failure(error) = result { results.withLock { $0.append(error) } }
            }
            done.fulfill()
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        wait(for: [done], timeout: 30)
        let errors = results.current
        XCTAssertEqual(errors.map(\.kind), [.invalidResponse, .nonJSON, .invalidResponse, .nonJSON, .invalidResponse, .nonJSON])
        XCTAssertEqual(errors.map(\.detail), Array(repeating: "nested deeper than 32 levels", count: 4)
                       + Array(repeating: "not UTF-8 text", count: 2))
        XCTAssertTrue(errors.allSatisfy(\.isTransient))
        XCTAssertTrue(errors.allSatisfy { $0.code == nil }, "a rejected body is never read for an error code")
        XCTAssertEqual(errors[1].summary, "503 answer not read (nested deeper than 32 levels)")
        XCTAssertEqual(errors[0].summary, "unexpected body (200, nested deeper than 32 levels)")
    }

    /// UTF-16 JSON, which `JSONSerialization` detects and reads, whose bytes hide its nesting from a byte scan: the
    /// last character of a string ends in a backslash byte (0x5C), so its closing quote looks escaped. Before the scan
    /// refused NUL bytes, a few thousand levels of it overflowed a 512 KB stack.
    static func utf16HidingItsBrackets(levels: Int) -> Data {
        let text = "{\"a\":\"\u{5C41}\",\"b\":" + String(repeating: "{\"a\":", count: levels) + "1"
            + String(repeating: "}", count: levels) + "}"
        return text.data(using: .utf16LittleEndian) ?? Data()
    }

    /// An answer larger than the cap is never parsed; one at the cap is.
    func test_answersLargerThanTheCap_areNeverParsed() throws {
        var padding = String(repeating: "x", count: APIClient.maximumAnswerBytes)
        let oversized = Data(("{\"linked\":true,\"pad\":\"" + padding + "\"}").utf8)
        transport.reply = .response(status: 200, headers: [:], body: oversized)
        let result = Locked<APIResult<UpdateResponse>?>(nil)
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .invalidResponse)
        XCTAssertEqual(error.detail, "larger than 256 KB")
        padding = String(repeating: "x", count: APIClient.maximumAnswerBytes - 40)
        transport.reply = .response(status: 200, headers: [:], body: Data(("{\"linked\":true,\"pad\":\"" + padding + "\"}").utf8))
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .success(success)? = result.current else { return XCTFail("expected success") }
        XCTAssertEqual(success.value.linked, true)
    }

    /// Brackets inside strings, escaped quotes included, are not nesting.
    func test_depthScan_ignoresBracketsInStrings() {
        let tricky = Data(#"{"a":"[[[[{{{{\"]]]]","b":[{"c":"\\"}]}"#.utf8)
        XCTAssertTrue(DepthLimit.jsonFits(tricky, maxDepth: 3))
        XCTAssertFalse(DepthLimit.jsonFits(tricky, maxDepth: 2))
        XCTAssertTrue(DepthLimit.jsonFits(Data(), maxDepth: 0))
        XCTAssertFalse(DepthLimit.jsonFits(Data("[[1]]".utf8), maxDepth: 1))
        // Text in another encoding never fits, however shallow it looks to the byte scan.
        XCTAssertFalse(DepthLimit.jsonFits(Self.utf16HidingItsBrackets(levels: 100), maxDepth: 32))
        XCTAssertFalse(DepthLimit.jsonFits(#"{"a":1}"#.data(using: .utf16BigEndian) ?? Data([0]), maxDepth: 32))
        XCTAssertTrue(DepthLimit.jsonFits(Data("{\"a\":\"\u{5C41}\\\"\"}".utf8), maxDepth: 1), "UTF-8 needs no such rule")
    }

    func test_errorEnvelope_isParsed_andCleaned() {
        transport.reply = json(["error": ["code": "device_disabled", "message": "Device\nis disabled", "reason": "dead_token"]],
                               status: 401, headers: ["x-request-id": "abc\u{0}123", "retry-after": "30"])
        let result = Locked<APIResult<UpdateResponse>?>(nil)
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.status, 401)
        XCTAssertEqual(error.code, "device_disabled")
        XCTAssertEqual(error.reason, "dead_token")
        XCTAssertEqual(error.message, "Device is disabled")
        XCTAssertEqual(error.requestId, "abc123")
        XCTAssertEqual(error.retryAfter, 30)
        XCTAssertFalse(error.isTransient)
        XCTAssertEqual(transport.requests.current.first?.headers["Authorization"], "Device c2VjcmV0")
    }

    func test_redirect_isAFailure() {
        transport.reply = .response(status: 302, headers: ["location": "https://evil.example"], body: Data())
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .redirect)
        XCTAssertTrue(error.isTransient)
    }

    /// push-service answers an update with `200 {}`: nothing is required, and a `linked` that is no JSON boolean reads
    /// as absent.
    func test_update_anyObjectIsASuccess() {
        let result = Locked<APIResult<UpdateResponse>?>(nil)
        transport.reply = json([:])
        let optOut = UpdateBody(pushToken: nil, apnsEnv: nil, optedIn: false, metadata: nil)
        _ = production.update(deviceId: deviceId, secret: secret, body: optOut) { result.set($0) }
        guard case let .success(empty)? = result.current else { return XCTFail("expected success") }
        XCTAssertNil(empty.value.linked)
        let request = transport.requests.current.last
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(request?.url.absoluteString, "https://api.salla.dev/notifications/v1/sallapush/devices/\(deviceId)")
        XCTAssertEqual(body(request) as NSDictionary, ["opted_in": false] as NSDictionary)
        let answers: [([String: Any], Bool?)] = [(["linked": "yes"], nil), (["linked": 1], nil), (["linked": true], true)]
        for (answer, linked) in answers {
            transport.reply = json(answer)
            _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
            guard case let .success(success)? = result.current else { return XCTFail("expected success for \(answer)") }
            XCTAssertEqual(success.value.linked, linked, "\(answer)")
        }
        transport.reply = .response(status: 200, headers: [:], body: Data("[]".utf8))
        _ = client.update(deviceId: deviceId, secret: secret, body: emptyUpdate) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("a body that is no JSON object is invalid") }
        XCTAssertEqual(error.kind, .invalidResponse)
    }

    /// The link carries the external id and the identity token (revealed only in the body), waits longer than the
    /// other routes for Salla's platform, and its `200 {}` must be a JSON object.
    func test_link_sendsTheExternalIdAndTheToken_andValidatesTheEmptyAnswer() {
        transport.reply = json([:])
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        _ = client.link(deviceId: deviceId, secret: secret,
                        body: LinkBody(externalId: "1001", identityToken: SecretString("eyJ.token.value"))) { result.set($0) }
        let request = transport.requests.current.last
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.path, "/devices/\(deviceId)/link")
        XCTAssertEqual(request?.timeout, APIClient.linkTimeout)
        XCTAssertEqual(request?.headers["Authorization"], "Device c2VjcmV0")
        XCTAssertEqual(body(request) as NSDictionary,
                       ["external_id": "1001", "identity_token": "eyJ.token.value"] as NSDictionary)
        guard case .success? = result.current else { return XCTFail("expected success") }
        XCTAssertFalse(String(describing: LinkBody(externalId: "1001", identityToken: SecretString("eyJ.token.value")))
            .contains("eyJ.token.value"), "the token never prints")
        transport.reply = .response(status: 200, headers: [:], body: Data("[]".utf8))
        _ = client.link(deviceId: deviceId, secret: secret,
                        body: LinkBody(externalId: "1001", identityToken: SecretString("t"))) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .invalidResponse)
    }

    /// `403 invalid_identity_token` is a client error with its code, which the engine reports.
    func test_link_rejectedToken_isAClientError() {
        transport.reply = json(["error": ["code": "invalid_identity_token", "message": "Identity token verification failed"]],
                               status: 403)
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        _ = client.link(deviceId: deviceId, secret: secret,
                        body: LinkBody(externalId: "1001", identityToken: SecretString("eyJ.expired"))) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.status, 403)
        XCTAssertEqual(error.code, "invalid_identity_token")
        XCTAssertTrue(error.isClientError)
        XCTAssertFalse(error.mayHaveApplied)
    }

    func test_tagsAndEvents_shapes() {
        transport.reply = json(["tags": ["a": "1"]])
        let tags = Locked<APIResult<TagsResponse>?>(nil)
        _ = client.tags(deviceId: deviceId, secret: secret, body: TagsBody(add: ["a": "1"], remove: [])) { tags.set($0) }
        XCTAssertEqual(transport.requests.current.last?.method, "PATCH")
        XCTAssertEqual(transport.requests.current.last?.timeout, 20)
        XCTAssertEqual(body(transport.requests.current.last) as NSDictionary, ["add": ["a": "1"]] as NSDictionary)
        guard case let .success(tagsSuccess)? = tags.current else { return XCTFail("expected success") }
        XCTAssertEqual(tagsSuccess.value.tags, ["a": "1"])

        transport.reply = json([:], status: 202)
        let events = Locked<APIResult<EventsResponse>?>(nil)
        _ = client.events(deviceId: deviceId, secret: secret,
                          body: EventsBody(events: [EventItem(type: "opened", notificationId: "msg_ab",
                                                              at: "2026-09-21T14:13:20.123Z")])) { events.set($0) }
        XCTAssertEqual(transport.requests.current.last?.timeout, 20, "the engine's events keep 20 s")
        let sent = body(transport.requests.current.last)
        XCTAssertEqual(sent as NSDictionary,
                       ["events": [["type": "opened", "notification_id": "msg_ab", "at": "2026-09-21T14:13:20.123Z"]]] as NSDictionary)
        guard case let .success(eventsSuccess)? = events.current else { return XCTFail("expected success: 202 {}") }
        XCTAssertEqual(eventsSuccess.value, EventsResponse(accepted: 0, ignored: 0))
        transport.reply = json(["accepted": 2, "ignored": 1], status: 202)
        _ = client.events(deviceId: deviceId, secret: secret, body: EventsBody(events: [])) { events.set($0) }
        guard case let .success(counted)? = events.current else { return XCTFail("expected success") }
        XCTAssertEqual(counted.value, EventsResponse(accepted: 2, ignored: 1), "counts are read when an answer has them")
    }

    /// An events call takes the timeout it is given, below or above the default: a caller passes the time it has left.
    func test_events_takeTheirOwnTimeout() {
        transport.reply = json([:], status: 202)
        let result = Locked<APIResult<EventsResponse>?>(nil)
        for seconds in [6.0, 30.0] {
            _ = client.events(deviceId: deviceId, secret: secret, body: EventsBody(events: []), timeout: seconds) { result.set($0) }
            XCTAssertEqual(transport.requests.current.last?.timeout, seconds)
            guard case .success? = result.current else { return XCTFail("expected success") }
        }
        XCTAssertEqual(transport.requests.current.last?.url.path, "/devices/\(deviceId)/events")
    }

    /// An unlink sends `{}` (push-service reads no body), and its `200 {}` must be a JSON object.
    func test_unlink_sendsAnEmptyObject_andValidatesTheEmptyAnswer() {
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        transport.reply = json([:])
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        let request = transport.requests.current.last
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.path, "/devices/\(deviceId)/unlink")
        XCTAssertEqual(request?.headers["Authorization"], "Device c2VjcmV0")
        XCTAssertEqual(request?.timeout, APIClient.requestTimeout)
        XCTAssertEqual(request.flatMap { String(data: $0.body ?? Data(), encoding: .utf8) }, "{}")
        guard case .success? = result.current else { return XCTFail("expected success") }
        transport.reply = .response(status: 200, headers: [:], body: Data("[]".utf8))
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .invalidResponse)
    }

    func test_transportFailures() {
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        transport.reply = .failure(.timeout)
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(timeout)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(timeout.kind, .timeout)
        XCTAssertTrue(timeout.outcomeUnknown)
        transport.reply = .failure(.network("offline"))
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(network)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(network.kind, .network)
    }

    func test_invalidatedTransport_startsNothing() {
        transport.invalidate()
        let called = Locked(false)
        let handle = client.unlink(deviceId: deviceId, secret: secret) { _ in called.set(true) }
        XCTAssertNil(handle)
        XCTAssertFalse(called.current)
    }

    func test_rateLimit_andRetryAfterDate() {
        transport.reply = json(["error": ["code": "rate_limited", "message": "Too many requests"]], status: 429,
                               headers: ["retry-after": "Mon, 21 Sep 2026 14:15:20 GMT"])
        let fixed = APIClient(base: APIBase.production, transport: transport, clock: FixedClock(now: 1_790_000_000))
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        _ = fixed.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(error.retryAfter, 120)
    }

    // MARK: - Error answers: the envelope, its message, and what a failure may have applied

    /// A JSON 4xx without the error envelope's code (Cloudflare's RFC 9457 bodies) is none of push-service's answers.
    func test_aJSON4xxWithoutACode_isNoClientError_andIsRetried() {
        transport.reply = json(["type": "https://developers.cloudflare.com/support/", "title": "Error 1020: Access denied",
                                "status": 403, "cloudflare_error": true], status: 403)
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .http)
        XCTAssertNil(error.code)
        XCTAssertFalse(error.isClientError)
        XCTAssertTrue(error.isTransient)
        XCTAssertFalse(error.mayHaveApplied)
        XCTAssertEqual(error.summary, "403")
    }

    /// As on Android, a code must be 1-64 characters for the body to be an envelope.
    func test_anEmptyOrOverlongCode_isNoEnvelope() {
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        for (code, expected) in [("", nil), (String(repeating: "x", count: 65), nil),
                                 (String(repeating: "x", count: 64), String(repeating: "x", count: 64))] {
            transport.reply = json(["error": ["code": code, "message": "m"]], status: 409)
            _ = client.unlink(deviceId: deviceId, secret: secret) { result.set($0) }
            guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
            XCTAssertEqual(error.code, expected)
            XCTAssertEqual(error.isClientError, expected != nil)
        }
    }

    /// The envelope's message is outside text: what the request carried and token-like runs never reach a log line.
    func test_theEnvelopeMessage_hidesWhatTheRequestCarried_andTokenLikeRuns() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAxIn0.c2lnbmF0dXJlc2lnbmF0dXJl"
        transport.reply = json(["error": ["code": "invalid_request",
                                          "message": "echo Device c2VjcmV0 for identity.token.long and \(jwt)"]], status: 400)
        let result = Locked<APIResult<EmptyResponse>?>(nil)
        let body = LinkBody(externalId: "1001", identityToken: SecretString("identity.token.long"))
        _ = client.link(deviceId: deviceId, secret: secret, body: body) { result.set($0) }
        guard case let .failure(error)? = result.current else { return XCTFail("expected failure") }
        XCTAssertEqual(error.message, "echo Device <redacted> for <redacted> and <redacted>")
        XCTAssertEqual(error.summary, "400 invalid_request: \"echo Device <redacted> for <redacted> and <redacted>\"")
    }

    func test_summary_showsServerText_onlyForAClientError() {
        let route = Route.update(deviceId: deviceId)
        func summary(_ status: Int, _ code: String?) -> String {
            APIError(kind: .http, route: route, status: status, code: code, message: "echo", requestId: "r1").summary
        }
        XCTAssertEqual(summary(400, "invalid_request"), "400 invalid_request: \"echo\", request r1")
        XCTAssertEqual(summary(503, "server_error"), "503 server_error, request r1")
        XCTAssertEqual(summary(429, "rate_limited"), "429 rate_limited, request r1")
        XCTAssertEqual(summary(403, nil), "403, request r1")
    }

    /// As Android's `mayHaveApplied`: only a failure without a usable answer may have changed the server.
    func test_mayHaveApplied_onlyWithoutAUsableAnswer() {
        let route = Route.link(deviceId: deviceId)
        for kind in [APIError.Kind.network, .timeout, .cancelled, .invalidResponse] {
            XCTAssertTrue(APIError(kind: kind, route: route, status: kind == .invalidResponse ? 200 : nil).mayHaveApplied)
        }
        for kind in [APIError.Kind.http, .nonJSON, .redirect] {
            XCTAssertFalse(APIError(kind: kind, route: route, status: 503).mayHaveApplied)
        }
    }
}

private struct FixedClock: Clock {
    let value: Double

    init(now: Double) {
        value = now
    }

    func now() -> Double { value }
}

/// Answers every request from a table, so the real `URLSession` stack runs without a network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.sallapush.test" || request.url?.host == "evil.sallapush.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let stub = Self.stubs[request.url?.path ?? ""]
        Self.lock.unlock()
        guard let url = request.url, let stub,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if (300..<400).contains(stub.status), let location = stub.headers["Location"], let next = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.lock.lock()
        StubURLProtocol.stubs = [:]
        StubURLProtocol.seen = []
        StubURLProtocol.lock.unlock()
    }

    private func send(_ path: String, transport: URLSessionTransport) throws -> HTTPResult {
        let url = try XCTUnwrap(URL(string: "https://stub.sallapush.test" + path))
        let request = HTTPRequest(method: "POST", url: url, headers: ["Authorization": "Device c2VjcmV0"],
                                  body: Data("{}".utf8), timeout: 5, route: .unlink(deviceId: "x"))
        let result = Locked<HTTPResult?>(nil)
        let done = expectation(description: "answer")
        let handle = transport.send(request) { answer in
            result.set(answer)
            done.fulfill()
        }
        XCTAssertNotNil(handle)
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result.current)
    }

    func test_answer_onTheEngineQueue_withLowercasedHeaders() throws {
        StubURLProtocol.stubs["/ok"] = .init(status: 200, headers: ["X-Request-Id": "r-9"], body: Data(#"{"a":1}"#.utf8))
        let queue = DispatchQueue(label: "test.engine")
        let transport = URLSessionTransport(queue: queue, userAgent: "SallaPush-iOS/test", protocolClasses: [StubURLProtocol.self])
        guard case let .response(status, headers, body) = try send("/ok", transport: transport) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers["x-request-id"], "r-9")
        XCTAssertEqual(body, Data(#"{"a":1}"#.utf8))
        transport.invalidate()
    }

    func test_redirect_isNeverFollowed() throws {
        StubURLProtocol.stubs["/moved"] = .init(status: 302, headers: ["Location": "https://evil.sallapush.test/steal"], body: Data())
        StubURLProtocol.stubs["/steal"] = .init(status: 200, headers: [:], body: Data("{}".utf8))
        let transport = URLSessionTransport(queue: DispatchQueue(label: "test.redirect"), userAgent: "SallaPush-iOS/test",
                                            protocolClasses: [StubURLProtocol.self])
        guard case let .response(status, _, _) = try send("/moved", transport: transport) else {
            return XCTFail("expected the redirect response")
        }
        XCTAssertEqual(status, 302)
        StubURLProtocol.lock.lock()
        let hosts = StubURLProtocol.seen.compactMap(\.url?.host)
        StubURLProtocol.lock.unlock()
        XCTAssertEqual(hosts, ["stub.sallapush.test"])
        transport.invalidate()
    }

    /// The live transport stops reading an answer one byte past the cap and cancels the download,
    /// so no body of unbounded size is ever buffered; the API client then rejects it.
    func test_oversizedAnswer_isCutOneBytePastTheCap() throws {
        StubURLProtocol.stubs["/huge"] = .init(status: 200, headers: [:], body: Data(repeating: 0x7B, count: 1_000_000))
        let transport = URLSessionTransport(queue: DispatchQueue(label: "test.huge"), userAgent: "SallaPush-iOS/test",
                                            protocolClasses: [StubURLProtocol.self], maximumBodyBytes: 1_000)
        guard case let .response(status, _, body) = try send("/huge", transport: transport) else {
            return XCTFail("expected the cut answer")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body.count, 1_001)
        transport.invalidate()
        let defaults = URLSessionTransport(queue: DispatchQueue(label: "test.default"), userAgent: "SallaPush-iOS/test",
                                           protocolClasses: [StubURLProtocol.self])
        StubURLProtocol.stubs["/big"] = .init(status: 503, headers: [:], body: Data(repeating: 0x20, count: 1_048_576))
        guard case let .response(bigStatus, _, bigBody) = try send("/big", transport: defaults) else {
            return XCTFail("expected the cut answer")
        }
        XCTAssertEqual(bigStatus, 503)
        XCTAssertEqual(bigBody.count, APIClient.maximumAnswerBytes + 1)
        defaults.invalidate()
        // Out-of-range caps never trap: Int.max keeps everything, a negative cap keeps one byte.
        for (cap, kept) in [(Int.max, 1_000_000), (-5, 1)] {
            let extreme = URLSessionTransport(queue: DispatchQueue(label: "test.cap.\(cap)"), userAgent: "SallaPush-iOS/test",
                                              protocolClasses: [StubURLProtocol.self], maximumBodyBytes: cap)
            guard case let .response(_, _, extremeBody) = try send("/huge", transport: extreme) else {
                return XCTFail("expected an answer for cap \(cap)")
            }
            XCTAssertEqual(extremeBody.count, kept)
            extreme.invalidate()
        }
    }

    func test_invalidatedTransport_createsNoTask() throws {
        let transport = URLSessionTransport(queue: DispatchQueue(label: "test.invalid"), userAgent: "SallaPush-iOS/test",
                                            protocolClasses: [StubURLProtocol.self])
        transport.invalidate()
        transport.invalidate()
        let url = try XCTUnwrap(URL(string: "https://stub.sallapush.test/ok"))
        let request = HTTPRequest(method: "POST", url: url, headers: [:], body: nil, timeout: 5, route: .unlink(deviceId: "x"))
        XCTAssertNil(transport.send(request) { _ in XCTFail("no completion expected") })
    }

    func test_userAgent() {
        let agent = URLSessionTransport.userAgent(sdkVersion: "1.2.0-beta.1", osVersion: "18.0.0", model: "iPhone15,2")
        XCTAssertTrue(agent.hasPrefix("SallaPush-iOS/1.2.0-beta.1 ("))
        XCTAssertTrue(agent.hasSuffix("18.0.0; iPhone15,2)"))
    }
}
