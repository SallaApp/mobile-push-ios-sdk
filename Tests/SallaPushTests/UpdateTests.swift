import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class UpdateTests: XCTestCase {
    func test_sameFingerprintWithin24h_sendsNothing() {
        let h = Harness()
        h.registered()
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.advance(3_600)
        h.send(.willEnterForeground)
        h.advance(2)
        XCTAssertEqual(h.server.templates, ["register"])
    }

    func test_after24h_heartbeat() throws {
        let h = Harness()
        h.registered()
        h.advance(86_400)
        h.send(.willEnterForeground)
        h.advance(2)
        let updates = h.server.requests("update")
        XCTAssertEqual(updates.count, 1)
        let body = try XCTUnwrap(updates.first?.json)
        XCTAssertNil(body["push_token"])
        XCTAssertEqual(body["opted_in"] as? Bool, true)
        XCTAssertEqual(body["apns_env"] as? String, "sandbox")
        XCTAssertEqual(body["language"] as? String, "ar")
        XCTAssertEqual(body["sdk_version"] as? String, "1.1.0")
        XCTAssertTrue(h.logs.contains("heartbeat.sent"))
        XCTAssertEqual(updates.first?.headers["authorization"]?.hasPrefix("Device "), true)
    }

    /// push-service answers an update with `200 {}`: the update is done and nothing is sent again.
    func test_theEmptyAnswer_completesTheUpdate() {
        let h = Harness()
        h.registered()
        h.server.script("update", times: nil) { _ in .json(200, [:], [:]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 1)
        XCTAssertEqual(h.logs.all.last { $0.code == "update.sent" }?.message, "Device updated (language).")
        h.send(.willEnterForeground)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("update").count, 1)
        XCTAssertFalse(h.logs.contains("net.invalid_response"))
    }

    func test_permissionRevoked_putsOptedInFalse() throws {
        let h = Harness()
        h.registered()
        h.center.status = .denied
        h.send(.didBecomeActive)
        h.advance(2)
        let update = try XCTUnwrap(h.server.requests("update").last)
        XCTAssertEqual(update.json["opted_in"] as? Bool, false)
        XCTAssertTrue(h.logs.contains("permission.changed"))
        XCTAssertFalse(h.snapshot.optedIn)
        XCTAssertTrue(h.logs.contains("update.sent"))
    }

    /// `update.sent` names the fields that changed since the last request the server accepted in
    /// this process; the first update after a relaunch cannot name them, since only the fingerprint is persisted.
    func test_updateSent_namesTheChangedFields() {
        let h = Harness()
        h.registered()
        h.center.status = .denied
        h.submit(.setLanguage("en"))
        h.send(.didBecomeActive)
        h.advance(2)
        XCTAssertEqual(h.logs.all.last { $0.code == "update.sent" }?.message, "Device updated (opted_in, language).")
        h.sendToken(7)
        h.advance(2)
        XCTAssertEqual(h.logs.all.last { $0.code == "update.sent" }?.message, "Device updated (push_token).")
        XCTAssertEqual(h.server.requests("update").count, 2)
        let next = h.relaunch()
        next.initialize()
        next.submit(.setLanguage("fr"))
        next.advance(2)
        XCTAssertEqual(next.logs.all.last { $0.code == "update.sent" }?.message,
                       "Device updated (first update since launch: a device field changed since the last one).")
    }

    func test_hostPromptGranted_didBecomeActive_putsOptedInTrue() throws {
        let h = Harness()
        h.center.status = .notDetermined
        h.registered()
        XCTAssertEqual(h.server.requests("register").first?.json["opted_in"] as? Bool, false)
        h.center.status = .authorized
        h.send(.didBecomeActive)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
        XCTAssertTrue(h.snapshot.optedIn)
    }

    func test_tokenChange_putsOnSameDevice() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.sendToken(7)
        h.advance(2)
        let update = try XCTUnwrap(h.server.requests("update").last)
        XCTAssertEqual(update.deviceId, deviceId)
        XCTAssertEqual(update.json["push_token"] as? String, Harness.tokenHex(7))
        XCTAssertEqual(h.server.requests("register").count, 1)
        h.send(.willEnterForeground)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 1, "the token is sent once")
    }

    func test_unchangedTokenDelivery_rereadsPermission_noNetworkWhenSame() {
        let h = Harness()
        h.registered()
        let reads = h.center.readCount
        h.sendToken()
        h.advance(2)
        XCTAssertGreaterThan(h.center.readCount, reads)
        XCTAssertEqual(h.server.templates, ["register"])
        XCTAssertTrue(h.logs.contains("token.unchanged"))
    }

    func test_refreshPermission_readsAndUpdates() {
        let h = Harness()
        h.registered()
        h.center.status = .denied
        h.submit(.refreshPermission)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, false)
    }

    func test_clockInTheFuture_countsAsDue() throws {
        let h = Harness()
        h.registered()
        let registeredAt = h.clock.now()

        // An hour later, nothing is due.
        let next = h.relaunch()
        next.clock.set(registeredAt + 3_600)
        next.initialize()
        next.advance(2)
        XCTAssertEqual(next.server.requests("update").count, 0)

        // The device clock moved back below the last update: the stored time is in the future, so the
        // heartbeat counts as due at once.
        let third = next.relaunch()
        third.clock.set(registeredAt - 50_000)
        third.initialize()
        third.advance(2)
        XCTAssertEqual(third.server.requests("update").count, 1)
    }

    func test_languageChange_sendsUpdate_unchangedIsIgnored() {
        let h = Harness()
        h.registered()
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["language"] as? String, "en")
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 1)
        h.submit(.setLanguage(nil))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["language"] as? String, "ar")
    }

    func test_timezoneChange_sendsUpdate() {
        let h = Harness()
        h.registered()
        h.device.zone.set("Europe/London")
        h.send(.timeZoneChanged)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["timezone"] as? String, "Europe/London")
    }

    func test_optOutAndOptIn() throws {
        let h = Harness()
        h.registered()
        h.submit(.optOut)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, false)
        XCTAssertFalse(h.snapshot.optedIn)
        XCTAssertTrue(h.logs.contains("subscription.opted_out"))
        h.submit(.optIn)
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
        XCTAssertTrue(h.logs.contains("subscription.opted_in"))
        XCTAssertTrue(h.center.authorizationRequests.isEmpty, "no prompt once permission is decided")
    }

    func test_optIn_promptsWhenNotDetermined() {
        let h = Harness()
        h.center.status = .notDetermined
        h.registered()
        h.submit(.optIn)
        h.advance(2)
        XCTAssertEqual(h.center.authorizationRequests, [false])
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
    }

    /// An `optIn()` in `didFinishLaunching`, before the first permission read.
    func test_optInBeforeInitialize_promptsOnlyWhenNotDetermined() {
        for (status, prompts) in [(PermissionStatus.notDetermined, [false]), (.authorized, []), (.denied, [])] {
            let h = Harness()
            h.center.status = status
            h.runtime.submit(.optIn)
            h.initialize()
            h.advance(2)
            XCTAssertEqual(h.center.authorizationRequests, prompts, "status \(status.name)")
        }
    }

    func test_optInRightAfterInitialize_promptsOnlyWhenNotDetermined() {
        for (status, prompts) in [(PermissionStatus.notDetermined, [false]), (.authorized, []), (.provisional, [])] {
            let h = Harness()
            h.center.status = status
            h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
            h.runtime.submit(.optIn)
            h.settle()
            h.advance(2)
            XCTAssertEqual(h.center.authorizationRequests, prompts, "status \(status.name)")
        }
    }

    func test_optInTwice_promptsOnce_andThePermissionIsReadAfterIt() {
        let h = Harness()
        h.center.status = .notDetermined
        h.useAsynchronousSystemCallbacks()
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        h.runtime.submit(.optIn)
        h.runtime.submit(.optIn)
        h.settle()
        h.sendToken()
        h.advance(3)
        XCTAssertEqual(h.center.authorizationRequests, [false])
        XCTAssertEqual(h.snapshot.permission, .authorized)
        XCTAssertTrue(h.snapshot.optedIn)
    }

    func test_metadata_isTruncatedInUTF16Units() throws {
        let h = Harness()
        h.registered { $0.appVersion = String(repeating: "٥", count: 40) }
        let body = try XCTUnwrap(h.server.requests("register").first?.json)
        let version = try XCTUnwrap(body["app_version"] as? String)
        XCTAssertEqual(version.utf16.count, 32)
    }

    func test_reinstallWithKeychain_sendsOneFullUpdate() {
        let h = Harness()
        h.registered()
        try? FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.sendToken()
        next.advance(2)
        XCTAssertEqual(next.server.requests("register").count, 1)
        XCTAssertEqual(next.server.requests("update").count, 1)
    }
}
