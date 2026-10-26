import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// As on Android, a consent withdrawal does not cancel the request on
/// the wire. It lands or fails, its answer is applied in memory (a registration's credentials reach the Keychain only
/// once consent is given again), and the opt-out, the tag clearing and the unlink are decided only when nothing is on
/// the wire.
final class ConsentInFlightTests: XCTestCase {
    /// Every file under the SDK's folder and its bytes.
    private func files(_ h: Harness) -> [String: Data] {
        var contents: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: h.root.path)
        while let name = enumerator?.nextObject() as? String {
            let url = h.root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            contents[name] = try? Data(contentsOf: url)
        }
        return contents
    }

    private func credentials(_ h: Harness) -> Data? {
        h.keychainAccess.value(account: KeychainStore.credentialsAccount(appId: "st_42_ios", hostTag: h.hostTag))
    }

    private func consentGivenAndRegistered() -> Harness {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.advance(3)
        return h
    }

    /// The same rule as the Android SDK.
    func test_withdrawalWhileALoginIsInFlight_logsOutOnceTheLoginLands() throws {
        let h = consentGivenAndRegistered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.advance(3)
        XCTAssertEqual(h.server.requests.count, before, "nothing goes while the login is on the wire")
        XCTAssertEqual(h.server.heldCount, 1, "the login on the wire is not cancelled")
        h.server.releaseHeld()
        h.advance(5)
        let after = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(after.map(\.template), ["update", "unlink"])
        XCTAssertEqual(after.first?.json["opted_in"] as? Bool, false)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId, "the login that landed is unlinked")
        XCTAssertNil(h.snapshot.externalId)
        h.advance(60)
        XCTAssertEqual(h.server.requests.count, before + 2)
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertEqual(revoked.message, "Consent withdrawn; opted out and unlinked on the server. SallaPush is now idle.")
    }

    /// The same rule as the Android SDK.
    func test_withdrawalWhileTheFirstRegistrationIsOnTheWire_optsOutOnceItLands() throws {
        let h = Harness()
        h.server.script("register", times: 1) { _ in .hold }
        h.runtime.setConsentRequired(true)
        h.initialize()
        h.runtime.setConsentGiven(true)
        h.sendToken()
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.setConsentGiven(false)
        h.advance(3)
        XCTAssertEqual(h.server.templates, ["register"])
        let atWithdrawal = files(h)
        h.server.releaseHeld()
        h.advance(5)
        // The row the registration created is opted out like any other; nothing else goes out.
        XCTAssertEqual(h.server.templates, ["register", "update"])
        XCTAssertEqual(h.server.requests("update").first?.json["opted_in"] as? Bool, false)
        h.advance(60)
        XCTAssertEqual(h.server.requests.count, 2)
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertEqual(revoked.message,
                       "Consent withdrawn; opted out on the server; it held no link or tags to clear. SallaPush is now idle.")
        // Nothing is written while consent is withdrawn: the new credentials live in memory only.
        XCTAssertEqual(files(h), atWithdrawal)
        XCTAssertNil(credentials(h))

        // Consent given again: the same registration is used and its credentials are written now.
        h.runtime.setConsentGiven(true)
        h.advance(5)
        XCTAssertNotNil(credentials(h))
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(h.server.device(deviceId)?.optedIn, true)
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.initialize()
        XCTAssertEqual(next.deviceId, deviceId)
        XCTAssertEqual(next.server.requests("register").count, 1)
    }

    /// A tags request on the wire at the withdrawal lands; the withdrawal clears the tags it left (the device was never
    /// linked, so nothing is unlinked).
    func test_withdrawalWhileATagsRequestIsInFlight_clearsTheTagsItLeaves() {
        let h = consentGivenAndRegistered()
        h.server.script("tags", times: 1) { _ in .hold }
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.setConsentGiven(false)
        h.advance(3)
        XCTAssertTrue(h.snapshot.tags.isEmpty, "the getters forget the tags at once")
        h.server.releaseHeld()
        h.advance(5)
        XCTAssertEqual(h.server.templates.suffix(2), ["update", "tags"])
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// As on Android, a tags request on the wire at the withdrawal may have applied
    /// even when its answer is lost (a timeout), so the device may hold tags: the withdrawal clears them.
    func test_withdrawalWhileATagsRequestIsOnTheWire_thatTimesOutAfterApplying_clearsTheTags() throws {
        let h = consentGivenAndRegistered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("tags", times: 1) { _ in .hold }
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.settle()
        // The server applied the tag, but the answer never arrived.
        h.server.mutate(deviceId) { $0.tags = ["plan": "gold"] }
        h.server.releaseHeld(.failure(.timeout))
        h.advance(30)
        let after = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(after.map(\.template), ["update", "tags"])
        XCTAssertEqual(after.last?.json as NSDictionary?, ["remove": ["plan"]] as NSDictionary)
        XCTAssertEqual(h.server.device(deviceId)?.tags, [:])
        XCTAssertEqual(h.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out on the server; its tags were cleared. SallaPush is now idle.")
    }

    /// The reverse: an answered error (here a 503) applied nothing, so a guest device that held no tags is only opted
    /// out, and `consent.revoked` says it held nothing to clear.
    func test_withdrawalWhileATagsRequestIsOnTheWire_answeredWithAnError_onlyOptsOut() throws {
        let h = consentGivenAndRegistered()
        h.server.script("tags", times: 1) { _ in .hold }
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.settle()
        h.server.releaseHeld(FakeServer.error(503, "server_error"))
        h.advance(30)
        XCTAssertEqual(Array(h.server.requests.dropFirst(before)).map(\.template), ["update"])
        XCTAssertEqual(h.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out on the server; it held no link or tags to clear. SallaPush is now idle.")
    }

    /// A tags answer settles it, as on Android: a guest whose tags the request on the
    /// wire removes, answered with no tags after the withdrawal reset the mirror, holds nothing to clear: only the
    /// opt-out goes.
    func test_withdrawalWhileATagsRequestRemovingEveryTagIsOnTheWire_answeredWithNoTags_onlyOptsOut() throws {
        let h = consentGivenAndRegistered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        XCTAssertEqual(h.file("identity.json")["server_tags"] as? String, "some")
        h.server.script("tags", times: 1) { _ in .hold }
        h.runtime.removeTags(["plan"])
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.settle()
        h.server.releaseHeld()
        h.advance(30)
        XCTAssertEqual(Array(h.server.requests.dropFirst(before)).map(\.template), ["update"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertEqual(h.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out on the server; it held no link or tags to clear. SallaPush is now idle.")
    }

    /// A login on the wire answered 403 after the withdrawal applied nothing: an unlinked guest device is only opted
    /// out, as on Android.
    func test_withdrawalWhileALoginIsInFlight_thatIsRejected_onlyOptsOut() {
        let h = consentGivenAndRegistered()
        h.server.customers = { _ in .rejected }
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.advance(3)
        h.server.releaseHeld()
        h.advance(5)
        XCTAssertEqual(Array(h.server.requests.dropFirst(before)).map(\.template), ["update"])
    }

    /// A login that lands during the withdrawal never shows its route key: the withdrawal forgot the customer.
    func test_aLoginLandingDuringTheWithdrawal_staysHiddenFromTheGetters() {
        let h = consentGivenAndRegistered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("update", times: 1) { _ in .hold }
        h.runtime.setConsentGiven(false)
        h.settle()
        h.server.releaseHeld()
        h.settle()
        XCTAssertEqual(h.server.heldCount, 1, "the withdrawal's opt-out is on the wire")
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId, "the login landed and linked the device")
        XCTAssertNil(h.snapshot.externalId)
        h.server.releaseHeld()
        h.advance(5)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId, "the withdrawal's unlink unlinked it")
    }

    /// SallaPush does not act on the app's behalf while consent is withdrawn: an update answered meanwhile links nothing.
    func test_answersLandingDuringTheWithdrawal_linkNothing() {
        let unlinked = consentGivenAndRegistered()
        unlinked.login("customer.token.a")
        unlinked.advance(3)
        unlinked.server.mutate(unlinked.deviceId) { $0.externalId = nil }
        unlinked.server.script("update", times: 1) { _ in .hold }
        unlinked.submit(.setLanguage("fr"))
        unlinked.advance(2)
        unlinked.runtime.setConsentGiven(false)
        unlinked.settle()
        unlinked.server.releaseHeld()
        unlinked.advance(5)
        XCTAssertEqual(unlinked.server.requests("link").count, 1, "no link while consent is withdrawn")
    }

    /// A device answer that drops the credentials during the withdrawal changes nothing in the Keychain (nothing is
    /// written while consent is withheld), and `consent.revoked` says the server could not be told.
    func test_credentialsRefusedDuringTheWithdrawal_touchNothing_andAreReported() throws {
        let h = consentGivenAndRegistered()
        h.server.script("update", times: 1) { _ in .hold }
        h.submit(.setLanguage("fr"))
        h.advance(2)
        h.runtime.setConsentGiven(false)
        h.settle()
        let item = try XCTUnwrap(credentials(h))
        h.server.releaseHeld(FakeServer.error(401, "invalid_device_secret"))
        h.advance(5)
        XCTAssertEqual(credentials(h), item)
        XCTAssertEqual(h.server.requests("register").count, 1, "consent rules out a new registration")
        let revoked = try XCTUnwrap(h.logs.all.first { $0.code == "consent.revoked" })
        XCTAssertEqual(revoked.message, "Consent withdrawn; the server refused this device's credentials meanwhile, so it "
                           + "could not be told. SallaPush is now idle.")
    }

    /// Consent given again while the login of before the withdrawal is still on the wire: no withdrawal request was
    /// sent, the login lands as usual and links, and the next update re-sends `opted_in`.
    func test_consentGivenAgain_whileTheLoginIsStillOnTheWire_theLoginLands() {
        let h = consentGivenAndRegistered()
        h.server.script("link", times: 1) { _ in .hold }
        h.login("customer.token.a")
        h.advance(2)
        let before = h.server.requests.count
        h.runtime.setConsentGiven(false)
        h.settle()
        h.runtime.setConsentGiven(true)
        h.settle()
        h.server.releaseHeld()
        h.advance(5)
        let after = Array(h.server.requests.dropFirst(before)).map(\.template)
        XCTAssertFalse(after.contains("unlink"), "\(after)")
        XCTAssertEqual(h.server.requests("link").count, 1, "the link on the wire is not sent twice")
        XCTAssertNotNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertNotNil(h.snapshot.externalId)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
    }
}
