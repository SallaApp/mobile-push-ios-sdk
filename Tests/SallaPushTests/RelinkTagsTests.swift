import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// A registration answer is a new device row: push-service gives it no link and no tags, and reports neither.
/// So after a re-registration (`401 invalid_device_secret`, `404 unknown_device`) SallaPush links the signed-in customer
/// again with the identity token in memory (without one, the app's next `login` call does), sends the tags it holds
/// again after that link, and drops what had nothing left to do on the new row: a queued logout, a tag clearing.
final class RelinkTagsTests: XCTestCase {
    /// Customer A is linked with a tag on the server; the row is purged.
    private func linkedThenPurged(_ h: Harness) throws -> String {
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["first_name": "Huda"]))
        h.advance(15)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(h.server.device(deviceId)?.externalId, "cust_a")
        XCTAssertEqual(h.server.device(deviceId)?.tags, ["first_name": "Huda"])
        h.server.purge(deviceId)
        return deviceId
    }

    func test_aPurgedRow_isLinkedAgainWithTheTokenInMemory_beforeItsTagsAreSentAgain() throws {
        let h = Harness()
        let purged = try linkedThenPurged(h)
        let before = h.server.requests.count
        h.submit(.addTags(["last_order": "a-123"]))
        h.advance(40)
        XCTAssertEqual(Array(h.server.templates.dropFirst(before)), ["tags", "register", "link", "tags"])
        let row = try XCTUnwrap(h.server.device(h.deviceId))
        XCTAssertNotEqual(row.id, purged)
        XCTAssertEqual(row.externalId, "cust_a")
        XCTAssertEqual(row.tags, ["first_name": "Huda", "last_order": "a-123"], "the tags SallaPush held, and the new change")
        XCTAssertEqual(h.server.requests("link").last?.json["identity_token"] as? String, "eyJ.cust_a")
        XCTAssertEqual(h.snapshot.tags, ["first_name": "Huda", "last_order": "a-123"])
        XCTAssertTrue(h.logs.contains("register.reregistering"))
    }

    /// `401 invalid_device_secret` registers again too, and links the customer again.
    func test_anInvalidSecret_registersAgain_andLinksTheCustomerAgain() throws {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1"]))
        h.advance(15)
        h.server.mutate(h.deviceId) { $0.secret = "rotated-elsewhere" }
        let before = h.server.requests.count
        h.submit(.addTags(["b": "2"]))
        h.advance(40)
        XCTAssertEqual(Array(h.server.templates.dropFirst(before)), ["tags", "register", "link", "tags"])
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1", "b": "2"])
    }

    /// The token is kept in memory only: after a relaunch without the launch's login, a purged row is not linked until
    /// the app's next login, which then links it; the tags still go to the new row.
    func test_aPurgedRow_withNoTokenInMemory_isLinkedByTheNextLogin() throws {
        let h = Harness()
        _ = try linkedThenPurged(h)
        let next = h.relaunch()
        next.initialize()
        next.submit(.setLanguage("en"))
        next.advance(15)
        XCTAssertTrue(next.server.requests("register").count >= 2, "registered again")
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["first_name": "Huda"])
        XCTAssertEqual(next.logs.count("identity.token_needed"), 1)
        XCTAssertTrue(next.snapshot.isLoggedIn)
        next.login(customer: "cust_a")
        next.advance(2)
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_a")
    }

    /// A token push-service rejected is forgotten: a later re-registration does not send it again.
    func test_aRejectedToken_isNotSentAgain_afterAReRegistration() throws {
        let h = Harness()
        let failures = FailureRecorder(h)
        h.registered()
        h.login(externalId: "cust_a", token: "eyJ.expired")
        h.advance(2)
        XCTAssertEqual(failures.failures.current, [.tokenRejected])
        h.server.purge(h.deviceId)
        h.submit(.setLanguage("en"))
        h.advance(15)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertEqual(h.server.requests("link").count, 1)
        XCTAssertEqual(h.logs.count("identity.token_needed"), 1)
    }

    /// A logout whose tag clearing finds the row purged: the new row has no link and no tags, so the logout is settled
    /// by the registration and nothing of A goes to the new row.
    func test_aLogoutQueuedWhenTheRowIsPurged_isSettledByTheRegistration() throws {
        let h = Harness()
        _ = try linkedThenPurged(h)
        let before = h.server.requests.count
        h.logout()
        h.advance(40)
        XCTAssertEqual(Array(h.server.templates.dropFirst(before)), ["tags", "register"])
        let row = try XCTUnwrap(h.server.device(h.deviceId))
        XCTAssertNil(row.externalId)
        XCTAssertEqual(row.tags, [:])
        XCTAssertTrue(h.identityOps().isEmpty)
        XCTAssertTrue(h.logs.all.contains { $0.code == "logout.skipped" && $0.message.hasPrefix("This device is registered") })
    }

    /// A's tag is on the server and A's next change is pending when the row is purged and the app
    /// switches to B. The switch's tag clearing finds the row purged; the new row has no tags, and B's link goes first:
    /// neither A's server tag nor A's pending change ever reaches B.
    func test_aPurgeDuringASwitch_neverGivesThePreviousCustomersTagsToTheNextCustomer() throws {
        let h = Harness()
        let purged = try linkedThenPurged(h)
        h.submit(.addTags(["last_order": "a-123"]))
        let before = h.server.requests.count
        h.login(customer: "cust_b")
        h.advance(40)
        XCTAssertEqual(Array(h.server.templates.dropFirst(before)), ["tags", "register", "link"])
        let row = try XCTUnwrap(h.server.device(h.deviceId))
        XCTAssertNotEqual(row.id, purged)
        XCTAssertEqual(row.externalId, "cust_b")
        XCTAssertEqual(row.tags, [:], "neither A's server tag nor A's pending change reaches B")
        XCTAssertTrue(h.snapshot.tags.isEmpty)
    }

    /// The new row holds no tags: a pending removal has nothing to remove there and is not sent.
    func test_aPendingRemoval_isNotSentToTheNewRow() throws {
        let h = Harness()
        _ = try linkedThenPurged(h)
        h.submit(.removeTags(["first_name"]))
        h.submit(.addTags(["plan": "gold"]))
        h.advance(40)
        let lastTags = try XCTUnwrap(h.server.requests("tags").last)
        XCTAssertEqual(lastTags.json as NSDictionary, ["add": ["plan": "gold"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.snapshot.tags, ["plan": "gold"])
    }

    /// A guest's tags go to the new row too; nothing is linked.
    func test_aGuestsPurgedRow_getsItsTagsBack() throws {
        let h = Harness()
        h.registered()
        h.logout()
        h.submit(.addTags(["g": "1"]))
        h.advance(15)
        h.server.purge(h.deviceId)
        h.submit(.addTags(["h": "2"]))
        h.advance(40)
        XCTAssertTrue(h.server.requests("link").isEmpty)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["g": "1", "h": "2"])
    }
}
