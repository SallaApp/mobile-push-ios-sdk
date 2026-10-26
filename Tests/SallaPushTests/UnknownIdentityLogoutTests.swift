import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// While the identity is unknown (a first launch, a reinstall), the launch `logout()` keeps
/// the tags the app set earlier in that launch: they are the signed-out user's. Whatever an earlier install left goes,
/// with the tags request that clears the server's tags (`clearTagsOnLogout`), and a logout with a known identity still
/// drops every unsent tag change.
final class UnknownIdentityLogoutTests: XCTestCase {
    /// A fresh install's `initialize`, `addTags`, `logout()`. The tag is kept and sent once
    /// the device is registered, and the next launch's same calls cost no request.
    func test_aFirstLaunch_keepsTheTagSetBeforeTheLaunchLogout() throws {
        let h = Harness()
        h.initialize()
        h.submit(.addTags(["lang": "ar"]))
        h.logout()
        XCTAssertEqual(h.snapshot.tags, ["lang": "ar"])
        h.sendToken()
        h.advance(30)
        XCTAssertEqual(h.server.templates, ["register", "tags"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["lang": "ar"])
        XCTAssertEqual(h.snapshot.tags, ["lang": "ar"])
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["lang": "ar"]))
        next.logout()
        next.advance(30)
        XCTAssertEqual(next.server.templates, ["register", "tags"])
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
    }

    /// After a reinstall the previous customer's tags go (the server's answer names them) and the inherited link with
    /// them, and the tag the signed-out user set before the launch logout is sent after that.
    func test_aReinstall_keepsTheTagSetBeforeTheLaunchLogout_andClearsThePreviousInstalls() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.submit(.addTags(["first_name": "Huda"]))
        h.advance(15)
        let deviceId = try XCTUnwrap(h.deviceId)
        try FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["lang": "ar"]))
        next.logout()
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
        next.sendToken()
        let before = next.server.requests.count
        next.advance(30)
        let sent = Array(next.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "tags", "unlink", "update", "tags"])
        let tags = sent.filter { $0.template == "tags" }
        XCTAssertEqual(tags.first.flatMap { String(data: $0.body, encoding: .utf8) }, "{}",
                       "no key of the previous install is known: the answer names them")
        XCTAssertEqual(tags.dropFirst().map { $0.json as NSDictionary },
                       [["remove": ["first_name"]], ["add": ["lang": "ar"]]] as [NSDictionary])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["lang": "ar"])
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
    }

    /// A logout with a known identity still drops the unsent tag changes made before it, here the launch logout that
    /// repairs a sign-out SallaPush missed.
    func test_aKnownIdentitysLaunchLogout_stillDropsTheTagChangesMadeBeforeIt() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["lang": "ar"]))
        next.logout()
        XCTAssertTrue(next.snapshot.tags.isEmpty)
        next.advance(30)
        XCTAssertEqual(next.server.requests("unlink").count, 1)
        XCTAssertTrue(next.server.requests("tags").isEmpty, "the server held none of the customer's tags")
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, [:])
    }

    /// A launch logout that comes after the tags went: the tags this launch set stay on the server, and those an earlier
    /// install left go. Here that install was a guest with a tag.
    func test_tagsThisLaunchAlreadySent_areSentAgainAfterTheLogoutClearsTheServersTags() throws {
        let h = Harness()
        h.registered()
        h.logout()
        h.submit(.addTags(["first_name": "Huda"]))
        h.advance(12)
        let deviceId = try XCTUnwrap(h.deviceId)
        try FileManager.default.removeItem(at: h.root)
        let next = h.relaunch()
        next.initialize()
        next.sendToken()
        next.submit(.addTags(["lang": "ar"]))
        next.advance(12)
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["first_name": "Huda", "lang": "ar"])
        XCTAssertEqual(next.snapshot.tags, ["first_name": "Huda", "lang": "ar"], "the answer names every tag of the row")
        let before = next.server.requests.count
        next.logout()
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
        next.advance(15)
        XCTAssertEqual(next.server.requests.dropFirst(before).map(\.template), ["tags", "unlink"],
                       "the server is known to hold lang already; the link the earlier install may have left goes")
        XCTAssertEqual(next.server.requests("tags").last?.json as NSDictionary?, ["remove": ["first_name"]] as NSDictionary)
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["lang": "ar"])
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
    }

    /// No identity call yet, and a tag set at every launch that the server already holds sends nothing; the launch logout
    /// that finally comes keeps it, and needs no request at all: the server is known to hold that tag and no link.
    func test_aStaticTagTheServerHolds_isKeptByTheLaunchLogout() throws {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["lang": "ar"]))
        h.advance(12)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(h.server.device(deviceId)?.tags, ["lang": "ar"])
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["lang": "ar"]))
        next.advance(12)
        XCTAssertEqual(next.server.requests("tags").count, 1, "the server already holds it")
        next.logout()
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
        next.advance(15)
        XCTAssertEqual(next.server.requests.count, 2, "only the first launch's registration and tag")
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["lang": "ar"])
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
        XCTAssertTrue(next.logs.contains("logout.skipped"))
    }

    /// A tags request is on the wire at the launch logout: its answer never settles the tags this launch set, so they
    /// are sent again after the clearing, whose answer names what the server holds.
    func test_aTagsRequestOnTheWireAtTheLaunchLogout_neverSettlesTheTagsThisLaunchSet() {
        let h = Harness()
        h.registered()
        h.server.script("tags") { _ in .hold }
        h.submit(.addTags(["lang": "ar"]))
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertEqual(h.server.templates, ["register", "tags", "tags", "tags"], "the device was never linked: no unlink")
        XCTAssertEqual(h.server.requests("tags").dropFirst().first.flatMap { String(data: $0.body, encoding: .utf8) }, "{}")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["lang": "ar"])
        XCTAssertEqual(h.snapshot.tags, ["lang": "ar"])
    }

    /// A tag set and removed again in this launch is not brought back, and neither is a pending change an earlier
    /// launch left (here after a corrupt `identity.json` made the identity unknown again).
    func test_onlyTheTagsThisLaunchStillShows_areKept() throws {
        let h = Harness()
        h.registered()
        h.logout()
        h.server.script("tags", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.submit(.addTags(["earlier": "1"]))
        h.advance(12)
        XCTAssertNotNil((h.file("state.json")["tags"] as? [String: Any])?["pending_add"] as? [String: Any])
        let folder = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)")
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("identity.json"))
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.submit(.addTags(["lang": "ar", "plan": "gold"]))
        next.submit(.removeTags(["plan"]))
        XCTAssertEqual(next.snapshot.tags, ["earlier": "1", "lang": "ar"])
        next.logout()
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"])
        next.advance(30)
        XCTAssertEqual(next.server.requests("tags").last?.json["add"] as? [String: String], ["lang": "ar"])
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["lang": "ar"])
    }

    /// A tag this launch set that a tags answer no longer names is not brought back: the logout keeps what the getters
    /// show.
    func test_aTagTheServersAnswerNoLongerNames_isNotBroughtBack() {
        let h = Harness()
        h.registered()
        h.server.script("tags") { _ in .json(200, ["tags": ["plan": "gold"]], [:]) }
        h.submit(.addTags(["lang": "ar"]))
        h.advance(12)
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold"])
        h.submit(.addTags(["theme": "dark"]))
        h.logout()
        XCTAssertEqual(h.snapshot.tags, ["theme": "dark"])
        h.advance(15)
        XCTAssertEqual(h.server.requests("tags").suffix(2).map { $0.json as NSDictionary },
                       [["remove": ["plan"]], ["add": ["theme": "dark"]]] as [NSDictionary])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["theme": "dark"])
    }

    /// The getters anticipate the launch logout as the engine applies it: before `initialize`, where nothing is known
    /// and a launch logout keeps this launch's tag calls, and while the engine is busy; once the identity is known (after
    /// that logout), the next logout clears the tags.
    func test_theGettersAnticipateTheLaunchLogout() throws {
        let h = Harness()
        h.installAsShared()
        SallaPush.User.addTag(key: "lang", value: "ar")
        SallaPush.logout()
        XCTAssertEqual(SallaPush.User.getTags(), ["lang": "ar"], "before initialize")
        h.registered()
        h.advance(12)
        XCTAssertEqual(SallaPush.User.getTags(), ["lang": "ar"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["lang": "ar"])

        let busy = Harness()
        busy.installAsShared()
        busy.initialize()
        let engine = try XCTUnwrap(busy.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        SallaPush.User.addTag(key: "lang", value: "ar")
        SallaPush.logout()
        XCTAssertEqual(SallaPush.User.getTags(), ["lang": "ar"], "the engine has not handled the calls yet")
        SallaPush.User.addTag(key: "plan", value: "gold")
        SallaPush.logout()
        XCTAssertEqual(SallaPush.User.getTags(), [:], "the identity is known since the first logout")
        gate.signal()
        busy.settle()
        XCTAssertEqual(SallaPush.User.getTags(), [:])
    }

    /// An accepted login ends the prediction that a logout keeps this launch's tags.
    /// The identity is known from that login on, so the logout after it clears them, in the getters at once as in the
    /// engine, as on the Android SDK.
    func test_aLoginBeforeTheLaunchLogout_endsTheKeptTagsPrediction() throws {
        let busy = Harness()
        busy.installAsShared()
        busy.initialize()
        let engine = try XCTUnwrap(busy.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        SallaPush.User.addTag(key: "lang", value: "ar")
        SallaPush.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        SallaPush.logout()
        let predicted = SallaPush.User.getTags()
        gate.signal()
        busy.settle()
        XCTAssertEqual(predicted, [:], "predicted while the engine was busy")
        XCTAssertEqual(SallaPush.User.getTags(), [:], "applied")
    }
}
