import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The getters' anticipation of pending calls is bounded like the pre-init buffer, its
/// reads are O(1) in every phase, and before an engine takes the calls it shows exactly what the engine will apply.
final class GetterViewTests: XCTestCase {
    private var pending: (Harness) -> Int = { h in h.runtime.view.withLock { $0.pendingCount } }

    /// The average time of one public getter read, in seconds.
    private func averageRead(_ reads: Int = 2_000) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<reads {
            _ = SallaPush.User.getTags()
            _ = SallaPush.User.isLoggedIn
            _ = SallaPush.User.pushSubscription.optedIn
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 / Double(reads * 3)
    }

    /// 20,000 calls while consent is pending: the view keeps at most the calls the buffer keeps, and a read costs what a
    /// lock and a copy cost (an O(n) replay of 20,000 calls took milliseconds per read).
    func test_twentyThousandCallsWhileConsentIsPending_stayWithinTheBufferBound_andReadsAreConstantTime() {
        let h = Harness()
        h.installAsShared()
        h.runtime.setConsentRequired(true)
        h.initialize()
        for index in 0..<20_000 {
            SallaPush.User.addTag(key: "screen_\(index % 150)", value: "v\(index)")
            if index % 1_000 == 0 { SallaPush.logout() }
        }
        h.settle()
        XCTAssertLessThanOrEqual(pending(h), PreInitBuffer.maximumCalls)
        XCTAssertLessThan(averageRead(), 0.000_1, "a read never replays the calls")
        XCTAssertTrue(h.server.requests.isEmpty)
    }

    /// The same before `initialize`, and in the withdrawn (paused) phase.
    func test_twentyThousandCallsBeforeInitialize_andWhileWithdrawn_stayWithinTheBufferBound() {
        let h = Harness()
        h.installAsShared()
        for index in 0..<20_000 { SallaPush.User.addTag(key: "k\(index % 300)", value: "v\(index)") }
        XCTAssertLessThanOrEqual(pending(h), PreInitBuffer.maximumCalls)
        XCTAssertLessThan(averageRead(), 0.000_1)

        let withdrawn = Harness()
        withdrawn.installAsShared()
        withdrawn.runtime.setConsentRequired(true)
        withdrawn.runtime.setConsentGiven(true)
        withdrawn.registered()
        withdrawn.runtime.setConsentGiven(false)
        withdrawn.advance(5)
        for index in 0..<20_000 { SallaPush.User.addTag(key: "k\(index % 300)", value: "v\(index)") }
        withdrawn.settle()
        XCTAssertLessThanOrEqual(pending(withdrawn), PreInitBuffer.maximumCalls)
        XCTAssertLessThan(averageRead(), 0.000_1)
    }

    /// 150 distinct tag calls before `initialize`: the buffer keeps the newest 100, and the getters show exactly those
    /// before `initialize`, then after the engine applied and sent them.
    func test_gettersBeforeInitialize_equalWhatTheEngineApplies() throws {
        let h = Harness()
        h.installAsShared()
        for index in 0..<150 { SallaPush.User.addTag(key: "k\(index)", value: "v\(index)") }
        let before = SallaPush.User.getTags()
        let expected = Dictionary(uniqueKeysWithValues: (50..<150).map { ("k\($0)", "v\($0)") })
        XCTAssertEqual(before, expected)
        h.registered()
        h.advance(12)
        let sent = try XCTUnwrap(h.server.requests("tags").first?.json["add"] as? [String: String])
        XCTAssertEqual(sent, expected)
        XCTAssertEqual(SallaPush.User.getTags(), expected)
        XCTAssertEqual(pending(h), 0)
    }

