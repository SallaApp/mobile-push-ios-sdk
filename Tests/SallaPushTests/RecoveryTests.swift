import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class RecoveryTests: XCTestCase {
    private func credentialsItem(_ h: Harness) -> Data? {
        h.keychainAccess.value(account: "device_credentials.st_42_ios.\(h.hostTag)")
    }

    /// A `401 invalid_device_secret`: the credentials are forgotten, the device registers again at once, and the events
    /// that were refused go with the credentials of the new registration.
    func test_invalidDeviceSecret_onEvents_registersAgain_andTheEventsGo() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        let before = credentialsItem(h)
        h.server.mutate(deviceId) { $0.secret = "refused" }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(12)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertTrue(h.logs.contains("register.reregistering"))
        let events = h.server.requests("events")
        XCTAssertEqual(events.count, 2, "refused once, then sent")
        let device = try XCTUnwrap(h.server.device(h.deviceId))
        XCTAssertEqual(events.last?.deviceId, device.id)
        XCTAssertEqual(events.last?.headers["authorization"], "Device " + device.secret)
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
        let after = try XCTUnwrap(credentialsItem(h))
        XCTAssertNotEqual(after, before, "the refused credentials were replaced")
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(stored["device_id"] as? String, device.id)
    }

    /// A `404 unknown_device`: the device registers again, as a new device, and the events go to it.
    func test_unknownDevice_onEvents_registersAgain_andTheEventsGoToTheNewDevice() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.purge(deviceId)
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .received, at: h.clock.now(), actionId: nil)]))
        h.advance(12)
        XCTAssertEqual(h.server.requests("register").count, 2)
        let newId = try XCTUnwrap(h.deviceId)
        XCTAssertNotEqual(newId, deviceId)
        XCTAssertEqual(h.server.requests("events").map(\.deviceId), [deviceId, newId])
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
    }

    /// push-service's device auth does not read a device's status: a device disabled because another registration took
    /// its token still answers, so nothing registers again, and a logout unlinks it.
    func test_aDisabledDevice_stillAnswers_andALogoutUnlinksIt() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.mutate(h.deviceId) { $0.disabledReason = "rotation" }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertEqual(h.server.requests("update").count, 1)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }

    /// A logout pending when the row turns out purged: the registration makes a new row, which has no link, so the
    /// logout is settled without a request.
    func test_unknownDevice_withPendingLogout_reregisters_andSettlesTheLogout() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("unlink") { _ in FakeServer.error(404, "unknown_device") }
        h.logout()
        h.server.purge(deviceId)
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertTrue(h.identityOps().isEmpty)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }

    func test_unknownDevice_replaysLoginAndTags() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.purge(deviceId)
        h.submit(.setLanguage("en"))
        h.advance(12)
        let newId = try XCTUnwrap(h.deviceId)
        XCTAssertNotEqual(newId, deviceId)
        XCTAssertNotNil(h.server.device(newId)?.externalId)
        XCTAssertEqual(h.server.device(newId)?.tags, ["a": "1"])
    }

    func test_routesClosed_keepsEveryOp_dormant24h() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in FakeServer.error(404, "not_found") }
        h.logout()
        h.advance(2)
        XCTAssertTrue(h.logs.contains("net.routes_closed"))
        h.submit(.addTags(["a": "1"]))
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertEqual(h.identityOps().count, 1, "the logout is kept, not done")
        h.server.clearScripts()
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("unlink").count, 2)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// When a `not_found` dormancy of the device routes ends, changes are sent again.
    func test_routesReopened_updatesResume() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(404, "not_found") }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 1)
        h.advance(86_400 + 10)
        h.submit(.setLanguage("fr"))
        h.advance(2)
        h.submit(.setLanguage("de"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["language"] as? String, "de")
        h.submit(.optOut)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, false)
        XCTAssertEqual(h.file("state.json")["registration"].flatMap { ($0 as? [String: Any])?["status"] as? String }, "registered")
    }
}
