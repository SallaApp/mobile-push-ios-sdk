import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class TagsTests: XCTestCase {
    func test_normalisation_validation_andTruncation() throws {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["ADD_TO_CART": "1", " last_login ": "2", "first name": "x", "note": String(repeating: "و", count: 300)]))
        h.advance(11)
        let request = try XCTUnwrap(h.server.requests("tags").first)
        let add = try XCTUnwrap(request.json["add"] as? [String: String])
        XCTAssertEqual(Set(add.keys), ["add_to_cart", "last_login", "note"])
        XCTAssertEqual(add["note"]?.utf16.count, 255)
        XCTAssertTrue(h.logs.contains("tags.normalized"))
        XCTAssertTrue(h.logs.contains("tags.invalid_key"))
        XCTAssertTrue(h.logs.contains("tags.value_truncated"))
        XCTAssertTrue(h.logs.contains("tags.flushed"))
        XCTAssertEqual(h.snapshot.tags["add_to_cart"], "1")
    }

    func test_emptyValue_removesTheTag() {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        h.submit(.addTags(["a": ""]))
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").last?.json["remove"] as? [String], ["a"])
        XCTAssertNil(h.snapshot.tags["a"])
    }

    func test_limit_dropsExtraAdds() {
        let h = Harness()
        h.registered()
        var tags: [String: String] = [:]
        for index in 0..<105 { tags["k\(index)"] = "v" }
        h.submit(.addTags(tags))
        h.advance(11)
        XCTAssertEqual(h.snapshot.tags.count, 100)
        XCTAssertTrue(h.logs.contains("tags.limit"))
        XCTAssertEqual((h.server.requests("tags").first?.json["add"] as? [String: String])?.count, 100)
    }

    /// push-service counts its tags plus the added keys minus the removed ones, also an added key it already holds, so
    /// at 100 tags it refuses a changed value: SallaPush sends the change alone, which is refused again, and drops it.
    /// A removal in the same request makes room for the change.
    func test_atTheLimit_aChangedValueIsRefusedAndDropped_andGoesWithARemoval() {
        let h = Harness()
        h.registered()
        var tags: [String: String] = [:]
        for index in 0..<100 { tags["k\(index)"] = "v" }
        h.submit(.addTags(tags))
        h.advance(11)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, tags)
        let sent = h.server.requests("tags").count
        let flushed = h.logs.count("tags.flushed")
        h.submit(.addTags(["k0": "new"]))
        h.advance(11)
        h.advance(5)
        XCTAssertEqual(h.server.requests("tags").dropFirst(sent).map { $0.json as NSDictionary },
                       [["add": ["k0": "new"]], ["add": ["k0": "new"]]] as [NSDictionary], "merged, then alone")
        XCTAssertEqual(h.logs.count("tags.flushed"), flushed, "push-service refused both")
        XCTAssertEqual(h.logs.count("tags.rejected_key"), 1)
        let rejected = h.logs.all.first { $0.code == "tags.rejected_key" }
        XCTAssertEqual(rejected?.metadata["http_status"], "400")
        XCTAssertEqual(rejected?.metadata["error_code"], "invalid_request")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags["k0"], "v")
        XCTAssertEqual(h.snapshot.tags["k0"], "v")
        h.submit(.removeTags(["k1"]))
        h.submit(.addTags(["k0": "new"]))
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?,
                       ["add": ["k0": "new"], "remove": ["k1"]] as NSDictionary)
        tags["k0"] = "new"
        tags["k1"] = nil
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, tags, "100 + 1 - 1 tags: accepted")
        XCTAssertEqual(h.snapshot.tags, tags)
    }

    func test_debounce_tenSecondsInForeground_atOnceInBackground() {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        h.advance(9)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        h.submit(.addTags(["b": "2"]))
        h.send(.didEnterBackground)
        h.advance(0.5)
        XCTAssertEqual(h.server.requests("tags").count, 2)
    }

    /// A switch drops the previous customer's unsent change; one that may have reached the server (its request failed
    /// in transit) is cleared from the device before the new customer is linked.
    func test_switchDropsPreviousCustomersUnsentTags() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("tags", times: nil) { _ in .failure(.network("offline")) }
        h.submit(.addTags(["a_only": "1"]))
        h.advance(11)
        h.server.clearScripts()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.login("customer.token.b")
        h.submit(.addTags(["b_only": "2"]))
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").suffix(2).map { $0.json as NSDictionary },
                       [["remove": ["a_only"]], ["add": ["b_only": "2"]]] as [NSDictionary])
        XCTAssertTrue(h.logs.contains("login.switched"))
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["b_only": "2"])
    }

    /// An app may call login at sign-in and again from its own `update()`, within the 1 s
    /// debounce. The second call keeps the switching login, so the previous customer's unsent tag never reaches the new
    /// customer.
    func test_switchThenSameLoginAgain_withinTheDebounce_dropsThePreviousCustomersTags() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        h.runtime.addTags(["a_cart": "1"])
        h.runtime.login(externalId: "cust_b", identityToken: "customer.token.b")
        h.runtime.login(externalId: "cust_b", identityToken: "customer.token.b")
        h.runtime.addTags(["b_cart": "2"])
        h.settle()
        h.advance(30)
        XCTAssertEqual(h.server.requests("link").count, 2, "one link for A, one for B")
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["b_cart": "2"], "A's tag never reaches B")
        XCTAssertEqual(h.snapshot.tags, ["b_cart": "2"])
    }

    /// A switch drops the previous customer's change at once, before it is saved, so a
    /// relaunch before B's link went keeps only B's change, and the launch login(B) links B, then sends it.
    func test_switchInterruptedByRelaunch_launchLogin_keepsTheNewCustomersTag() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        h.submit(.addTags(["a_only": "1"]))
        h.login("customer.token.b")
        h.submit(.addTags(["b_only": "1"]))
        h.advance(3)
        let pending = (h.file("state.json")["tags"] as? [String: Any])?["pending_add"] as? [String: [String: Any]] ?? [:]
        XCTAssertEqual(Set(pending.keys), ["b_only"], "A's change was dropped at the switch")
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.login("customer.token.b")
        next.advance(30)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["b_only": "1"])
        XCTAssertEqual(next.snapshot.tags, ["b_only": "1"])
    }

    /// A refreshed token of the linked customer is no switch and sends nothing: their changes stay and go.
    func test_aRefreshedTokenOfTheLinkedCustomer_keepsTheirChanges() {
        let h = Harness()
        h.registered()
        h.login(externalId: "cust_same", token: "eyJ.cust_same")
        h.advance(3)
        h.submit(.addTags(["cart": "1"]))
        h.server.customers = { _ in .linked("cust_same") }
        h.login(externalId: "cust_same", token: "eyJ.cust_same.refreshed")
        h.advance(30)
        XCTAssertEqual(h.server.requests("link").count, 1, "already linked to that customer")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["cart": "1"])
        XCTAssertFalse(h.logs.contains("login.switched"))
    }

    /// A's link never went (its first attempt failed and the app switched before the retry): B's
    /// login still drops A's change, which never reaches B.
    func test_aSwitchAwayFromALoginThatNeverLinked_neverGivesItsTagChangesToTheNextCustomer() {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.logout()
        h.server.script("link", times: 1) { _ in FakeServer.error(503, "server_error") }
        h.login("customer.token.a")
        h.advance(1.5)
        XCTAssertEqual(h.identityOps().map { $0["kind"] as? String }, ["login"], "A's link waits for its retry")
        h.runtime.addTags(["first_name": "Huda"])
        h.login("customer.token.b")
        h.advance(40)
        XCTAssertEqual(h.server.requests("link").map { $0.json["identity_token"] as? String },
                       ["customer.token.a", "customer.token.b"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:], "A's change never reaches B")
        XCTAssertTrue(h.server.requests("tags").isEmpty)
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// A's change, made before a refreshed token of A and then B's login, never reaches B.
    func test_aRefreshedTokenBeforeASwitch_stillDropsThePreviousCustomersTagChanges() {
        let h = Harness()
        h.server.customers = { token in .linked(token.hasPrefix("customer.token.a") ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.runtime.addTags(["first_name": "Huda"])
        h.login("customer.token.a.refreshed")
        h.login("customer.token.b")
        h.advance(40)
        XCTAssertEqual(h.server.requests("link").map { $0.json["identity_token"] as? String },
                       ["customer.token.a", "customer.token.b"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:], "A's change, made before B's login, never reaches B")
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// `login.switched` says what a switch did to the tags.
    func test_switchLogLine_saysWhatHappenedToTheTags() throws {
        let h = Harness()
        h.registered { $0.clearTagsOnLogout = false }
        h.server.customers = { token in .linked(token == "token.a" ? "cust_a" : "cust_b") }
        h.login("token.a")
        h.submit(.addTags(["plan": "gold"]))
        h.advance(12)
        h.login("token.b")
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.logs.all.first { $0.code == "login.switched" }?.message,
                       "Account switched; this device keeps its tags (clearTagsOnLogout is off).")
        let cleared = Harness()
        cleared.registered()
        cleared.server.customers = { token in .linked(token == "token.a" ? "cust_a" : "cust_b") }
        cleared.login("token.a")
        cleared.submit(.addTags(["plan": "gold"]))
        cleared.advance(12)
        cleared.login("token.b")
        cleared.advance(3)
        XCTAssertEqual(cleared.logs.all.first { $0.code == "login.switched" }?.message,
                       "Account switched; the previous customer's tags are cleared before the new customer is linked.")
        let none = Harness()
        none.registered()
        none.server.customers = { token in .linked(token == "token.a" ? "cust_a" : "cust_b") }
        none.login("token.a")
        none.advance(3)
        none.login("token.b")
        none.advance(3)
        XCTAssertEqual(none.logs.all.first { $0.code == "login.switched" }?.message,
                       "Account switched; this device holds none of the previous customer's tags.")
    }

    func test_logout_clearsTheMirror_andTheServerTags() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
    }

    /// The answer of a tags request sent before logout() never restores the previous customer's tags,
    /// and adding the same tag again as a guest sends it.
    func test_tagsInFlightDuringLogout_mirrorCleared_reAddIsSent() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("tags") { _ in .hold }
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.server.releaseHeld()
        h.settle()
        XCTAssertEqual(h.snapshot.tags, [:], "the earlier request's answer does not repopulate the mirror")
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertEqual(h.snapshot.tags, [:])
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["add": ["a": "1"]] as NSDictionary,
                       "the same tag is sent again")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        XCTAssertEqual(h.snapshot.tags, ["a": "1"])
    }

    /// A tags request in flight may leave tags on the server, so a logout clears them, also when the device was never
    /// linked (here push-service rejected the identity token). With an unknown identity the launch logout would keep
    /// this launch's tags instead (`UnknownIdentityLogoutTests`).
    func test_logoutWhileTagsInFlight_clearsTheTagsThatRequestLeaves() {
        let h = Harness()
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("tags") { _ in .hold }
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        XCTAssertEqual(h.server.heldCount, 1)
        h.logout()
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, [:])
        XCTAssertEqual(h.snapshot.tags, [:])
    }

    func test_rejectedMergedOp_dropsOnlyTheOffendingKey() throws {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: nil) { request in
            let add = request.json["add"] as? [String: String] ?? [:]
            if add["bad"] != nil { return FakeServer.error(400, "invalid_request") }
            return .json(200, ["tags": add], [:])
        }
        h.submit(.addTags(["good": "1", "bad": "2", "also_good": "3"]))
        h.advance(11)
        h.advance(5)
        XCTAssertTrue(h.logs.contains("tags.rejected_key"))
        let accepted = h.server.requests("tags").filter { ($0.json["add"] as? [String: String])?["bad"] == nil }
        let sentKeys = Set(accepted.flatMap { ($0.json["add"] as? [String: String] ?? [:]).keys })
        XCTAssertEqual(sentKeys, ["good", "also_good"])
        XCTAssertNil(h.snapshot.tags["bad"])
    }

    /// Tag changes made while a tags request is on the wire wait for the foreground rate. A steady
    /// stream of changes (every 0.25 s for 60 s, one during each request) sends at most one request per 10 s.
    /// In the background a change goes at once, also right after a request.
    func test_tagChangesDuringFlight_waitForTheForegroundRate_andTheBackgroundFlushesAtOnce() {
        let h = Harness()
        h.registered()
        h.server.script("tags", times: nil) { _ in .hold }
        let start = h.clock.now()
        var sendTimes: [Double] = []
        for index in 0..<240 {
            h.runtime.addTags(["counter": "\(index)"])
            h.advance(0.25)
            guard h.server.heldCount > 0 else { continue }
            sendTimes.append(h.clock.now() - start)
            h.runtime.addTags(["counter": "during-\(index)"])
            h.settle()
            h.server.releaseHeld()
            h.settle()
        }
        XCTAssertGreaterThanOrEqual(sendTimes.count, 5, "\(sendTimes)")
        XCTAssertLessThanOrEqual(sendTimes.count, 7, "\(sendTimes)")
        for (earlier, later) in zip(sendTimes, sendTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, Engine.tagsDebounce - 0.001, "\(sendTimes)")
        }
        h.server.clearScripts()
        h.advance(30)
        h.send(.didEnterBackground)
        let before = h.server.requests("tags").count
        h.runtime.addTags(["counter": "background-1"])
        h.settle()
        h.runtime.addTags(["counter": "background-2"])
        h.settle()
        XCTAssertEqual(h.server.requests("tags").count, before + 2, "each went at once")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags["counter"], "background-2")
    }

    func test_rejectedTagValue_isDroppedLocally() {
        let h = Harness()
        h.registered()
        h.server.script("tags") { _ in FakeServer.error(400, "invalid_request") }
        h.submit(.addTags(["k": "v"]))
        h.advance(11)
        h.advance(3)
        XCTAssertGreaterThanOrEqual(h.server.requests("tags").count, 2)
        XCTAssertEqual(h.snapshot.tags["k"], "v")
    }
}
