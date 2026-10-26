import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class ConsentTests: XCTestCase {
    private func files(_ h: Harness) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: h.root.path)
        var names: [String] = []
        while let name = enumerator?.nextObject() as? String {
            if name.hasSuffix(".json") { names.append(name) }
        }
        return names.sorted()
    }

    func test_requiredBeforeInitialize_nothingStoredOrSent_untilGiven() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.initialize()
        h.sendToken()
        h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.advance(30)
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertTrue(files(h).isEmpty)
        XCTAssertEqual(h.keychainAccess.writeCount, 0)
        XCTAssertEqual(h.keychainAccess.readCount, 0)
        XCTAssertFalse(h.application.calls.contains("registerForRemoteNotifications"))
        XCTAssertEqual(h.logs.count("consent.waiting"), 1)
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertTrue(h.logs.contains("consent.given"))
        XCTAssertEqual(h.server.templates, ["register", "link"])
        XCTAssertEqual(files(h).first, "consent.json")
    }

    func test_configurationRequiresConsent_andSetConsentRequiredFalseCannotLowerIt() {
        let h = Harness()
        h.initialize { $0.requiresUserConsent = true }
        h.runtime.setConsentRequired(false)
        h.sendToken()
        h.advance(5)
        XCTAssertTrue(h.server.requests.isEmpty)
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    func test_consentGivenBeforeInitialize_startsAtOnce() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    func test_consentPersists_acrossRelaunch() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.submit(.setLanguage("en"))
        next.advance(2)
        XCTAssertEqual(next.server.requests("update").count, 1)
        XCTAssertEqual(next.file("consent.json", appId: "").isEmpty, true)
        let consent = try? Data(contentsOf: next.root.appendingPathComponent("consent.json"))
        let object = consent.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(object?["v"] as? Int, 1)
        XCTAssertEqual(object?["given"] as? Bool, true)
    }

    /// The withdrawal's data-minimising requests: the opt-out, the removal of every tag SallaPush held (the unsent one
    /// included), then the unlink.
    func test_withdrawal_sendsOptOutTagClearingAndUnlink_thenIdles() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let before = h.server.requests.count
        h.submit(.addTags(["b": "2"]))
        h.runtime.setConsentGiven(false)
        h.advance(5)
        let after = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(after.map(\.template), ["update", "tags", "unlink"])
        XCTAssertEqual(after.first?.json as NSDictionary?, ["opted_in": false] as NSDictionary)
        XCTAssertEqual(after.dropFirst().first?.json as NSDictionary?, ["remove": ["a", "b"]] as NSDictionary)
        XCTAssertTrue(h.logs.contains("consent.revoked"))
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        h.runtime.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        h.submit(.setLanguage("fr"))
        h.advance(60)
        XCTAssertEqual(h.server.requests.count, before + 3, "idle after withdrawal")
        XCTAssertNotNil(h.keychainAccess.value(account: "device_credentials.st_42_ios.\(h.hostTag)"), "the credentials stay")
    }

    /// A withdrawal whose tag clearing still finds tags after one more request doesn't say the tags were cleared.
    func test_aWithdrawal_whoseServerStillNamesTags_doesNotSayTheyWereCleared() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        h.server.script("tags", times: 2) { _ in .json(200, ["tags": ["x": "stays"]], [:]) }
        h.runtime.setConsentGiven(false)
        h.advance(5)
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertFalse(revoked.message.contains("its tags were cleared"), revoked.message)
        XCTAssertTrue(revoked.message.contains("the server still holds tags SallaPush could not clear"), revoked.message)
    }

    /// A withdrawal keeps no customer id on disk, also when a login is still queued.
    func test_aWithdrawalWithALoginQueued_keepsNoCustomerIdOnDisk() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.initialize()
        h.login(customer: "cust_a")
        h.runtime.setConsentGiven(false)
        h.advance(2)
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/identity.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("cust_a"), text)
    }

    func test_consentGivenAgain_resumesWithTheSameDevice() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let deviceId = h.deviceId
        h.runtime.setConsentGiven(false)
        h.advance(5)
        h.runtime.setConsentGiven(true)
        h.submit(.setLanguage("fr"))
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertEqual(h.deviceId, deviceId)
        XCTAssertEqual(h.server.requests("update").last?.json["language"] as? String, "fr")
    }

    /// No `registerForRemoteNotifications` by the SDK while consent is pending, also after a grant;
    /// the engine start registers once consent is given.
    func test_requestPermission_whileConsentIsPending_registersOnlyWhenTheEngineStarts() {
        let h = Harness()
        h.center.status = .notDetermined
        h.runtime.setConsentRequired(true)
        h.initialize()
        h.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        h.settle()
        XCTAssertEqual(h.center.authorizationRequests, [false])
        XCTAssertFalse(h.application.calls.contains("registerForRemoteNotifications"))
        h.runtime.setConsentGiven(true)
        h.settle()
        XCTAssertEqual(h.application.calls.filter { $0 == "registerForRemoteNotifications" }.count, 1,
                       "registered once, by the engine start")
    }

    /// A withdrawal whose write fails removes the old `given: true`, so the next launch waits.
    func test_failedWithdrawalWrite_removesTheOldFile_andTheNextLaunchWaits() throws {
        let h = Harness()
        h.registered { $0.requiresUserConsent = true }
        XCTAssertTrue(h.server.requests.isEmpty)
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 1)
        h.failingWrites.set(["consent.json"])
        h.runtime.setConsentGiven(false)
        h.advance(5)
        let failure = try XCTUnwrap(h.logs.all.first { $0.code == "storage.failed" })
        XCTAssertTrue(failure.message.contains("consent.json"), failure.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("consent.json").path))
        let before = h.server.requests.count
        let next = h.relaunch()
        next.initialize { $0.requiresUserConsent = true }
        next.sendToken()
        next.advance(30)
        XCTAssertNil(next.engine, "the next launch waits for consent")
        XCTAssertEqual(next.server.requests.count, before)
    }

    /// When the file can be neither written nor removed, this process stays withdrawn and the write is retried at
    /// the next foreground; once it succeeds, later launches wait too.
    func test_failedConsentWrite_isRetriedAtTheNextForeground() throws {
        let h = Harness()
        h.registered { $0.requiresUserConsent = true }
        h.runtime.setConsentGiven(true)
        h.advance(3)
        h.failingWrites.set(["consent.json"])
        h.failingRemoves.set(true)
        h.runtime.setConsentGiven(false)
        h.advance(5)
        let requests = h.server.requests.count
        h.submit(.setLanguage("fr"))
        h.advance(30)
        XCTAssertEqual(h.server.requests.count, requests, "withdrawn in memory")
        h.failingWrites.set([])
        h.failingRemoves.set(false)
        h.send(.willEnterForeground)
        h.settle()
        let data = try Data(contentsOf: h.root.appendingPathComponent("consent.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["given"] as? Bool, false)
        let next = h.relaunch()
        next.initialize { $0.requiresUserConsent = true }
        next.advance(30)
        XCTAssertNil(next.engine)
    }

    // MARK: - Consent given again after a withdrawal (Android reconcileAfterWithdrawal)

    /// Withdrawn (the server opted out and unlinked), relaunch, consent given again: the launch login is not
    /// skipped and a full update sends `opted_in: true`, so the server and the getters agree again.
    func test_withdrawal_thenConsentAtALaterLaunch_sendsOptedInAndRelinks() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login(customer: "cust_a")
        h.advance(3)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.runtime.setConsentGiven(false)
        h.advance(5)
        XCTAssertEqual(h.server.device(deviceId)?.optedIn, false)
        XCTAssertNil(h.server.device(deviceId)?.externalId)
        let identity = h.file("identity.json")
        XCTAssertEqual(identity["server_link"] as? String, "unknown", "written before the withdrawal requests")
        XCTAssertTrue(identity["desired_external_id"] is NSNull, "the customer's id is not kept")
        XCTAssertTrue((h.file("state.json")["registration"] as? [String: Any])?["sent_fingerprint"] is NSNull)
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        next.runtime.setConsentGiven(true)
        next.settle()
        next.sendToken()
        next.send(.didBecomeActive)
        next.advance(30)
        XCTAssertEqual(next.server.device(deviceId)?.optedIn, true)
        XCTAssertEqual(next.server.device(deviceId)?.externalId, "cust_a")
        XCTAssertEqual(next.snapshot.externalId, "cust_a")
        XCTAssertTrue(next.snapshot.optedIn)
        XCTAssertFalse(next.logs.contains("login.skipped_same"))
    }

    /// Consent given again while the withdrawal's opt-out is on the wire. That request may have been applied,
    /// so `opted_in: true` is sent again.
    func test_consentGivenAgain_whileTheOptOutIsOnTheWire_sendsOptedInAgain() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.advance(3)
        h.server.script("update", times: 1) { _ in .hold }
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.setConsentGiven(true)
        h.settle()
        h.server.mutate(h.deviceId) { $0.optedIn = false }
        h.advance(30)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
        XCTAssertEqual(h.server.device(h.deviceId)?.optedIn, true)
    }

    /// Consent given again in the same process after the withdrawal unlinked the device: the asserted customer is
    /// logged in again with the token in memory (Android's relinkAfterConsent).
    func test_consentGivenAgain_inTheSameProcess_relinksTheAssertedCustomer() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login(customer: "cust_a")
        h.advance(3)
        h.runtime.setConsentGiven(false)
        h.advance(5)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertNil(h.snapshot.externalId)
        XCTAssertTrue(h.snapshot.isLoggedIn)
        h.runtime.setConsentGiven(true)
        h.advance(5)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(h.server.requests("link").last?.json["identity_token"] as? String, "eyJ.cust_a")
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(h.server.device(h.deviceId)?.optedIn, true)
        XCTAssertEqual(h.snapshot.externalId, "cust_a")
    }

    /// `consent.revoked` says what happened. Not registered: nothing was sent.
    func test_withdrawal_ofAnUnregisteredDevice_saysNothingWasSent() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.initialize()
        h.runtime.setConsentGiven(false)
        h.advance(5)
        XCTAssertTrue(h.server.requests.isEmpty)
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertEqual(revoked.message, "Consent withdrawn; this device was not registered, so the server holds nothing to "
                       + "minimise. SallaPush is now idle.")
    }

    func test_withdrawal_ofALinkedDevice_saysOptedOutAndUnlinked_andOfAGuest_saysThereWasNothingToClear() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.runtime.setConsentGiven(false)
        h.advance(5)
        XCTAssertEqual(h.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out and unlinked on the server. SallaPush is now idle.")
        let guest = Harness()
        guest.runtime.setConsentRequired(true)
        guest.runtime.setConsentGiven(true)
        guest.registered()
        guest.runtime.setConsentGiven(false)
        guest.advance(5)
        XCTAssertEqual(guest.server.templates.suffix(1), ["update"], "an unlinked guest without tags needs no logout")
        XCTAssertEqual(guest.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out on the server; it held no link or tags to clear. SallaPush is now idle.")
    }

    /// Both data-minimising requests are refused. Each refusal is logged with what support needs, and
    /// `consent.revoked` never claims the server was told.
    func test_withdrawal_refusedByTheServer_logsTheRefusals_andSaysSo() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.server.script("update", times: nil) { _ in FakeServer.error(404, "not_found") }
        h.server.script("unlink", times: nil) { _ in FakeServer.error(401, "invalid_device_secret") }
        h.runtime.setConsentGiven(false)
        h.advance(5)
        let closed = try XCTUnwrap(h.logs.all.first { $0.code == "net.routes_closed" })
        XCTAssertEqual(closed.level, .warn)
        XCTAssertTrue(closed.message.contains("opt-out was not applied"), closed.message)
        XCTAssertFalse(closed.message.contains("Check the"), closed.message)
        XCTAssertEqual(closed.metadata["error_code"], "not_found")
        let rejected = try XCTUnwrap(h.logs.all.first { $0.code == "net.client_error" })
        XCTAssertEqual(rejected.level, .error)
        XCTAssertTrue(rejected.message.hasPrefix("POST /devices/{id}/unlink was rejected (401 invalid_device_secret"),
                      rejected.message)
        XCTAssertNotNil(rejected.metadata["request_id"])
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertFalse(revoked.message.contains("on the server"), revoked.message)
        XCTAssertTrue(revoked.message.contains("the opt-out was refused (404 not_found"), revoked.message)
        XCTAssertTrue(revoked.message.contains("the unlink was refused (401 invalid_device_secret"), revoked.message)
        XCTAssertEqual(h.server.requests("register").count, 1, "consent rules out a re-registration")
    }

    /// The opt-out keeps failing. After six attempts the withdrawal ends in this process (idle, logged)
    /// instead of waiting forever; the unlink step is not attempted.
    func test_withdrawal_retriesExhausted_endsTheWithdrawal_andSaysTheServerWasNotTold() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.runtime.setConsentGiven(false)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("update").count, 6)
        let exhausted = try XCTUnwrap(h.logs.all.first { $0.code == "net.retry_exhausted" })
        XCTAssertTrue(exhausted.message.hasSuffix("the consent withdrawal stops retrying it."), exhausted.message)
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertTrue(revoked.message.hasPrefix("Consent withdrawn; the opt-out could not be sent in this process "
                                                    + "(503 server_error"), revoked.message)
        XCTAssertTrue(revoked.message.hasSuffix("). SallaPush is now idle."), revoked.message)
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.advance(3_600)
        XCTAssertEqual(h.server.requests("update").count, 6, "idle")
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
    }

    /// Every ordering of setConsentRequired (R), initialize (I) and setConsentGiven (G), those that start with G or
    /// give consent before requiring it included.
    func test_everyOrdering_ofRequiredInitializeAndGiven_registersOnce() {
        for order in ["RIG", "RGI", "IRG", "GRI", "GIR", "IGR"] {
            let h = Harness()
            for step in order {
                switch step {
                case "R": h.runtime.setConsentRequired(true)
                case "G": h.runtime.setConsentGiven(true)
                default: h.initialize()
                }
                h.settle()
            }
            h.sendToken()
            h.advance(3)
            XCTAssertEqual(h.server.templates, ["register"], order)
            XCTAssertTrue(h.logs.contains("consent.given"), order)
        }
    }

    func test_requiredWhileRunning_pausesWithoutRequests() {
        let h = Harness()
        h.registered()
        h.runtime.setConsentRequired(true)
        h.submit(.setLanguage("fr"))
        h.advance(30)
        XCTAssertEqual(h.server.templates, ["register"])
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(h.server.requests("update").count, 1)
    }
}