    /// The same while consent is withdrawn: the calls made meanwhile are what the engine applies when consent is back.
    func test_gettersWhileWithdrawn_equalWhatTheEngineAppliesWhenConsentIsBack() throws {
        let h = Harness()
        h.installAsShared()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.runtime.setConsentGiven(false)
        h.advance(5)
        for index in 0..<150 { SallaPush.User.addTag(key: "k\(index)", value: "v\(index)") }
        SallaPush.User.removeTag("k149")
        let expected = Dictionary(uniqueKeysWithValues: (51..<149).map { ("k\($0)", "v\($0)") })
        XCTAssertEqual(SallaPush.User.getTags(), expected, "the oldest calls are dropped, as by the buffer")
        h.runtime.setConsentGiven(true)
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, expected)
        XCTAssertEqual(SallaPush.User.getTags(), expected)
    }

    /// A withdrawal forgets the customer's id, and consent given again in the same process names the customer of the
    /// identity token in memory before the calls made meanwhile run: a login of that customer keeps the tags set
    /// meanwhile, and a login of another one is an account switch, in the getters at once as in the engine.
    func test_aLoginWhileWithdrawn_keepsTheTagsOnlyForTheCustomerOfTheTokenInMemory() {
        let cases: [(customer: String, tags: [String: String])] = [("cust_a", ["x": "1"]), ("cust_b", [:])]
        for (customer, tags) in cases {
            let h = Harness()
            h.runtime.setConsentRequired(true)
            h.runtime.setConsentGiven(true)
            h.registered()
            h.login(customer: "cust_a")
            h.advance(3)
            h.runtime.setConsentGiven(false)
            h.advance(5)
            h.submit(.addTags(["x": "1"]))
            h.runtime.login(externalId: customer, identityToken: FakeServer.token(for: customer))
            XCTAssertEqual(h.snapshot.tags, tags, customer)
            h.runtime.setConsentGiven(true)
            h.advance(15)
            XCTAssertEqual(h.server.device(h.deviceId)?.tags, tags, customer)
            XCTAssertEqual(h.snapshot.tags, tags, customer)
            XCTAssertEqual(h.snapshot.externalId, customer)
        }
    }

    /// The buffer collapses identity calls: a logout removes the logins before it, and the getters follow, so a
    /// buffered login(A) then logout() then login(B) shows what the engine will do.
    func test_collapsedIdentityCalls_leaveTheView_withTheBuffer() {
        let h = Harness()
        h.installAsShared()
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        SallaPush.logout()
        SallaPush.logout()
        XCTAssertEqual(pending(h), 1, "one logout is kept")
        SallaPush.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        SallaPush.login(externalId: "cust_c", identityToken: FakeServer.token(for: "cust_c"))
        XCTAssertEqual(pending(h), 2, "the logout and the last login")
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.externalId, "cust_c")
        h.registered()
        h.advance(3)
        XCTAssertEqual(h.server.requests("link").map { $0.json["external_id"] as? String }, ["cust_c"])
        XCTAssertEqual(pending(h), 0)
    }

    /// A guest's launch logout is free and keeps the tags: the getters do not clear them in the meantime.
    /// A login of the same customer keeps the tags, and an account switch drops them, in the getters at once as in the
    /// engine.
    func test_theGettersFollowTheEnginesIdentityRules() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        h.logout()
        h.submit(.addTags(["a": "1"]))
        h.advance(12)
        let engine = try XCTUnwrap(h.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        SallaPush.logout()
        XCTAssertEqual(SallaPush.User.getTags(), ["a": "1"], "a guest's free logout keeps the tags")
        gate.signal()
        h.settle()
        XCTAssertEqual(SallaPush.User.getTags(), ["a": "1"])

        h.login(customer: "cust_a")
        h.submit(.addTags(["b": "2"]))
        h.advance(12)
        let blocked = DispatchSemaphore(value: 0)
        engine.queue.async { blocked.wait() }
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        XCTAssertEqual(SallaPush.User.getTags(), ["a": "1", "b": "2"], "the same customer keeps the tags")
        SallaPush.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        XCTAssertTrue(SallaPush.User.getTags().isEmpty, "an account switch drops them")
        XCTAssertEqual(SallaPush.User.externalId, "cust_b")
        blocked.signal()
        h.settle()
        XCTAssertTrue(SallaPush.User.getTags().isEmpty)
        XCTAssertEqual(SallaPush.User.externalId, "cust_b")
    }

    /// `identity.json` reset while `state.json` keeps the tags: the identity is unknown, so a login keeps only this
    /// launch's tags, in the getters at once as in the engine.
    func test_aLoginWhileTheIdentityIsUnknown_keepsOnlyThisLaunchsTags_inTheGettersAtOnce() throws {
        let h = Harness()
        h.registered()
        h.login(customer: "cust_a")
        h.submit(.addTags(["a": "1", "b": "2"]))
        h.advance(12)
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/identity.json"))
        let next = h.relaunch()
        next.installAsShared()
        next.initialize()
        next.submit(.addTags(["c": "3"]))
        XCTAssertEqual(SallaPush.User.getTags(), ["a": "1", "b": "2", "c": "3"])
        let engine = try XCTUnwrap(next.engine)
        let blocked = DispatchSemaphore(value: 0)
        engine.queue.async { blocked.wait() }
        SallaPush.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        XCTAssertEqual(SallaPush.User.getTags(), ["c": "3"], "only this launch's tags stay")
        blocked.signal()
        next.settle()
        XCTAssertEqual(SallaPush.User.getTags(), ["c": "3"])
    }

    /// The view is kept up to date incrementally; after any sequence of calls, drops and publishes it equals the engine's
    /// snapshot with the pending intents applied from scratch.
    func test_incrementalView_alwaysEqualsAFoldFromScratch() {
        var generator = SplitMix(seed: 0x5A11A)
        for _ in 0..<200 {
            var view = GetterView()
            var reference: [GetterView.Entry] = []
            var engine = EngineSnapshot()
            var sequence = 0
            for _ in 0..<60 {
                switch generator.next() % 10 {
                case 0..<6:
                    sequence += 1
                    let intent = Self.randomIntent(&generator)
                    view.append(sequence: sequence, intent: intent)
                    reference.append(GetterView.Entry(sequence: sequence, intent: intent))
                case 6, 7:
                    // The engine handled a prefix; sometimes it did exactly what the intents anticipated.
                    let handled = reference.prefix(Int(generator.next() % 4))
                    var next = engine
                    for entry in handled { entry.intent.apply(to: &next, clearTagsOnLogout: view.clearTagsOnLogout) }
                    if generator.next() % 3 == 0 { next.tags["server_\(generator.next() % 5)"] = "x" }
                    if generator.next() % 4 == 0 { next.logoutIsFree.toggle() }
                    // The identity becomes known (or, for the model, unknown again with nothing set in this launch).
                    if generator.next() % 5 == 0 { next.launchTags = next.launchTags == nil ? [:] : nil }
                    // The engine's state at load: another customer, or none.
                    if generator.next() % 5 == 0 { next.externalId = next.externalId == nil ? "c\(generator.next() % 3)" : nil }
                    // A consent withdrawal forgot the id; the identity token in memory names a customer, or none.
                    if generator.next() % 5 == 0 {
                        next.tokenExternalId = next.tokenExternalId == nil ? "c\(generator.next() % 3)" : nil
                    }
                    next.callSequence = handled.last?.sequence ?? engine.callSequence
                    next.token = "t\(generator.next() % 3)"
                    engine = next
                    view.publish(next)
                    reference.removeFirst(handled.count)
                case 8:
                    let dropped = reference.filter { _ in generator.next() % 3 == 0 }.map(\.sequence)
                    view.remove(sequences: dropped)
                    reference.removeAll { dropped.contains($0.sequence) }
                default:
                    view.setClearTagsOnLogout(generator.next() % 2 == 0)
                }
                var expected = engine
                for entry in reference { entry.intent.apply(to: &expected, clearTagsOnLogout: view.clearTagsOnLogout) }
                XCTAssertEqual(view.resolved(), expected)
                XCTAssertEqual(view.pendingCount, reference.count)
            }
        }
    }

    private static func randomIntent(_ generator: inout SplitMix) -> PendingIntent {
        let key = "k\(generator.next() % 6)"
        switch generator.next() % 7 {
        case 0: return .login(externalId: "c\(generator.next() % 3)")
        case 1: return .logout
        case 2: return .optIn
        case 3: return .optOut
        case 4: return .tags(TagRules.changes(removing: [key]))
        default: return .tags(TagRules.changes(adding: [key: generator.next() % 5 == 0 ? "" : "v\(generator.next() % 9)"]))
        }
    }
}

/// A small deterministic random generator for model tests.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
