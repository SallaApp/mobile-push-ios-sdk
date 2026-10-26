import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// Records login failures reported to observers.
final class FailureRecorder: @unchecked Sendable {
    let failures = Locked<[SallaPushLoginFailure]>([])
    private var observation: SallaPushObservation?

    init(_ harness: Harness) {
        let failures = self.failures
        observation = harness.runtime.observers.addLoginFailureHandler { failure in
            failures.withLock { $0.append(failure) }
        }
    }
}

/// The link and the unlink as push-service runs them: `login(externalId:identityToken:)` links the device (Salla's
/// platform checks the token, which SallaPush keeps in memory only), and `logout()` unlinks it, saved and retried until
/// the server answers.
final class IdentityTests: XCTestCase {
    func test_login_sendsTheLink_withTheExternalIdAndTheIdentityToken() throws {
        let h = Harness()
        h.registered()
        h.login(externalId: "  1001 ", token: " eyJ.1001\n")
        XCTAssertTrue(h.snapshot.isLoggedIn)
        XCTAssertEqual(h.snapshot.externalId, "1001", "the getters show the id as soon as login returns")
        h.advance(2)
        let link = try XCTUnwrap(h.server.requests("link").first)
        XCTAssertEqual(link.method, "POST")
        XCTAssertEqual(link.path, "/devices/\(try XCTUnwrap(h.deviceId))/link")
        XCTAssertEqual(link.json as NSDictionary, ["external_id": "1001", "identity_token": "eyJ.1001"] as NSDictionary)
        XCTAssertEqual(link.headers["authorization"]?.hasPrefix("Device "), true)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "1001")
        XCTAssertTrue(h.logs.contains("login.ok"))
        XCTAssertEqual(h.snapshot.externalId, "1001")
    }

    func test_loginBeforeToken_linksAfterRegistration() {
        let h = Harness()
        h.initialize()
        h.login(customer: "cust_a")
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertTrue(h.snapshot.isLoggedIn)
        XCTAssertTrue(h.logs.contains("login.queued"))
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.server.templates, ["register", "link"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
    }

    /// The app logs in at every launch while signed in: a device the server linked to that customer sends nothing.
    func test_theNextLaunchsLogin_ofTheLinkedCustomer_sendsNothing() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        let next = h.relaunch()
        next.initialize()
        next.login(customer: "cust_a")
        next.sendToken()
        next.advance(2)
        XCTAssertEqual(next.server.requests("link").count, 1)
        XCTAssertTrue(next.logs.contains("login.skipped_same"))
        XCTAssertTrue(next.snapshot.isLoggedIn)
        XCTAssertEqual(next.snapshot.externalId, "cust_a")
    }

    /// A launch login whose link waits from the previous launch keeps it, and it goes with this launch's token.
    func test_aLinkPendingFromThePreviousLaunch_goesWithTheLaunchLoginsToken() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        h.login(customer: "cust_a")
        h.advance(3)
        let links = h.server.requests("link").count
        let next = h.relaunch()
        next.server.clearScripts()
        next.login(customer: "cust_a")
        next.initialize()
        next.advance(3)
        XCTAssertEqual(next.server.requests("link").count, links + 1)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_a")
        XCTAssertFalse(next.logs.contains("identity.token_needed"))
    }

    /// The token is kept in memory only: a link left from the previous launch without the launch's login is dropped,
    /// the tags no longer wait for it, and the app's next login links the device.
    func test_aLinkPendingFromThePreviousLaunch_withoutAToken_isDropped_andTheNextLoginLinks() {
        let h = Harness()
        h.registered()
        h.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(12)
        XCTAssertEqual(next.logs.count("identity.token_needed"), 1)
        XCTAssertEqual(next.server.requests("tags").count, 1, "the tags no longer wait")
        XCTAssertTrue(next.snapshot.isLoggedIn, "desired stays customer until the app calls logout()")
        XCTAssertEqual(next.snapshot.externalId, "cust_a")
        next.login(customer: "cust_a")
        next.advance(2)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_a")
    }

    func test_logout_sendsTheUnlink_deviceAuthenticated_withAnEmptyBody() throws {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.logout()
        XCTAssertFalse(h.snapshot.isLoggedIn)
        XCTAssertNil(h.snapshot.externalId)
        h.advance(2)
        let unlink = try XCTUnwrap(h.server.requests("unlink").first)
        XCTAssertEqual(unlink.method, "POST")
        XCTAssertEqual(String(data: unlink.body, encoding: .utf8), "{}")
        XCTAssertEqual(unlink.headers["authorization"]?.hasPrefix("Device "), true, "device-authenticated only")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertTrue(h.logs.contains("logout.ok"))
        XCTAssertEqual(h.server.requests("register").count, 1, "the device stays registered")
    }

    /// Offline at sign-out: the unlink is saved and retried until the server answers it, across a relaunch too.
    func test_logout_isSavedAndRetried_offlineAndAcrossARelaunch() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(30)
        XCTAssertGreaterThanOrEqual(h.server.requests("unlink").count, 1)
        XCTAssertEqual(h.identityOps().map { $0["kind"] as? String }, ["logout"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a", "not unlinked yet")
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(3)
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
        XCTAssertTrue(next.identityOps().isEmpty)
        XCTAssertTrue(next.logs.contains("logout.ok"))
    }

    /// Signed in, `logout()` clears the device's tags, then unlinks it; the next launch's logout is free.
    func test_signedInLogout_clearsTheTagsBeforeTheUnlink_thenTheNextLaunchLogoutIsFree() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1", "b": "2"]))
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1", "b": "2"])
        let before = h.server.requests.count
        h.logout()
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        h.advance(2)
        let sent = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "unlink"], "the tags go before the unlink")
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["remove": ["a", "b"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        let count = h.server.requests.count
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, count)
        XCTAssertTrue(next.logs.contains("logout.skipped"))
    }

    func test_logoutWithoutLink_needsNoNetwork() {
        let h = Harness()
        h.registered()
        h.logout()
        h.advance(30)
        XCTAssertEqual(h.server.templates, ["register"])
        XCTAssertTrue(h.logs.contains("logout.skipped"))
    }

    /// A reinstall keeps the Keychain, not the files: the launch logout clears the tags the previous install left,
    /// which only the server's answer names, then unlinks the link it left.
    func test_aReinstallsLaunchLogout_clearsThePreviousInstallsTags_andUnlinks() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        try? FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.sendToken()
        let before = next.server.requests.count
        next.advance(2)
        let sent = next.server.requests.dropFirst(before).filter { $0.template != "update" }
        XCTAssertEqual(sent.map(\.template), ["tags", "tags", "unlink"])
        XCTAssertEqual(sent.first.flatMap { String(data: $0.body, encoding: .utf8) }, "{}",
                       "no key is known: the answer names the keys the server holds")
        XCTAssertEqual(sent.dropFirst().first?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
    }

    /// The app signed out while SallaPush was not initialized: the next launch's logout unlinks the device.
    func test_logoutMissedWhileUninitialized_nextLaunchUnlinks() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.advance(2)
        XCTAssertEqual(next.server.requests("unlink").count, 1)
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
    }

    /// A logout queued before registration says so, and the registration answer, a new row with no
    /// link and no tags, settles it (DEBUG `logout.skipped`).
    func test_freshInstallLaunchLogout_isQueued_thenSettledByTheRegistration() throws {
        let h = Harness()
        h.initialize()
        h.logout()
        let queued = try XCTUnwrap(h.logs.all.first { $0.code == "logout.queued" })
        XCTAssertEqual(queued.message, "Logout queued until this device is registered; the registration answer settles "
                       + "whether it is still needed.")
        h.sendToken()
        h.advance(30)
        XCTAssertEqual(h.server.templates, ["register"])
        let skipped = try XCTUnwrap(h.logs.all.last { $0.code == "logout.skipped" })
        XCTAssertEqual(skipped.message, "This device is registered without a link or tags to clear; the queued logout needs "
                       + "no request.")
        XCTAssertEqual(skipped.level, .debug)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// An external id must be 1-128 characters (UTF-16 units, as push-service counts them) after trimming, and the
    /// token 1-4,096: anything else is ignored on the caller thread, sends nothing and reports no login failure.
    func test_invalidArguments_areIgnoredOnTheCallerThread() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "", token: "eyJ.x")
        h.login(externalId: " \n", token: "eyJ.x")
        h.login(externalId: String(repeating: "1", count: 129), token: "eyJ.x")
        h.login(externalId: String(repeating: "😀", count: 65), token: "eyJ.x")
        h.login(externalId: "cust_a", token: "")
        h.login(externalId: "cust_a", token: " \t ")
        h.login(externalId: "cust_a", token: String(repeating: "a", count: 4_097))
        h.advance(2)
        XCTAssertTrue(h.server.requests("link").isEmpty)
        XCTAssertTrue(failures.failures.current.isEmpty, "push-service refused nothing")
        XCTAssertEqual(h.logs.all.filter { $0.code == "api.invalid_argument" && $0.message.hasPrefix("login ignored") }.count, 7)
        XCTAssertFalse(h.snapshot.isLoggedIn)
        XCTAssertNil(h.snapshot.externalId)
        let longest = String(repeating: "😀", count: 64)
        h.login(customer: longest)
        h.advance(2)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, longest)
    }

    /// A `403 invalid_identity_token`: reported, never sent again; the app's session decides, and a fresh token links.
    func test_aRejectedIdentityToken_isReported_andNotSentAgain() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.advance(600)
        XCTAssertEqual(h.server.requests("link").count, 1, "no retry")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        XCTAssertEqual(h.logs.all.first { $0.code == "login.rejected" }?.level, .warn)
        XCTAssertTrue(h.identityOps().isEmpty)
        XCTAssertTrue(h.snapshot.isLoggedIn, "the app's session decides")
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        h.login(customer: "cust_a")
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
    }

    /// A `400 invalid_request`: reported as `.invalidRequest`, never sent again.
    func test_anInvalidRequest_isReported_andNotSentAgain() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link") { _ in FakeServer.error(400, "invalid_request") }
        h.login(customer: "cust_a")
        h.advance(2)
        h.advance(600)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(failures.failures.current, [.invalidRequest])
        XCTAssertEqual(h.logs.all.first { $0.code == "identity.client_error" }?.level, .error)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A 403 without push-service's error code (a proxy's, an edge's) is no answer of push-service: retried, nothing
    /// reported.
    func test_a403WithoutACode_isRetried_andReportsNothing() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link") { _ in .json(403, ["title": "blocked"], [:]) }
        h.login(customer: "cust_a")
        h.advance(2)
        h.advance(120)
        XCTAssertEqual(h.server.requests("link").count, 2)
        XCTAssertTrue(failures.failures.current.isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
    }

    /// The app passed a newer token while the link was on the wire: the 403 of the older token sends the link again
    /// with the newer one, and reports nothing.
    func test_aRejectedTokenReplacedMeanwhile_isSentAgainWithTheNewerToken() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        h.login(customer: "cust_a")
        XCTAssertTrue(h.logs.all.contains { $0.code == "login.queued" && $0.message.hasPrefix("Login already queued") })
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertEqual(h.server.requests("link").map { $0.json["identity_token"] as? String }, ["eyJ.expired", "eyJ.cust_a"])
        XCTAssertTrue(failures.failures.current.isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
    }

    /// The identity token reaches the link's body and nothing else: no file, no log line.
    func test_theIdentityToken_isNeverStoredOrLogged() throws {
        let h = Harness()
        let token = "v4.public.SECRET-identity-token"
        h.server.customers = { $0 == token ? .linked("1001") : .rejected }
        h.registered()
        h.server.script("link") { _ in .failure(.timeout) }
        h.login(externalId: "1001", token: token)
        h.advance(60)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "1001")
        for name in ["identity.json", "state.json", "events.json"] {
            let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/\(name)")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("SECRET"), name)
        }
        XCTAssertFalse(h.keychainAccess.allValues.contains { (String(bytes: $0, encoding: .utf8) ?? "").contains("SECRET") })
        XCTAssertFalse(h.logs.all.contains { $0.message.contains("SECRET") || $0.metadata.values.contains { $0.contains("SECRET") } })
        XCTAssertFalse(h.logs.console.contains { $0.contains("SECRET") })
    }

    func test_userObservers_seeLoginAndLogout() {
        let h = Harness()
        let changes = Locked<[(Bool, String?)]>([])
        let observation = h.runtime.observers.addUserHandler { change in
            changes.withLock { $0.append((change.current.isLoggedIn, change.current.externalId)) }
        }
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.logout()
        h.advance(2)
        let values = changes.current
        XCTAssertEqual(values.first?.0, true)
        XCTAssertEqual(values.first?.1, "cust_a")
        XCTAssertEqual(values.last?.0, false)
        XCTAssertNil(values.last?.1)
        observation.cancel()
    }

    /// push-service reports no link in a registration or update answer: a link removed outside SallaPush is not
    /// repaired by an update, and the next launch's login of the same customer is skipped as already linked.
    func test_noLinkIsReconciled_fromUpdateAnswers() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.advance(2)
        h.server.unlinkOutOfBand(h.deviceId)
        h.advance(86_401)
        h.send(.willEnterForeground)
        h.advance(3)
        XCTAssertEqual(h.server.requests("update").count, 1, "the daily refresh")
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(h.snapshot.externalId, "cust_a")
        XCTAssertFalse(h.logs.contains("identity.token_needed"))
    }
}

