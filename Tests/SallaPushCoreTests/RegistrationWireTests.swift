import Foundation
@testable import SallaPushCore
import XCTest

/// The registration as push-service serves it, and the base URL its routes live under: `{base}/apps/...` and
/// `{base}/devices/...`, where the default base has a path (`/notifications/v1/sallapush`).
final class RegistrationWireTests: XCTestCase {
    private let transport = CapturingTransport()
    private lazy var production = APIClient(base: APIBase.production, transport: transport, clock: SystemClock())
    private let deviceId = "3f2a8c1e-0000-4000-8000-000000000001"

    /// A register answer's fields beyond the id and the secret, with what they are read as.
    private struct EarlierFields {
        let answer: [String: Any]
        let disabled: Bool
        let adopted: Bool
        let linked: Bool
    }

    private func json(_ object: [String: Any], status: Int = 200) -> HTTPResult {
        .response(status: status, headers: [:], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
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

    func test_register_withoutAPushToken_omitsIt() {
        transport.reply = json(["device_id": deviceId, "device_secret": "c2VjcmV0"], status: 201)
        _ = production.register(appId: "st_42_ios", body: registerBody(pushToken: nil)) { _ in }
        let sent = body(transport.requests.current.last)
        XCTAssertNil(sent["push_token"])
        XCTAssertEqual(sent["platform"] as? String, "ios")
        XCTAssertEqual(sent["apns_env"] as? String, "sandbox")
        XCTAssertEqual(sent["opted_in"] as? Bool, true)
    }

    /// `status`, `adopted` and `linked`, which push-service no longer answers, never make an answer invalid: a JSON
    /// string or boolean is read, anything else reads as absent (active, false, false).
    func test_register_earlierFields_areReadLeniently() {
        let cases = [
            EarlierFields(answer: ["status": "disabled", "adopted": true, "linked": true], disabled: true, adopted: true, linked: true),
            EarlierFields(answer: ["status": "active", "adopted": false, "linked": false], disabled: false, adopted: false, linked: false),
            EarlierFields(answer: ["status": "weird", "adopted": 1, "linked": "yes"], disabled: false, adopted: false, linked: false),
            EarlierFields(answer: ["status": 7, "adopted": NSNull()], disabled: false, adopted: false, linked: false),
        ]
        for fields in cases {
            var answer: [String: Any] = ["device_id": deviceId, "device_secret": "c2VjcmV0"]
            answer.merge(fields.answer) { _, new in new }
            transport.reply = json(answer, status: 201)
            let result = Locked<APIResult<RegisterResponse>?>(nil)
            _ = production.register(appId: "st_42_ios", body: registerBody()) { result.set($0) }
            guard case let .success(success)? = result.current else { return XCTFail("expected success for \(fields.answer)") }
            XCTAssertEqual(success.value.isDisabled, fields.disabled, "\(fields.answer)")
            XCTAssertEqual(success.value.adopted, fields.adopted, "\(fields.answer)")
            XCTAssertEqual(success.value.linked, fields.linked, "\(fields.answer)")
        }
    }

    /// push-service serves its routes under `/notifications/v1/sallapush`: every route goes under the default base's
    /// path, and a base given with a trailing slash builds the same URLs.
    func test_aBaseWithAPath_prefixesEveryRoute() throws {
        XCTAssertEqual(APIBase.defaultString, "https://api.salla.dev/notifications/v1/sallapush")
        XCTAssertEqual(APIBase.production.string, APIBase.defaultString)
        XCTAssertEqual(APIBase.production.origin, "https://api.salla.dev", "the host partitions stored state, not the path")
        let slashed = try XCTUnwrap(APIBase.validated(URL(string: "https://push.example.test/notifications/v1/sallapush//")))
        XCTAssertEqual(slashed.string, "https://push.example.test/notifications/v1/sallapush")
        let routes: [(Route, String)] = [
            (.register(appId: "st_42_ios"), "/apps/st_42_ios/devices"),
            (.update(deviceId: deviceId), "/devices/\(deviceId)"),
            (.tags(deviceId: deviceId), "/devices/\(deviceId)/tags"),
            (.events(deviceId: deviceId), "/devices/\(deviceId)/events"),
        ]
        for base in [APIBase.production, slashed] {
            for (route, path) in routes {
                XCTAssertEqual(base.url(for: route)?.absoluteString, base.string + path)
                XCTAssertEqual(base.url(for: route)?.path, "/notifications/v1/sallapush" + path)
            }
        }
        transport.reply = json(["tags": [String: String]()])
        _ = production.tags(deviceId: deviceId, secret: SecretString("c2VjcmV0"), body: TagsBody(add: [:], remove: ["a"])) { _ in }
        XCTAssertEqual(transport.requests.current.last?.url.absoluteString,
                       "https://api.salla.dev/notifications/v1/sallapush/devices/\(deviceId)/tags")
    }

    /// A base copied with a trailing `/v1` is the base without it, so no route gets a second version segment. Only one
    /// final segment that is exactly `v1` goes.
    func test_aBaseEndingInV1_isTheBaseWithoutIt() throws {
        let copied = "https://api.salla.dev/notifications/v1/sallapush/v1/"
        for text in [copied, "https://api.salla.dev/notifications/v1/sallapush/v1"] {
            let base = try XCTUnwrap(APIBase.validated(URL(string: text)), text)
            XCTAssertEqual(base, APIBase.production, text)
            XCTAssertEqual(base.url(for: .register(appId: "st_42_ios"))?.path,
                           "/notifications/v1/sallapush/apps/st_42_ios/devices", text)
        }
        let client = APIClient(base: try XCTUnwrap(APIBase.validated(URL(string: copied))), transport: transport,
                               clock: SystemClock())
        transport.reply = json(["device_id": deviceId, "device_secret": "c2VjcmV0"], status: 201)
        _ = client.register(appId: "st_42_ios", body: registerBody()) { _ in }
        XCTAssertEqual(transport.requests.current.last?.url.absoluteString,
                       "https://api.salla.dev/notifications/v1/sallapush/apps/st_42_ios/devices")
        let cases = [("http://localhost:8787/v1", "http://localhost:8787"),
                     ("https://push.example.test/v1/v1", "https://push.example.test/v1"),
                     ("https://push.example.test/api/v10", "https://push.example.test/api/v10"),
                     ("https://push.example.test/apiv1", "https://push.example.test/apiv1"),
                     ("https://push.example.test/V1", "https://push.example.test/V1"),
                     ("https://v1", "https://v1"), ("https://v1/", "https://v1")]
        for (text, expected) in cases {
            XCTAssertEqual(APIBase.validated(URL(string: text))?.string, expected, text)
        }
    }

    /// push-service's admin can generate a UUID v4 app id: it is a path segment like any slug.
    func test_register_aUUIDAppId() {
        let appId = "6f1c2b7e-3d4a-4c5b-9e8f-0a1b2c3d4e5f"
        transport.reply = json(["device_id": deviceId, "device_secret": "c2VjcmV0"], status: 201)
        let result = Locked<APIResult<RegisterResponse>?>(nil)
        _ = production.register(appId: appId, body: registerBody()) { result.set($0) }
        XCTAssertEqual(transport.requests.current.last?.url.absoluteString,
                       "https://api.salla.dev/notifications/v1/sallapush/apps/\(appId)/devices")
        guard case .success? = result.current else { return XCTFail("expected success") }
    }
}
