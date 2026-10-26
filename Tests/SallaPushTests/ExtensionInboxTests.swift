import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// The app's side of the `received` the extension sends itself: every App Group record names its one sender, so the app
/// never sends a `received` the extension sent or is sending, takes over every claim the extension hasn't started
/// sending, and sends what the extension gives back. The records here are written the way the extension writes and moves
/// them.
final class ExtensionInboxTests: XCTestCase {
    private static let group = "group.salla.test"
    private static let id = "msg_ab12"

    /// A claim the inbox did not write; thrown, it fails the test.
    private struct UnexpectedWrite: Error {
        let result: Inbox.ClaimResult
    }

    /// A harness whose App Groups are available, at a temporary folder removed after the test.
    private func harnessWithAnAppGroup() -> Harness {
        let h = Harness()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-receipts-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        h.appGroupContainer.set(container)
        return h
    }

    private func inbox(_ h: Harness) throws -> Inbox {
        Inbox(folder: Inbox.folder(inContainer: try XCTUnwrap(h.appGroupContainer.current)))
    }

    /// The inbox's file names, sorted.
    private func files(_ h: Harness) throws -> [String] {
        let folder = try inbox(h).folder
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A record the extension claimed at `seconds`, then locked (`.inflight`) when `locked`, then marked sent (`.sent`)
    /// when `sent`.
    @discardableResult
    private func claim(_ h: Harness, _ messageId: String = ExtensionInboxTests.id, at seconds: Double, locked: Bool = false,
                       sent: Bool = false) throws -> InboxClaim {
        let inbox = try inbox(h)
        let written = inbox.writeClaimed(messageId: messageId, at: seconds)
        guard case let .claimed(claim) = written else { throw UnexpectedWrite(result: written) }
        if locked || sent { XCTAssertTrue(inbox.lock(claim)) }
        if sent { XCTAssertTrue(inbox.markSent(claim)) }
        return claim
    }

    /// A SallaPush notification of message `id`.
    private func notification(_ id: String = ExtensionInboxTests.id) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "T", "body": "B"]],
         "custom": ["i": "7d3f1c2a-0000-4000-8000-000000000001", "a": ["push_ref": id]]]
    }

    /// The events push-service got, as "<message id> <type>", from its events request `index` on.
    private func sent(_ h: Harness, from index: Int = 0) -> [String] {
        h.server.requests("events").dropFirst(index).flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).map {
                "\($0["notification_id"] as? String ?? "") \($0["type"] as? String ?? "")"
            }
        }
    }

    /// The `at` of every `received` push-service got, from its events request `index` on.
    private func receivedTimes(_ h: Harness, from index: Int = 0) -> [String] {
        h.server.requests("events").dropFirst(index).flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "received" }
                .map { $0["at"] as? String ?? "" }
        }
    }

    private func seen(_ h: Harness) -> [String] {
        h.file("events.json")["seen"] as? [String] ?? []
    }

    /// The app recorded `received` and `displayed` through `willPresent`, then its events got stuck: six 503s exhaust the
    /// retries of this process, which ends with both on disk. Its first attempt held the message, so the extension
    /// leaves that `received` to the app from then on. Returns when the notification arrived.
    private func stuckEvents(_ h: Harness) -> Double {
        h.registered { $0.appGroupIdentifier = Self.group }
        h.random.set(0)
        h.server.script("events", times: Backoff.attemptsPerProcess) { _ in FakeServer.error(503, "server_error") }
        let arrival = h.clock.now()
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(40)
        XCTAssertEqual(h.server.requests("events").count, Backoff.attemptsPerProcess)
        XCTAssertTrue(h.logs.contains("net.retry_exhausted"))
        XCTAssertEqual((h.file("events.json")["pending"] as? [[String: Any]])?.count, 2)
        return arrival
    }

    /// The app recorded `received` and `displayed` through `willPresent`, and its process ended within the 5 s batch,
    /// before its first flush: both wait on disk, and the app never held the message, so the extension could send that
    /// `received`. Returns when the notification arrived.
    private func unsentEvents(_ h: Harness) -> Double {
        h.registered { $0.appGroupIdentifier = Self.group }
        let arrival = h.clock.now()
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.settle()
        XCTAssertTrue(h.server.requests("events").isEmpty)
        XCTAssertEqual((h.file("events.json")["pending"] as? [[String: Any]])?.count, 2)
        return arrival
    }

    func test_sentRecord_isNeverSentByTheApp() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        try claim(h, at: h.clock.now(), sent: true)
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertTrue(h.server.requests("events").isEmpty)
        XCTAssertEqual(try files(h), [], "deleted once its key is on disk")
        XCTAssertEqual(seen(h), ["msg_ab12|received"])
        // The forwarded `received` of that notification comes after the file went; the key dedupes it.
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"])
    }

    func test_sentRecord_dedupesTheForegroundReceived() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let record = try claim(h, at: h.clock.now(), sent: true)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: notification()), [.banner, .list, .sound])
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"])
        XCTAssertEqual(try files(h), [record.name + ".sent", "msg_ab12.held"], "the settle before a flush deletes nothing")
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertEqual(try files(h), ["msg_ab12.held"])
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"])
    }

    /// In the foreground the flush, 5 s after the notification, comes before the extension's random wait ends: it takes
    /// the claim over and sends both events, and the extension's lock then fails.
    func test_foregroundPush_theFlushTakesTheClaimOver_andSendsBothEvents() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let record = try claim(h, at: h.clock.now())
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(4)
        XCTAssertTrue(h.server.requests("events").isEmpty, "the batch waits 5 s")
        XCTAssertEqual(try files(h), [record.name + ".sending"])
        h.advance(2)
        XCTAssertEqual(sent(h), ["msg_ab12 received", "msg_ab12 displayed"])
        XCTAssertEqual(try files(h), [record.name + ".json", "msg_ab12.held"], "the flush took the claim over")
        XCTAssertFalse(try inbox(h).lock(record), "the extension sends nothing")
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertEqual(try files(h), ["msg_ab12.held"], "the next full pass drops it: the app sent its own")
        XCTAssertEqual(sent(h), ["msg_ab12 received", "msg_ab12 displayed"])
    }

    func test_freshInflight_dropsTheForegroundReceived_andAReleaseIsSentAtTheRecheck() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let arrival = h.clock.now() + 0.25
        h.clock.set(arrival)
        let record = try claim(h, at: arrival, locked: true)
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"], "the extension is sending 'received'")
        XCTAssertFalse(seen(h).contains("msg_ab12|received"), "its key goes, so a record given back is read")
        h.advance(20)
        XCTAssertTrue(try inbox(h).release(record), "the extension gives it back (offline, say)")
        h.advance(35)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed", "msg_ab12 received"], "at the recheck, 60 s after the claim")
        XCTAssertEqual(receivedTimes(h), [ISO8601.string(from: arrival)], "the extension's time")
        XCTAssertEqual(try files(h), ["msg_ab12.held"])
    }

    func test_inflightEndingAsSent_beforeTheRecheck_sendsNoReceived() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let record = try claim(h, at: h.clock.now(), locked: true)
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"])
        XCTAssertTrue(try inbox(h).markSent(record))
        h.advance(61)
        XCTAssertEqual(sent(h), ["msg_ab12 displayed"])
        XCTAssertEqual(try files(h), ["msg_ab12.held"], "the recheck's full pass removed it")
        XCTAssertTrue(seen(h).contains("msg_ab12|received"))
    }

    /// `didReceiveRemoteNotification` can reach the app before the extension writes its record. The settle
    /// before the flush still finds the record: the app sends its own `received` of a claim it takes over, and none of
    /// a record the extension sent.
    func test_recordWrittenAfterTheForwardedReceived_stillSettlesIt() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: notification("msg_a1")))
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: notification("msg_a2")))
        h.settle()
        let claimed = try claim(h, "msg_a1", at: h.clock.now())
        try claim(h, "msg_a2", at: h.clock.now(), sent: true)
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_a1 received"])
        XCTAssertFalse(try inbox(h).lock(claimed))
    }

    /// `didReceiveRemoteNotification` reached the app before the extension wrote its record, and a flush (here the move
    /// to the background) sent the app's `received` at once. The app held the message first, so the claim the extension
    /// writes then can't be locked: push-service gets one `received`, and the app's next pass reads the claim without
    /// sending it again.
    func test_aFlushBeforeTheExtensionsClaim_leavesThatClaimToTheApp() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: notification()))
        h.send(.didEnterBackground)
        XCTAssertEqual(sent(h), ["msg_ab12 received"], "sent at once, before the extension wrote anything")
        XCTAssertEqual(try files(h), ["msg_ab12.held"])
        let late = try claim(h, at: h.clock.now())
        XCTAssertFalse(try inbox(h).lock(late), "the extension sends nothing")
        h.send(.willEnterForeground)
        h.advance(61)
        XCTAssertEqual(sent(h), ["msg_ab12 received"])
        XCTAssertEqual(try files(h), ["msg_ab12.held"], "the pass read the claim, and the dedupe key dropped it")
    }

    func test_plainRecord_withAForegroundReceived_sendsOneReceived() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertEqual(try inbox(h).writeReceived(messageId: Self.id, at: h.clock.now()), .written)
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.settle()
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 received", "msg_ab12 displayed"])
        XCTAssertEqual(try files(h), ["msg_ab12.held"])
    }

    /// A claim whose extension stopped after taking the lock (iOS ended it) is the app's once 60 s old: at once when the
    /// app finds it that old, else at the recheck.
    func test_abandonedInflight_isTakenOverAndSent() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let now = h.clock.now()
        try claim(h, "msg_a1", at: now - 120, locked: true)
        try claim(h, "msg_a2", at: now, locked: true)
        h.send(.willEnterForeground)
        XCTAssertEqual(sent(h), ["msg_a1 received"], "the old claim at once; the fresh one is still the extension's")
        h.advance(59)
        XCTAssertEqual(sent(h), ["msg_a1 received"])
        h.advance(2)
        XCTAssertEqual(sent(h), ["msg_a1 received", "msg_a2 received"])
        XCTAssertEqual(receivedTimes(h).last, ISO8601.string(from: now))
        XCTAssertEqual(try files(h), ["msg_a1.held", "msg_a2.held"])
    }

    /// The user taps the notification while the extension waits its random delay, and the tap launches the killed app.
    /// Its foreground pass takes the claim over and sends `received` with `opened`, as before; the extension's lock then
    /// fails.
    func test_tapWithinTheWait_takesTheClaimOver_andSendsReceivedWithOpened() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let arrival = h.clock.now()
        let record = try claim(h, at: arrival)
        h.advance(3)
        let next = h.relaunch()
        XCTAssertTrue(next.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                     userInfo: notification()))
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next).sorted(), ["msg_ab12 opened", "msg_ab12 received"])
        XCTAssertEqual(next.server.requests("events").count, 1, "one batch")
        XCTAssertEqual(receivedTimes(next), [ISO8601.string(from: arrival)])
        XCTAssertEqual(try files(next), ["msg_ab12.held"])
        XCTAssertFalse(try inbox(next).lock(record))
    }

    /// A `.sent` file goes only once the dedupe key it gave is on disk, so a relaunch can't send its `received`.
    func test_sentFile_isKeptUntilTheSettleIsOnDisk() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let record = try claim(h, at: h.clock.now(), sent: true)
        h.failingWrites.set(["events.json"])
        h.send(.willEnterForeground)
        XCTAssertEqual(try files(h), [record.name + ".sent"], "its key isn't on disk")
        h.failingWrites.set([])
        h.send(.willEnterForeground)
        XCTAssertEqual(try files(h), [])
        XCTAssertEqual(seen(h), ["msg_ab12|received"])
        XCTAssertTrue(h.server.requests("events").isEmpty)
    }

    /// A settle that empties the queue ends its batch, as a sent batch does: an event recorded later still waits 5 s,
    /// although the queue was told to go at once long before, while another request was on the wire.
    func test_aSettleThatEmptiesTheQueue_letsALaterEventWaitForItsBatch() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        h.server.script("update", times: 1) { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1, "an update is on the wire, so the events wait")
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: notification()))
        h.send(.didEnterBackground)
        try claim(h, at: h.clock.now(), sent: true)
        h.send(.willEnterForeground)
        h.server.releaseHeld()
        h.advance(10)
        XCTAssertTrue(h.server.requests("events").isEmpty, "the extension sent it")
        h.submit(.events([EventRecord(messageId: "msg_cd", type: .opened, at: h.clock.now(), actionId: nil)]))
        XCTAssertTrue(h.server.requests("events").isEmpty, "a later event waits for its batch")
        h.advance(5)
        XCTAssertEqual(sent(h), ["msg_cd opened"])
    }

    /// The extension sent a notification's `received` and is sending it again (APNs delivered it twice): the pass that
    /// settles the app's own `received` and deletes the `.sent` file keeps the key, so the second record, given back
    /// later, is never sent by the app.
    func test_aDuplicateStillBeingSent_ofASentRecord_keepsTheKey() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: notification()))
        h.settle()
        try claim(h, at: h.clock.now(), sent: true)
        let duplicate = try claim(h, at: h.clock.now(), locked: true)
        h.send(.willEnterForeground)
        XCTAssertEqual(try files(h), [duplicate.name + ".inflight"], "the .sent file went, once the pass's settle was on disk")
        XCTAssertTrue(seen(h).contains("msg_ab12|received"), "the key stays")
        XCTAssertTrue(try inbox(h).release(duplicate))
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertTrue(h.server.requests("events").isEmpty)
        XCTAssertEqual(try files(h), [])
    }

    // MARK: - Relaunch: the app's own `received` is settled from disk, also in a later process

    func test_relaunch_withASentRecord_sendsOnlyDisplayed() throws {
        let h = harnessWithAnAppGroup()
        let arrival = unsentEvents(h)
        try claim(h, at: arrival, sent: true)
        let next = h.relaunch()
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next), ["msg_ab12 displayed"])
        XCTAssertEqual(try files(next), [])
        XCTAssertTrue((next.file("events.json")["pending"] as? [Any] ?? [0]).isEmpty)
    }

    func test_backgroundRelaunch_withASentRecord_sendsNoReceived() throws {
        let h = harnessWithAnAppGroup()
        let arrival = unsentEvents(h)
        let record = try claim(h, at: arrival, sent: true)
        let next = h.relaunch()
        next.application.state = .background
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next), ["msg_ab12 displayed"])
        XCTAssertEqual(try files(next), [record.name + ".sent", "msg_ab12.held"], "a background launch deletes nothing")
        XCTAssertFalse(next.logs.contains("inbox.ingested"))
    }

    func test_relaunch_withAFreshInflight_sendsNoReceivedNow_andExactlyOneAfterItsRelease() throws {
        let h = harnessWithAnAppGroup()
        let arrival = unsentEvents(h)
        let record = try claim(h, at: arrival, locked: true)
        let next = h.relaunch()
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next), ["msg_ab12 displayed"])
        XCTAssertTrue(try inbox(next).release(record))
        next.advance(55)
        XCTAssertEqual(sent(next), ["msg_ab12 displayed", "msg_ab12 received"], "at the recheck, 60 s after the claim")
        XCTAssertEqual(receivedTimes(next), [ISO8601.string(from: arrival)])
        next.send(.willEnterForeground)
        next.advance(61)
        XCTAssertEqual(sent(next).filter { $0.hasSuffix(" received") }.count, 1)
    }

    func test_relaunch_withASendingClaim_takesItOver_andSendsExactlyOne() throws {
        let h = harnessWithAnAppGroup()
        let arrival = stuckEvents(h)
        let record = try claim(h, at: arrival)
        XCTAssertFalse(try inbox(h).lock(record), "the app held the message at its first attempt")
        let next = h.relaunch()
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next, from: Backoff.attemptsPerProcess), ["msg_ab12 received", "msg_ab12 displayed"])
        XCTAssertFalse(try inbox(next).lock(record), "the extension sends nothing")
        XCTAssertEqual(try files(next), ["msg_ab12.held"])
        next.advance(61)
        XCTAssertEqual(sent(next, from: Backoff.attemptsPerProcess).count, 2)
    }

    /// Without an App Group in SallaPush's configuration nothing reads the inbox: the app's `received` goes as before.
    func test_withoutAnAppGroup_theForegroundReceivedIsUnchanged() throws {
        let h = harnessWithAnAppGroup()
        let record = try claim(h, at: h.clock.now(), sent: true)
        h.registered()
        _ = h.runtime.router.willPresent(userInfo: notification())
        h.advance(6)
        h.send(.willEnterForeground)
        XCTAssertEqual(sent(h), ["msg_ab12 received", "msg_ab12 displayed"])
        XCTAssertEqual(try files(h), [record.name + ".sent"])
    }

    /// A background launch still reads no record into the queue and deletes nothing: the settle before its flush only
    /// takes over the claim of the `received` it holds. The first foreground reads the rest.
    func test_backgroundLaunch_neverIngests() throws {
        let h = harnessWithAnAppGroup()
        let arrival = stuckEvents(h)
        let held = try claim(h, at: arrival)
        XCTAssertEqual(try inbox(h).writeReceived(messageId: "msg_cd", at: arrival), .written)
        try claim(h, "msg_ef", at: arrival)
        let before = try files(h)
        let next = h.relaunch()
        next.application.state = .background
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(6)
        XCTAssertEqual(sent(next, from: Backoff.attemptsPerProcess), ["msg_ab12 received", "msg_ab12 displayed"])
        XCTAssertEqual(try files(next), before.map { $0 == held.name + ".sending" ? held.name + ".json" : $0 }.sorted())
        XCTAssertFalse(next.logs.contains("inbox.ingested"))
        next.application.state = .active
        next.send(.willEnterForeground)
        next.advance(6)
        XCTAssertEqual(sent(next, from: Backoff.attemptsPerProcess).sorted(),
                       ["msg_ab12 displayed", "msg_ab12 received", "msg_cd received", "msg_ef received"])
        XCTAssertEqual(try files(next), ["msg_ab12.held", "msg_cd.held", "msg_ef.held"])
    }

    func test_recheck_waitsForConsent() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let record = try claim(h, at: h.clock.now(), locked: true)
        h.send(.willEnterForeground)
        h.runtime.setConsentRequired(true)
        h.advance(61)
        XCTAssertEqual(try files(h), [record.name + ".inflight"], "no pass while consent is withheld")
        XCTAssertTrue(h.server.requests("events").isEmpty)
        h.runtime.setConsentGiven(true)
        h.advance(6)
        XCTAssertEqual(sent(h), ["msg_ab12 received"], "the first pass with consent takes the claim over")
        XCTAssertEqual(try files(h), ["msg_ab12.held"])
    }
}
