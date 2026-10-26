import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The tag rules of both SDKs (Android's `TagRules.addChangesNothing` and
/// `removeChangesNothing`). An add equal to the mirror sends nothing only while the mirror is the server's truth: the
/// device is registered, the last tags answer reported tags, no tags request is on the wire, and no queued logout or
/// login of another customer still clears the tags. A remove sends nothing only when the key is not in the mirror, the
/// registered row holds no tags, and no tags request is on the wire. A tags op that waits after a failure keeps its wait
/// for a change made meanwhile. The Android SDK follows the same rules.
final class TagRuleTests: XCTestCase {
    private func stateOps(_ h: Harness) -> [String] {
        (h.file("state.json")["ops"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
    }

    /// The engine's ops in memory: what the pump changes reaches the file with the next change.
    private func liveStateOps(_ h: Harness) -> [String] {
        guard let engine = h.engine else { return [] }
        return engine.queue.sync { engine.state.ops.map(\.kind.rawValue) }
    }

    private func pendingTags(_ h: Harness) -> (add: [String: Any], remove: [String: Any]) {
        let tags = h.file("state.json")["tags"] as? [String: Any] ?? [:]
        return (tags["pending_add"] as? [String: Any] ?? [:], tags["pending_remove"] as? [String: Any] ?? [:])
    }

    private func serverTags(_ h: Harness) -> String? {
        h.file("identity.json")["server_tags"] as? String
    }

    // MARK: - Changes that send nothing

    func test_addingTheValueTheServerHolds_sendsNothing_andDropsAPendingChangeOfTheKey() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold", "city": "riyadh"])
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertEqual(serverTags(h), "some")
        h.runtime.addTags(["plan": "gold", "city": "riyadh"])
        // A change of a key, then its value as the server holds it: the pending change goes, and nothing is sent.
        h.runtime.addTags(["plan": "silver"])
        h.runtime.addTags(["plan": "gold"])
        h.runtime.removeTags(["city"])
        h.runtime.addTags(["city": "riyadh"])
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertTrue(pendingTags(h).add.isEmpty)
        XCTAssertTrue(pendingTags(h).remove.isEmpty)
        XCTAssertFalse(stateOps(h).contains("tags"))
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold", "city": "riyadh"])
    }

    /// Nothing left to send: the tags op goes at once, also while another request is on the wire.
    func test_aChangeTakenBackWhileAnotherRequestIsOnTheWire_leavesNoTagsOpBehind() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.script("update", times: 1) { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.addTags(["plan": "silver"])
        h.runtime.addTags(["plan": "gold"])
        h.settle()
        XCTAssertFalse(stateOps(h).contains("tags"))
        h.server.releaseHeld()
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").count, 1)
    }

    /// A row registered fresh holds no tags at all.
    func test_removingATagTheServerCannotHold_sendsNothing() {
        let h = Harness()
        h.registered()
        XCTAssertEqual(serverTags(h), "none")
        h.runtime.removeTags(["promo"])
        h.runtime.removeTags(["a", "b"])
        h.runtime.addTags(["gone": ""])
        h.advance(30)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        XCTAssertTrue(pendingTags(h).remove.isEmpty)
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    func test_staticTagsSetAtEveryLaunch_costNoRequest() {
        let first = Harness()
        first.registered()
        let tags = ["store_theme": "dark", "platform": "ios"]
        first.runtime.addTags(tags)
        first.advance(11)
        XCTAssertEqual(first.server.requests("tags").count, 1)
        var launches = [first]
        for _ in 0..<3 {
            guard let previous = launches.last else { return }
            let before = previous.server.requests.count
            let next = previous.relaunch()
            launches.append(next)
            next.initialize()
            next.runtime.addTags(tags)
            next.sendToken()
            next.advance(60)
            next.send(.didEnterBackground)
            next.advance(1)
            XCTAssertEqual(next.server.requests.count, before, "\(next.server.templates)")
            XCTAssertEqual(next.snapshot.tags, tags)
        }
    }

    /// The same rule as the Android SDK.
    func test_tagChangesThatSendNothing_showTheSameTagsAtOnceAndOnceApplied() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold", "city": "riyadh"])
        h.advance(11)
        h.runtime.addTags(["plan": "gold", "city": "riyadh"])
        h.runtime.addTags(["plan": "silver"])
        h.runtime.addTags(["plan": "gold"])
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold", "city": "riyadh"], "right after the calls")
        h.settle()
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold", "city": "riyadh"], "once applied")
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").count, 1)
    }

    /// The same rule as the Android SDK.
    func test_removingTagsAFreshRowCannotHold_showsTheSameTagsAtOnceAndOnceApplied() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.runtime.removeTags(["plan"])
        h.runtime.removeTags(["never_set", "PROMO"])
        XCTAssertTrue(h.snapshot.tags.isEmpty, "right after the calls")
        h.settle()
        XCTAssertTrue(h.snapshot.tags.isEmpty, "once applied")
        h.advance(30)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
    }

    // MARK: - Guards: the change is still sent

    /// Until the switch's tag clearing is answered, the mirror is A's tags, not what the server will hold for B.
    func test_theSameValueAsThePreviousCustomers_setForTheNextCustomerDuringTheSwitch_isStillSent() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.runtime.addTags(["tier": "gold"])
        h.advance(15)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["tier": "gold"])
        h.server.script("tags", times: 1) { _ in .hold }
        h.login("customer.token.b")
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1, "the switch's tag clearing is on the wire")
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["tier"]] as NSDictionary)
        h.runtime.addTags(["tier": "gold"])
        h.settle()
        // The model answers the clearing, which deleted A's tag.
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertEqual(h.server.requests("tags").last?.json["add"] as? [String: String], ["tier": "gold"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["tier": "gold"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.snapshot.tags, ["tier": "gold"])
    }

    /// The server held no tags when the request left, but it will hold this one: the remove must follow.
    func test_aRemoveOfATagThatARequestOnTheWireAdds_isStillSent() {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: 1) { _ in .hold }
        h.runtime.addTags(["promo": "spring"])
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.removeTags(["promo"])
        h.settle()
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertEqual(h.server.requests("tags").last?.json["remove"] as? [String], ["promo"])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// The mirror still says gold, but the request on the wire makes it silver: going back to gold must be sent.
    func test_anAddRevertingAValueThatARequestOnTheWireChanges_isStillSent() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.script("tags", times: 1) { _ in .hold }
        h.runtime.addTags(["plan": "silver"])
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.addTags(["plan": "gold"])
        h.settle()
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold"])
        XCTAssertEqual(h.server.requests("tags").count, 3)
    }

    /// The credentials were refused (`401 invalid_device_secret`): until the new registration is answered, the row the
    /// tags will reach is not known. It is a fresh row, which holds no tags.
    func test_theServersValue_setAgainWhileTheDeviceRegistersAgain_isStillSent() throws {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        XCTAssertEqual(serverTags(h), "some")
        let oldId = try XCTUnwrap(h.deviceId)
        h.server.mutate(oldId) { $0.secret = "refused" }
        h.server.script("register", times: 1) { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.addTags(["plan": "gold"])
        h.settle()
        h.server.releaseHeld()
        h.advance(15)
        let newId = try XCTUnwrap(h.deviceId)
        XCTAssertNotEqual(newId, oldId)
        XCTAssertEqual(h.server.requests("tags").count, 2)
        XCTAssertEqual(h.server.requests("tags").last?.json["add"] as? [String: String], ["plan": "gold"])
        XCTAssertEqual(h.server.device(newId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold"])
    }

    /// A registration answer is a new row, which holds no tags: a remove recorded while the device registers
    /// again has nothing to remove there and is not sent.
    func test_aRemoveWhileTheDeviceRegistersAgain_isNotSentToTheNewRow() throws {
        let h = Harness()
        h.registered()
        XCTAssertEqual(serverTags(h), "none")
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.mutate(deviceId) { $0.secret = "refused" }
        h.server.script("register", times: 1) { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.removeTags(["promo"])
        h.settle()
        h.server.releaseHeld()
        h.advance(15)
        XCTAssertNotEqual(h.deviceId, deviceId)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        XCTAssertEqual(serverTags(h), "none")
    }

    /// A link never changes the tags: while one waits for its retry after an answer that never came, an add of the
    /// value the server holds still sends nothing.
    func test_anAddWhileALinksOutcomeIsUnknown_sendsNothing() throws {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["tier": "gold"])
        h.advance(15)
        XCTAssertEqual(serverTags(h), "some")
        h.server.script("link", times: nil) { _ in .failure(.timeout) }
        h.login(customer: "cust_a")
        h.advance(2)
        h.runtime.addTags(["tier": "gold"])
        h.advance(15)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertTrue(pendingTags(h).add.isEmpty)
        XCTAssertEqual(h.snapshot.tags, ["tier": "gold"])
    }

    /// A tags request that failed in transit may have reached the server: what it holds is unknown until a tags answer
    /// says, so going back to the mirror's value is still sent (the rule a consent withdrawal follows for such a
    /// request, here in the normal flow).
    func test_anAddRevertingAChangeThatFailedInTransit_isStillSent() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.script("tags", times: 1) { _ in .failure(.timeout) }
        h.runtime.addTags(["plan": "silver"])
        h.advance(11)
        // The server applied the change before the answer was lost.
        h.server.mutate(h.deviceId) { $0.tags = ["plan": "silver"] }
        XCTAssertEqual(serverTags(h), "unknown")
        h.runtime.addTags(["plan": "gold"])
        h.advance(60)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold"])
        XCTAssertEqual(serverTags(h), "some")
    }

    // MARK: - Logout after a tags request without a usable answer

    /// The server's tags count as present unless they are known to be none: a tags request that failed in transit
    /// may have left tags, so a `logout()` clears them on an unlinked device too (and sends no unlink: the device is known
    /// to be unlinked). The app asserts a customer the server never linked (push-service rejected the identity token), so
    /// the identity is known: a launch logout of an unknown identity keeps this launch's tags instead
    /// (`UnknownIdentityLogoutTests`).
    func test_logoutAfterATagsRequestFailedInTransit_clearsTheTagsItMayHaveLeft() throws {
        let h = Harness()
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("tags", times: nil) { _ in .failure(.timeout) }
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.mutate(deviceId) { $0.tags = ["plan": "gold"] }
        h.server.clearScripts()
        h.logout()
        h.advance(3)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["plan"]] as NSDictionary)
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
        XCTAssertEqual(h.server.device(deviceId)?.tags, [:])
        XCTAssertEqual(serverTags(h), "none")
    }

    /// An answered error applied nothing, so the server's tags stay known as none and the logout of an unlinked device
    /// needs no request.
    func test_logoutAfterATagsRequestAnsweredWithAnError_needsNoRequest() {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        XCTAssertEqual(serverTags(h), "none")
        h.logout()
        h.advance(3)
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
        XCTAssertFalse(h.server.requests("tags").contains { $0.json["remove"] != nil })
        XCTAssertTrue(h.logs.contains("logout.skipped"))
    }

    // MARK: - A failed tags op keeps its wait

    /// Back to what the server holds (nothing left to send), then a new change: it waits for the 429 too (a
    /// trigger never shortens a 429 wait).
    func test_a429WaitOfTags_holdsForAChangeMadeAfterNothingWasLeftToSend() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.script("tags", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "120"]) }
        h.runtime.addTags(["plan": "silver"])
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").count, 2)
        h.runtime.addTags(["plan": "gold"])
        h.settle()
        XCTAssertTrue(pendingTags(h).add.isEmpty, "back to the value the server holds")
        XCTAssertEqual(stateOps(h), ["tags"], "the op waiting after the 429 is kept with nothing to send")
        h.runtime.addTags(["city": "riyadh"])
        h.send(.willEnterForeground)
        h.advance(60)
        XCTAssertEqual(h.server.requests("tags").count, 2)
        h.advance(70)
        XCTAssertEqual(h.server.requests("tags").count, 3)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold", "city": "riyadh"])
    }

    /// A tags op kept for its wait with nothing to send goes once the wait is over.
    func test_aWaitingTagsOpWithNothingToSend_goesWhenItsWaitEnds() {
        let h = Harness()
        h.registered()
        h.runtime.addTags(["plan": "gold"])
        h.advance(11)
        h.server.script("tags", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "120"]) }
        h.runtime.addTags(["plan": "silver"])
        h.advance(11)
        h.runtime.addTags(["plan": "gold"])
        h.advance(60)
        XCTAssertEqual(liveStateOps(h), ["tags"])
        h.advance(70)
        XCTAssertTrue(liveStateOps(h).isEmpty, "the wait is over and nothing is left to send")
        XCTAssertEqual(h.server.requests("tags").count, 2)
        h.runtime.addTags(["city": "riyadh"])
        h.advance(9)
        XCTAssertEqual(h.server.requests("tags").count, 2, "a later change waits for the usual 10 s again")
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").count, 3)
    }
}
