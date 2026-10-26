import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// `clearTagsOnLogout` (default true) on push-service's tags route: before the unlink of a logout, and
/// before the link of another customer, one `PATCH` removes every tag key SallaPush holds; when its answer still names
/// tags SallaPush did not know of, one more removes them. SallaPush's own copy of the tags goes at the call.
final class ClearTagsOnLogoutTests: XCTestCase {
    /// Customer A signed in with tags on the server.
    private func signedInWithTags(_ h: Harness, _ tags: [String: String] = ["a": "1", "b": "2"]) {
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(tags))
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, tags)
    }

    /// One request removes every key SallaPush holds, sent and unsent, before the unlink.
    func test_aLogout_removesEveryKeySallaPushHolds_inOneRequest_beforeTheUnlink() {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags", times: nil) { _ in .failure(.network("offline")) }
        h.submit(.addTags(["c": "3"]))
        h.submit(.removeTags(["b"]))
        h.advance(11)
        h.server.clearScripts()
        let before = h.server.requests.count
        h.logout()
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        h.advance(30)
        let sent = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "unlink"])
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["remove": ["a", "b", "c"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// A reinstall keeps the Keychain, not the files. Its signed-out launch clears A's tags, which
    /// only the server's answer names, and unlinks A, so customer B's login finds none of them.
    func test_theReinstallsLaunchLogout_clearsThePreviousCustomersTags_andTheNextCustomerGetsNone() throws {
        let h = Harness()
        signedInWithTags(h)
        let deviceId = try XCTUnwrap(h.deviceId)
        try FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.sendToken()
        next.advance(5)
        XCTAssertEqual(next.server.device(deviceId)?.tags, [:])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        next.login(customer: "cust_b")
        next.advance(3)
        XCTAssertEqual(next.server.device(deviceId)?.externalId, "cust_b")
        XCTAssertEqual(next.server.device(deviceId)?.tags, [:])
        XCTAssertTrue(next.snapshot.tags.isEmpty)
    }

    /// Tags SallaPush never knew of (set on the server behind its back): the first answer names them and one more request
    /// removes them; a server that still answers with tags gets no third clearing request, only the tags request that
    /// follows the unlink, and no more.
    func test_tagsSallaPushDidNotKnowOf_goWithOneMoreRequest_andNoMore() throws {
        let h = Harness()
        signedInWithTags(h, ["a": "1"])
        h.server.mutate(h.deviceId) { $0.tags["x"] = "elsewhere" }
        let before = h.server.requests.count
        h.logout()
        h.advance(5)
        let sent = Array(h.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "tags", "unlink"])
        XCTAssertEqual(sent.prefix(2).map { $0.json as NSDictionary }, [["remove": ["a"]], ["remove": ["x"]]] as [NSDictionary])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])

        let stubborn = Harness()
        signedInWithTags(stubborn, ["a": "1"])
        stubborn.server.script("tags", times: nil) { _ in .json(200, ["tags": ["x": "stays"]], [:]) }
        let count = stubborn.server.requests.count
        stubborn.logout()
        stubborn.advance(60)
        XCTAssertEqual(stubborn.server.requests.dropFirst(count).map(\.template), ["tags", "tags", "unlink", "tags"])
    }

    /// A tag clearing the network interrupts is retried before the unlink: the order never changes.
    func test_anInterruptedTagClearing_isRetried_beforeTheUnlink() {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags", times: 2) { _ in .failure(.network("offline")) }
        let before = h.server.requests.count
        h.logout()
        h.advance(30)
        let sent = h.server.requests.dropFirst(before).map(\.template)
        XCTAssertEqual(sent, ["tags", "tags", "tags", "unlink"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
    }

    /// A tag clearing push-service refuses never holds the unlink back.
    func test_aRefusedTagClearing_neverHoldsTheUnlinkBack() throws {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags") { _ in FakeServer.error(400, "invalid_request") }
        h.logout()
        h.advance(5)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        let refused = try XCTUnwrap(h.logs.all.first { $0.code == "net.client_error" })
        XCTAssertTrue(refused.message.hasSuffix("the device's tags were not cleared."), refused.message)
        XCTAssertTrue(h.identityOps().isEmpty)
    }

    /// A logout left to a drain-only engine (the next launch runs another app id) still clears the tags before the
    /// unlink.
    func test_aDrainOnlyEngine_clearsTheTagsBeforeTheUnlink() throws {
        let h = Harness()
        signedInWithTags(h)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("tags", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        let before = next.server.requests.count
        next.initialize("st_43_ios")
        next.advance(5)
        XCTAssertTrue(next.logs.contains("init.drain_started"))
        let drained = next.server.requests.dropFirst(before).filter { $0.deviceId == deviceId }
        XCTAssertEqual(drained.map(\.template), ["tags", "unlink"])
        XCTAssertEqual(drained.first?.json as NSDictionary?, ["remove": ["a", "b"]] as NSDictionary)
        XCTAssertEqual(next.server.device(deviceId)?.tags, [:])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        XCTAssertTrue(next.identityOps().isEmpty)
    }

    /// With `clearTagsOnLogout` off, a logout only unlinks: the device and the getters keep the tags.
    func test_withClearTagsOnLogoutOff_theLogoutKeepsTheTags() {
        let h = Harness()
        h.registered { $0.clearTagsOnLogout = false }
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let before = h.server.requests.count
        h.logout()
        h.advance(5)
        XCTAssertEqual(h.server.requests.dropFirst(before).map(\.template), ["unlink"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        XCTAssertEqual(h.snapshot.tags, ["a": "1"])
    }

    /// The tag mirror is no longer what the server holds while a logout that clears the tags is queued: an add of the
    /// value the mirror held is still sent, after the clearing removed it.
    func test_anAddOfTheValueTheServerHeld_isStillSent_whileALogoutThatClearsTheTagsIsQueued() {
        let h = Harness()
        signedInWithTags(h, ["a": "1"])
        h.server.script("tags") { _ in .hold }
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1, "the clearing is on the wire")
        h.submit(.addTags(["a": "1"]))
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertEqual(h.server.requests("tags").suffix(2).map { $0.json as NSDictionary },
                       [["remove": ["a"]], ["add": ["a": "1"]]] as [NSDictionary])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        XCTAssertEqual(h.snapshot.tags, ["a": "1"])
    }

    /// A logout queued while `clearTagsOnLogout` was off (an earlier launch's configuration) does not cover a logout made
    /// with it on: that logout clears the tags, then unlinks, and replaces the unsent one (its 429 applied nothing).
    func test_aPendingLogoutThatKeepsTheTags_doesNotCoverALogoutThatClearsThem() {
        let h = Harness()
        h.registered { $0.clearTagsOnLogout = false }
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        h.server.script("unlink", times: nil) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "3600"]) }
        h.logout()
        h.advance(3)
        XCTAssertEqual(h.identityOps().map { $0["clear_tags"] as? Bool }, [false])
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.logout()
        XCTAssertEqual(next.identityOps().map { $0["clear_tags"] as? Bool }, [true])
        next.advance(5)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
        XCTAssertTrue(next.identityOps().isEmpty)
    }

    /// A reinstall keeps the Keychain, not the files. A login at launch with no logout before it clears the tags the
    /// previous install left, which only the server's answer names, and keeps those this launch set.
    func test_theReinstallsFirstLogin_clearsThePreviousInstallsTags_andKeepsThisLaunchs() throws {
        let h = Harness()
        signedInWithTags(h)
        let deviceId = try XCTUnwrap(h.deviceId)
        try FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["c": "3"]))
        next.login(customer: "cust_b")
        next.sendToken()
        next.advance(15)
        XCTAssertEqual(next.server.device(deviceId)?.externalId, "cust_b")
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["c": "3"])
        XCTAssertEqual(next.snapshot.tags, ["c": "3"])
        XCTAssertTrue(next.logs.contains("login.switched"))
    }

    /// Customer A's row holds tags, and consent was withdrawn while the network was down, until the withdrawal's retries
    /// ran out: the files forget A's id and tags, while the row keeps both. Returns the next launch, with consent given.
    private func relaunchAfterAWithdrawalThatReachedNoServer(_ h: Harness, clearTagsOnLogout: Bool = true) -> Harness {
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered { $0.clearTagsOnLogout = clearTagsOnLogout }
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1", "b": "2"]))
        h.advance(12)
        for route in ["update", "tags", "unlink"] {
            h.server.script(route, times: nil) { _ in .failure(.network("offline")) }
        }
        h.runtime.setConsentGiven(false)
        h.advance(3_600)
        XCTAssertTrue(h.logs.contains("consent.revoked"))
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1", "b": "2"])
        let next = h.relaunch()
        next.server.clearScripts()
        next.runtime.setConsentRequired(true)
        next.initialize { $0.clearTagsOnLogout = clearTagsOnLogout }
        next.runtime.setConsentGiven(true)
        next.advance(5)
        XCTAssertTrue(next.snapshot.isLoggedIn)
        XCTAssertNil(next.snapshot.externalId, "the withdrawal forgot the customer's id")
        return next
    }

    /// The next login after such a withdrawal can't be told from another customer's: it is an account switch, and the
    /// tags only the server's answer names leave the row before the link.
    func test_aLoginAfterAWithdrawalThatReachedNoServer_clearsTheTagsTheRowKept_beforeTheLink() throws {
        let h = Harness()
        let next = relaunchAfterAWithdrawalThatReachedNoServer(h)
        let deviceId = try XCTUnwrap(next.deviceId)
        let before = next.server.requests.count
        next.login(customer: "cust_b")
        next.advance(15)
        let sent = Array(next.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "tags", "link"])
        XCTAssertEqual(sent.dropFirst().first?.json as NSDictionary?, ["remove": ["a", "b"]] as NSDictionary,
                       "the keys the first answer named")
        XCTAssertEqual(next.server.device(deviceId)?.tags, [:])
        XCTAssertEqual(next.server.device(deviceId)?.externalId, "cust_b")
        XCTAssertTrue(next.snapshot.tags.isEmpty)
        XCTAssertEqual(next.logs.all.first { $0.code == "login.switched" }?.message,
                       "The previous customer's id is unknown (an upgrade from an earlier SallaPush version, or a "
                           + "consent withdrawal), so this login counts as an account switch; the previous customer's "
                           + "tags are cleared before the new customer is linked.")
    }

    /// With `clearTagsOnLogout` off, that login keeps the tags, and says so.
    func test_withClearTagsOnLogoutOff_aLoginAfterAWithdrawalThatReachedNoServer_keepsTheTags() throws {
        let h = Harness()
        let next = relaunchAfterAWithdrawalThatReachedNoServer(h, clearTagsOnLogout: false)
        let deviceId = try XCTUnwrap(next.deviceId)
        let before = next.server.requests.count
        next.login(customer: "cust_b")
        next.advance(15)
        XCTAssertEqual(next.server.requests.dropFirst(before).map(\.template), ["link"])
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["a": "1", "b": "2"])
        XCTAssertEqual(next.logs.all.first { $0.code == "login.switched" }?.message,
                       "The previous customer's id is unknown (an upgrade from an earlier SallaPush version, or a "
                           + "consent withdrawal), so this login counts as an account switch; this device keeps its "
                           + "tags (clearTagsOnLogout is off).")
    }

    /// A switch's tag clearing that hadn't gone when the app was killed still goes at the next launch, before the link:
    /// the next customer never gets the previous one's tags.
    func test_aSwitchsClearingThatHadNotGoneBeforeARelaunch_stillGoesBeforeTheNextLink() {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags", times: nil) { _ in .failure(.network("offline")) }
        h.login(customer: "cust_b")
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(5)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
        next.login(customer: "cust_b")
        next.advance(5)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
    }

    /// A crash between the two file writes of a logout (`state.json` saved, `identity.json` not) leaves an empty tag copy
    /// with `server_tags` some: the next logout still clears the tags, through the server's answer.
    func test_aCrashBetweenTheFileWritesOfALogout_stillClearsTheTagsAtTheNextLogout() throws {
        let h = Harness()
        signedInWithTags(h)
        let identityURL = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/identity.json")
        let beforeLogout = try Data(contentsOf: identityURL)
        h.server.script("tags", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(1)
        try beforeLogout.write(to: identityURL)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.logout()
        next.advance(5)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
    }

    /// A row SallaPush registered holds no earlier customer's tags: its first login clears nothing.
    func test_theFirstLoginOnANewRow_sendsNoTagClearing() {
        let h = Harness()
        h.registered()
        let before = h.server.requests.count
        h.login(customer: "cust_a")
        h.advance(5)
        let sent = h.server.requests.dropFirst(before).map(\.template)
        XCTAssertFalse(sent.contains("tags"), "\(sent)")
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertFalse(h.logs.contains("login.switched"))
    }

    /// A refused tag clearing of an account switch never holds the link back: the next tags request, after the link,
    /// removes the previous customer's tags.
    func test_aRefusedClearingOfASwitch_isFollowedByATagsRequestThatRemovesThePreviousCustomersTags() {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags", times: 1) { _ in FakeServer.error(400, "invalid_request") }
        h.login(customer: "cust_b")
        h.advance(15)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// A refused tag clearing of a logout never holds the unlink back: the next tags request, after the unlink, removes
    /// the tags, so the next customer gets none of them.
    func test_aRefusedClearingOfALogout_isFollowedByATagsRequest_andTheNextCustomerGetsNoneOfTheTags() {
        let h = Harness()
        signedInWithTags(h)
        h.server.script("tags", times: 1) { _ in FakeServer.error(400, "invalid_request") }
        h.logout()
        h.advance(15)
        XCTAssertNil(h.server.device(h.deviceId)?.externalId)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        h.login(customer: "cust_b")
        h.advance(5)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
    }

    /// A tag written by another writer between the clearing's two requests is still on the server after them: it is not
    /// the next customer's, the log doesn't call the tags cleared, and the next tags request removes it.
    func test_aTagWrittenBetweenTheClearingsTwoRequests_isNotTheNextCustomers_andIsRemovedNext() {
        let h = Harness()
        signedInWithTags(h, ["a": "1"])
        h.server.mutate(h.deviceId) { $0.tags["u"] = "elsewhere" }
        h.server.script("tags", times: nil) { _ in .hold }
        h.login(customer: "cust_b")
        h.advance(1)
        XCTAssertEqual(h.server.heldCount, 1, "the first clearing request is on the wire")
        h.server.releaseHeld()
        h.advance(1)
        XCTAssertEqual(h.server.heldCount, 1, "the second clearing request is on the wire")
        h.server.mutate(h.deviceId) { $0.tags["x"] = "late" }
        h.server.releaseHeld()
        h.advance(1)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["x": "late"])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        let flushed = h.logs.all.filter { $0.code == "tags.flushed" }.map(\.message)
        XCTAssertFalse(flushed.contains("Tags cleared before the new customer is linked."), "\(flushed)")
        XCTAssertTrue(flushed.contains { $0.hasPrefix("The server still holds 1 tag SallaPush could not clear") }, "\(flushed)")
        h.server.clearScripts()
        while h.server.heldCount > 0 { h.server.releaseHeld() }
        h.advance(15)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }
}
