import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class RegistrationTests: XCTestCase {
    func test_firstToken_sendsOneRegisterWithEveryField() throws {
        let h = Harness()
        h.initialize()
        XCTAssertTrue(h.server.requests.isEmpty, "nothing is sent without a token")
        h.sendToken()
        h.advance(2)
        let registers = h.server.requests("register")
        XCTAssertEqual(registers.count, 1)
        let body = try XCTUnwrap(registers.first?.json)
        XCTAssertEqual(registers.first?.host, "api.salla.dev")
        XCTAssertEqual(registers.first?.path, "/apps/st_42_ios/devices")
        XCTAssertNil(registers.first?.headers["authorization"])
        XCTAssertEqual(Set(body.keys), ["platform", "push_token", "apns_env", "opted_in", "app_version", "sdk_version",
                                        "os_version", "device_model", "language", "timezone"],
                       "the fields push-service stores, and no installation_id, previous_device_id or bundle_id")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["push_token"] as? String, Harness.tokenHex())
        XCTAssertEqual(body["apns_env"] as? String, "sandbox")
        XCTAssertEqual(body["opted_in"] as? Bool, true)
        XCTAssertEqual(body["app_version"] as? String, "5.0.38")
        XCTAssertEqual(body["sdk_version"] as? String, "1.1.0")
        XCTAssertEqual(body["os_version"] as? String, "18.0.0")
        XCTAssertEqual(body["device_model"] as? String, "iPhone15,2")
        XCTAssertEqual(body["language"] as? String, "ar")
        XCTAssertEqual(body["timezone"] as? String, "Asia/Riyadh")
        XCTAssertNotNil(h.deviceId)
        XCTAssertTrue(h.logs.contains("register.ok"))
    }

    /// push-service knows a device by its row alone: SallaPush keeps no installation id, and the credentials of the
    /// (app id, API host) are the only Keychain item it writes, never on a read path.
    func test_registration_writesOnlyTheCredentials_toTheKeychain() throws {
        let h = Harness()
        h.initialize()
        h.logout()
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        _ = h.snapshot
        XCTAssertTrue(h.keychainAccess.allValues.isEmpty)
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.keychainAccess.allValues.count, 1)
        let stored = try XCTUnwrap(h.keychainAccess.value(account: "device_credentials.st_42_ios.\(h.hostTag)"))
        let credentials = try XCTUnwrap(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(credentials["device_id"] as? String, h.deviceId)
        XCTAssertEqual(credentials["api_host"] as? String, "https://api.salla.dev")
    }

    func test_secondLaunch_reusesCredentials_sendsNoRegister() {
        let h = Harness()
        h.registered()
        let next = h.relaunch()
        next.initialize()
        next.sendToken()
        next.advance(2)
        XCTAssertEqual(next.server.requests("register").count, 1)
        XCTAssertEqual(next.deviceId, h.deviceId)
    }

    func test_twoTokenDeliveries_oneRegister() {
        let h = Harness()
        h.initialize()
        h.sendToken()
        h.sendToken()
        h.advance(2)
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    /// A purged device (`404 unknown_device`) registers again with the fields of any registration: push-service takes no
    /// `previous_device_id` or `installation_id`. The new device gets the tags.
    func test_reRegistration_sendsTheFieldsOfAFirstRegistration() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.purge(deviceId)
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        let registers = h.server.requests("register")
        XCTAssertEqual(registers.count, 2)
        let first = try XCTUnwrap(registers.first?.json)
        let again = try XCTUnwrap(registers.last?.json)
        XCTAssertEqual(Set(again.keys), Set(first.keys))
        XCTAssertNil(again["previous_device_id"])
        XCTAssertNil(again["installation_id"])
        XCTAssertTrue(h.logs.contains("register.reregistering"))
        h.advance(15)
        let newId = try XCTUnwrap(h.deviceId)
        XCTAssertNotEqual(newId, deviceId)
        XCTAssertEqual(h.server.device(newId)?.tags, ["a": "1"])
    }

    // MARK: - Registration answers

    /// push-service answers a registration with the device id and secret alone: the device is registered, and a new
    /// device holds no tags.
    func test_anAnswerWithOnlyTheIdAndSecret_registersTheDevice() throws {
        let h = Harness()
        let deviceId = h.server.seedImportedDevice(token: Harness.tokenHex())
        let secret = try XCTUnwrap(h.server.device(deviceId)?.secret)
        h.server.script("register") { _ in .json(201, ["device_id": deviceId.uppercased(), "device_secret": secret], [:]) }
        h.registered()
        XCTAssertEqual(h.deviceId, deviceId)
        XCTAssertEqual((h.file("state.json")["registration"] as? [String: Any])?["status"] as? String, "registered")
        XCTAssertEqual(h.file("identity.json")["server_tags"] as? String, "none")
        let registered = try XCTUnwrap(h.logs.all.first { $0.code == "register.ok" })
        XCTAssertTrue(registered.message.hasPrefix("Device registered: \(deviceId) in "), registered.message)
        XCTAssertEqual(registered.metadata["device_id"], deviceId)
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        XCTAssertEqual(h.server.device(deviceId)?.tags, ["a": "1"])
    }

    /// push-service never answers a `status`: one that says `disabled` changes nothing, and tags and events go.
    func test_aDisabledStatusOnRegister_isIgnored() throws {
        let h = Harness()
        let deviceId = h.server.seedImportedDevice(token: Harness.tokenHex())
        let secret = try XCTUnwrap(h.server.device(deviceId)?.secret)
        h.server.script("register") { _ in
            .json(201, ["device_id": deviceId, "device_secret": secret, "status": "disabled", "adopted": false,
                        "linked": false], [:])
        }
        h.registered()
        XCTAssertEqual(h.deviceId, deviceId)
        h.submit(.addTags(["a": "1"]))
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(11)
        XCTAssertEqual(h.server.requests("events").count, 1)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertEqual((h.file("state.json")["registration"] as? [String: Any])?["status"] as? String, "registered")
    }

    /// Closed SDK routes and an unknown app id say different things. Closed routes, on registration or on a device
    /// route, say SallaPush is unavailable, with no URL and no advice to change it: an app can't. An unknown app id
    /// points at the app id.
    func test_routesClosed_sayUnavailable_andAnUnknownAppIdPointsAtTheAppId() throws {
        let closed = Harness()
        closed.server.script("register") { _ in FakeServer.error(404, "not_found") }
        closed.registered()
        let closedMessage = try XCTUnwrap(closed.logs.all.first { $0.code == "register.dormant" }?.message)
        XCTAssertTrue(closedMessage.hasPrefix("SallaPush is unavailable (HTTP 404 not_found"), closedMessage)
        XCTAssertFalse(closedMessage.contains("https://"), closedMessage)
        XCTAssertFalse(closedMessage.contains("Check the"), closedMessage)

        let device = Harness()
        device.registered()
        device.server.script("update") { _ in FakeServer.error(404, "not_found") }
        device.submit(.setLanguage("en"))
        device.advance(2)
        let routesMessage = try XCTUnwrap(device.logs.all.first { $0.code == "net.routes_closed" }?.message)
        XCTAssertEqual(routesMessage, "SallaPush is unavailable (404 not_found); pending work is kept and retried in 24 h.")

        let unknown = Harness()
        unknown.server.script("register") { _ in FakeServer.error(404, "unknown_app") }
        unknown.registered()
        let unknownMessage = try XCTUnwrap(unknown.logs.all.first { $0.code == "register.dormant" }?.message)
        XCTAssertTrue(unknownMessage.contains("Check the app id"), unknownMessage)
    }

    /// A registration's `400 invalid_request` is dormant for 24 h, then retried.
    func test_invalidRequestOnRegister_isDormant24h() {
        let h = Harness()
        h.server.script("register") { _ in FakeServer.error(400, "invalid_request") }
        h.registered()
        XCTAssertEqual(h.logs.all.first { $0.code == "net.client_error" }?.level, .error)
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("register").count, 1)
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertNotNil(h.deviceId)
    }

    /// push-service never answers `platform_mismatch`, `app_mismatch` or `app_disabled`: each is a client error like any
    /// other on the registration, which waits 24 h (`invalid_request`) before the registration is tried again.
    func test_codesPushServiceNeverSends_areOrdinaryClientErrors() {
        for (status, code) in [(400, "platform_mismatch"), (400, "app_mismatch"), (409, "app_disabled")] {
            let h = Harness()
            h.server.script("register") { _ in FakeServer.error(status, code) }
            h.registered()
            let registration = h.file("state.json")["registration"] as? [String: Any]
            XCTAssertEqual(registration?["dormant_reason"] as? String, "invalid_request", code)
            XCTAssertEqual(h.logs.all.first { $0.code == "net.client_error" }?.level, .error, code)
            XCTAssertTrue(h.logs.codes.allSatisfy { !$0.hasPrefix("register.") }, "\(code): \(h.logs.codes)")
            h.advance(3_600)
            XCTAssertEqual(h.server.requests("register").count, 1, code)
            h.advance(86_400)
            XCTAssertEqual(h.server.requests("register").count, 2, code)
            XCTAssertNotNil(h.deviceId, code)
        }
    }

    func test_backgroundLaunchWithoutIdentityOps_sendsNoRegister() {
        let h = Harness()
        h.application.state = .background
        h.initialize()
        h.sendToken()
        h.advance(30)
        XCTAssertTrue(h.server.requests.isEmpty)
        h.application.state = .active
        h.send(.willEnterForeground)
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    func test_backgroundLaunchWithPendingLogout_registersForIt() {
        let h = Harness()
        h.registered()
        h.login("token.one")
        h.advance(2)
        let next = h.relaunch()
        next.keychainAccess.removeAll(matching: "device_credentials.st_42_ios.\(next.hostTag)")
        next.application.state = .background
        next.initialize()
        next.logout()
        next.advance(2)
        XCTAssertEqual(next.server.requests("register").count, 2)
        XCTAssertTrue(next.server.requests("unlink").isEmpty, "a registration answer is a row without a link")
        XCTAssertTrue(next.server.requests("update").isEmpty)
    }

    // MARK: - The API URL

    /// An API URL copied with push-service's `/v1` (its OpenAPI server URL) registers: SallaPush drops the `/v1`, so
    /// its routes are the default URL's, and `init.started` names no URL.
    func test_anAPIURLEndingInV1_registers() throws {
        let h = Harness()
        h.registered { $0.apiBaseURL = URL(string: "https://api.salla.dev/notifications/v1/sallapush/v1/") }
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertNotNil(h.deviceId)
        XCTAssertFalse(h.logs.contains("register.dormant"))
        let started = try XCTUnwrap(h.logs.all.first { $0.code == "init.started" }?.message)
        XCTAssertFalse(started.contains("https://"), started)
    }

    /// The files are kept per host, not per URL: a wait for closed routes (`404 not_found`) at another URL on this host
    /// ends when the app starts with a new one, which may be the fix (here, a bare host of an earlier version made
    /// right), so the device registers at once. The same URL keeps the wait, and a wait for an unknown app id stays
    /// whatever the URL; `identity.json` takes the URL in use.
    func test_anotherAPIURLOnTheHost_endsAWaitForClosedRoutes_only() {
        let bareHost = URL(string: "https://api.salla.dev")
        for (first, code, registersAtLoad) in [(bareHost, "not_found", true), (nil, "not_found", false),
                                               (bareHost, "unknown_app", false)] {
            let label = "\(first?.absoluteString ?? "the default URL"), \(code)"
            let h = Harness()
            h.server.script("register") { _ in FakeServer.error(404, code) }
            h.registered { $0.apiBaseURL = first }
            XCTAssertEqual((h.file("state.json")["registration"] as? [String: Any])?["dormant_reason"] as? String, code,
                           label)
            let next = h.relaunch()
            next.initialize()
            next.advance(5)
            XCTAssertEqual(next.server.requests("register").count, registersAtLoad ? 2 : 1, label)
            XCTAssertEqual(next.deviceId != nil, registersAtLoad, label)
            XCTAssertEqual(next.file("identity.json")["api_base_url"] as? String, APIBase.defaultString, label)
        }
    }

    /// A registered device whose routes answered `404 not_found` at another URL on this host sends its pending work at
    /// once with the new URL, as the same device.
    func test_anotherAPIURLOnTheHost_endsAWaitForClosedDeviceRoutes() throws {
        let h = Harness()
        h.registered { $0.apiBaseURL = URL(string: "https://api.salla.dev") }
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("update", times: nil) { _ in FakeServer.error(404, "not_found") }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertTrue(h.logs.contains("net.routes_closed"))
        let refused = h.server.requests("update").count
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(5)
        XCTAssertEqual(next.deviceId, deviceId)
        XCTAssertEqual(next.server.requests("register").count, 1)
        let resent = next.server.requests("update").dropFirst(refused)
        XCTAssertEqual(resent.first?.json["language"] as? String, "en", "the pending update goes at once")
        XCTAssertEqual((next.file("state.json")["registration"] as? [String: Any])?["status"] as? String, "registered")
    }

    /// A build that kept a final `/v1` saved it in `identity.json`, and its routes got a doubled version: its wait for closed
    /// routes ends at load, because the URL in use differs from the saved one, though the saved one names the same URL
    /// once `/v1` is dropped.
    func test_aWaitForClosedRoutes_savedWithAFinalV1_endsAtLoad() throws {
        let copied = "https://api.salla.dev/notifications/v1/sallapush/v1"
        let h = Harness()
        h.server.script("register") { _ in FakeServer.error(404, "not_found") }
        h.registered { $0.apiBaseURL = URL(string: copied) }
        let file = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/identity.json")
        var identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        identity["api_base_url"] = copied
        try JSONSerialization.data(withJSONObject: identity).write(to: file)
        let next = h.relaunch()
        next.initialize { $0.apiBaseURL = URL(string: copied) }
        next.advance(5)
        XCTAssertEqual(next.server.requests("register").count, 2)
        XCTAssertNotNil(next.deviceId)
        XCTAssertEqual(next.file("identity.json")["api_base_url"] as? String, APIBase.defaultString)
    }
}