// MARK: - Account switch

extension IdentityTests {
    /// A login of another customer: the previous customer's tags leave the device before the new link (one request
    /// removing the keys the server holds), their unsent changes are dropped, and the new customer's own changes go after.
    func test_anAccountSwitch_clearsThePreviousCustomersTagsBeforeTheNewLink() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        h.submit(.addTags(["a2": "unsent"]))
        let before = h.server.requests.count
        h.login(customer: "cust_b")
        XCTAssertTrue(h.snapshot.tags.isEmpty, "the getters drop them at once")
        XCTAssertEqual(h.snapshot.externalId, "cust_b")
        h.submit(.addTags(["b": "1"]))
        h.advance(12)
        let sent = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "link", "tags"])
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary,
                       "the server is known to hold only a; a2 never left the device")
        XCTAssertEqual(sent.last?.json as NSDictionary?, ["add": ["b": "1"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["b": "1"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.snapshot.tags, ["b": "1"])
        XCTAssertTrue(h.logs.contains("login.switched"))
    }

    /// A guest who signs in keeps the tags set while signed out: no tag is cleared.
    func test_aGuestsLogin_keepsTheTags() {
        let h = Harness()
        h.registered()
        h.logout()
        h.submit(.addTags(["g": "1"]))
        h.advance(12)
        h.login(customer: "cust_a")
        h.advance(2)
        XCTAssertEqual(h.server.templates.filter { $0 != "update" }, ["register", "tags", "link"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["g": "1"])
        XCTAssertEqual(h.snapshot.tags, ["g": "1"])
        XCTAssertFalse(h.logs.contains("login.switched"))
    }

    /// With `clearTagsOnLogout` off, a switch keeps the tags, on the device and in the getters.
    func test_withClearTagsOnLogoutOff_aSwitchKeepsTheTags() {
        let h = Harness()
        h.registered { $0.clearTagsOnLogout = false }
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        h.login(customer: "cust_b")
        h.advance(2)
        XCTAssertEqual(h.server.templates.filter { $0 != "update" }, ["register", "link", "tags", "link"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        XCTAssertEqual(h.snapshot.tags, ["a": "1"])
    }

    /// B's switching login, its tags not cleared yet, is replaced by C's: C's link clears what B's had still to clear.
    func test_aSwitchReplacedBeforeItWent_stillClearsThePreviousCustomersTags() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let before = h.server.requests.count
        h.login(customer: "cust_b")
        h.login(customer: "cust_c")
        h.advance(2)
        let sent = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "link"])
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(sent.last?.json["external_id"] as? String, "cust_c")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
    }

    /// A logout made while a switching login's tags are being cleared: that login is never linked.
    func test_aLogoutDuringASwitchsTagClearing_neverLinksTheSwitchedCustomer() {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        h.server.script("tags") { _ in .hold }
        h.login(customer: "cust_b")
        h.advance(2)
        h.logout()
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertFalse(h.server.requests("link").contains { $0.json["external_id"] as? String == "cust_b" })
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
    }

    /// A link whose answer was lost may have linked the device. A relaunch with no token drops it, and keeps that on
    /// disk: a logout at a later launch still unlinks.
    func test_aLinkOfUnknownOutcome_droppedAtARelaunch_isStillUnlinkedByALaterLogout() {
        let h = Harness()
        h.registered()
        h.server.mutate(h.deviceId) { $0.externalId = "cust_a" }
        h.server.script("link", times: nil) { _ in .failure(.timeout) }
        h.login(customer: "cust_a")
        h.advance(2)
        let second = h.relaunch()
        second.server.clearScripts()
        second.initialize()
        second.advance(2)
        let third = second.relaunch()
        third.initialize()
        third.logout()
        third.advance(5)
        XCTAssertFalse(third.server.requests("unlink").isEmpty)
        XCTAssertNil(third.server.device(third.deviceId)?.externalId)
    }

    /// A refusal of a login the app already replaced (a logout made while the link was on the wire) is logged, and not
    /// reported to the login failure handlers.
    func test_aRefusalOfALoginTheAppAlreadyReplaced_isNotReported() {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.server.script("link") { _ in .hold }
        h.login(customer: "cust_a")
        h.advance(2)
        h.logout()
        h.server.releaseHeld(FakeServer.error(403, "invalid_identity_token"))
        h.advance(5)
        XCTAssertTrue(h.logs.contains("login.rejected"))
        XCTAssertTrue(failures.failures.current.isEmpty)
    }

    /// A login made before the device's first registration logs no account switch and sends no tag clearing: the new
    /// row holds nothing.
    func test_aLoginBeforeTheFirstRegistration_logsNoSwitch_andClearsNothing() {
        let h = Harness()
        h.initialize()
        h.login(customer: "cust_a")
        h.sendToken()
        h.advance(5)
        XCTAssertFalse(h.logs.contains("login.switched"))
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
    }

    /// The raw values of an earlier version's removed failures are never reused.
    func test_loginFailureRawValues_neverReuseRemovedOnes() {
        XCTAssertEqual(SallaPushLoginFailure.tokenRejected.rawValue, 0)
        XCTAssertEqual(SallaPushLoginFailure.invalidRequest.rawValue, 3)
    }
}
