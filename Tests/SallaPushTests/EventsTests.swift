import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

final class EventsTests: XCTestCase {
    private let compat: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "T", "body": "B"]],
        "custom": ["i": "7d3f1c2a-0000-4000-8000-000000000001", "a": ["push_ref": "msg_ab12", "id": "987"]],
    ]

    private func sentEvents(_ h: Harness) -> [(String, String)] {
        h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).map {
                ($0["notification_id"] as? String ?? "", $0["type"] as? String ?? "")
            }
        }
    }

    private func sentTimes(_ h: Harness) -> [String] {
        h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).map { $0["at"] as? String ?? "" }
        }
    }

    /// Writes the `events.json` an earlier version queued: `ids` received now.
    private func queueEvents(_ ids: [String], in h: Harness) throws {
        let at = ISO8601.string(from: h.clock.now())
        let file: [String: Any] = ["v": 1, "pending": ids.map { ["id": $0, "type": "received", "at": at] },
                                   "seen": ids.map { $0 + "|received" }]
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/events.json")
        try JSONSerialization.data(withJSONObject: file).write(to: url)
    }

    /// push-service cuts `at` at the first `.` before it stores it, and loses a batch whose `at` has none: every event
    /// goes in UTC with milliseconds. Its `202 {}` carries no counts.
    func test_at_isSentInUTCWithMilliseconds_andTheEmptyAnswerSendsTheBatch() throws {
        let h = Harness()
        h.registered()
        h.server.script("events") { _ in .json(202, [:], [:]) }
        h.clock.set(1_790_000_000.123)
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        XCTAssertEqual(sentTimes(h), ["2026-09-21T14:13:20.123Z"])
        let event = try XCTUnwrap((h.server.requests("events").first?.json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(event.keys), ["type", "notification_id", "at"])
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty, "202 {} sends the batch")
        XCTAssertEqual(h.logs.all.last { $0.code == "events.flushed" }?.message, "1 event sent.")
        XCTAssertEqual(h.server.requests("events").count, 1)
    }

    /// Events an earlier version queued carry `at` without a fraction: they go in the new form, at the same second.
    func test_eventsQueuedByBeta1_areSentWithMilliseconds() throws {
        let h = Harness()
        h.registered()
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/events.json")
        let queued = #"{"v":1,"pending":[{"id":"msg_ab","type":"opened","at":"2026-09-21T14:13:19Z","action_id":null},"#
            + #"{"id":"msg_cd","type":"received","at":"2026-09-21T17:13:18+03:00","action_id":null}],"#
            + #""seen":["msg_ab|opened","msg_cd|received"]}"#
        try Data(queued.utf8).write(to: url)
        let next = h.relaunch()
        next.initialize()
        next.advance(6)
        XCTAssertEqual(sentTimes(next), ["2026-09-21T14:13:19.000Z", "2026-09-21T14:13:18.000Z"])
        XCTAssertTrue((next.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
        XCTAssertFalse(next.logs.contains("storage.state_reset"))
    }

    func test_tap_recordsOpenedOnce() {
        let h = Harness()
        h.registered()
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                  userInfo: compat))
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.1), ["opened"])
        XCTAssertEqual(sentEvents(h).first?.0, "msg_ab12")
        XCTAssertTrue(h.logs.contains("events.flushed"))
    }

    func test_dismissAction_notOpened_noClick() {
        let h = Harness()
        let clicks = Locked(0)
        let observation = h.runtime.router.addClickHandler { _ in clicks.withLock { $0 += 1 } }
        h.registered()
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDismissActionIdentifier,
                                                  userInfo: compat))
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.1), ["dismissed"])
        XCTAssertEqual(clicks.current, 0)
        observation.cancel()
    }

    func test_coldStartDoubleDelivery_isDeduplicated() {
        let h = Harness()
        h.registered()
        _ = h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: compat)
        _ = h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: compat)
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).count, 1)
    }

    func test_customAction_isOpened_withActionId() {
        let h = Harness()
        let actions = Locked<[String?]>([])
        let observation = h.runtime.router.addClickHandler { event in actions.withLock { $0.append(event.result.actionId) } }
        h.registered()
        _ = h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: "reply", userInfo: compat)
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.1), ["opened"])
        XCTAssertEqual(actions.current, ["reply"])
        observation.cancel()
    }

    func test_batchesOf50() {
        let h = Harness()
        h.registered()
        let sentAt = h.clock.now()
        let records = (0..<120).map { index in
            EventRecord(messageId: "msg_\(String(index, radix: 16))", type: .received, at: sentAt, actionId: nil)
        }
        h.submit(.events(records))
        h.advance(6)
        XCTAssertEqual(h.server.requests("events").map { ($0.json["events"] as? [Any])?.count ?? 0 }, [50, 50, 20])
    }

    func test_oldEvents_areDroppedAtFlush() {
        let h = Harness()
        h.registered()
        h.submit(.events([EventRecord(messageId: "msg_aa", type: .received, at: h.clock.now() - 7 * 86_400, actionId: nil),
                          EventRecord(messageId: "msg_bb", type: .received, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.0), ["msg_bb"])
        XCTAssertTrue(h.logs.contains("events.dropped"))
    }

    /// push-service stores a message id in 40 characters and loses a whole batch, answering 202, when one id is longer.
    /// A payload with a longer id is still SallaPush's, but records no event.
    func test_aMessageIdLongerThan40Characters_recordsNoEvent() {
        let h = Harness()
        h.registered()
        let fits = "msg_" + String(repeating: "a", count: 36)
        let tooLong = "msg_" + String(repeating: "b", count: 37)
        for id in [fits, tooLong] {
            let payload: [AnyHashable: Any] = [
                "aps": ["alert": ["title": "T", "body": "B"]],
                "custom": ["i": "7d3f1c2a-0000-4000-8000-000000000001", "a": ["push_ref": id]],
            ]
            XCTAssertEqual(h.runtime.router.willPresent(userInfo: payload), [.banner, .list, .sound], id)
        }
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.0), [fits, fits])
        XCTAssertFalse((h.file("events.json")["seen"] as? [String] ?? []).contains { $0.hasPrefix(tooLong) })
        XCTAssertFalse(h.logs.contains("events.dropped"))
    }

    /// An event with such an id that an earlier version queued is dropped when events are sent, and the others of its
    /// batch go.
    func test_aQueuedEventWithAMessageIdLongerThan40Characters_isDropped_andTheOthersAreSent() throws {
        let h = Harness()
        h.registered()
        let fits = "msg_" + String(repeating: "a", count: 36)
        try queueEvents(["msg_ab", "msg_" + String(repeating: "c", count: 37), fits], in: h)
        let next = h.relaunch()
        next.initialize()
        next.advance(6)
        XCTAssertEqual(sentEvents(next).map(\.0), ["msg_ab", fits])
        let dropped = try XCTUnwrap(next.logs.all.first { $0.code == "events.dropped" })
        XCTAssertEqual(dropped.message,
                       "1 event was dropped: the SallaPush server stores message ids of up to 40 characters.")
        XCTAssertEqual(dropped.metadata["count"], "1")
        XCTAssertTrue((next.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
    }

    /// A queue holding only such events sends nothing and empties: no empty batch goes every 5 s.
    func test_aQueueOfOnlyMessageIdsLongerThan40Characters_sendsNothing_andEmpties() throws {
        let h = Harness()
        h.registered()
        try queueEvents(["msg_" + String(repeating: "d", count: 37), "msg_" + String(repeating: "e", count: 64)], in: h)
        let next = h.relaunch()
        next.initialize()
        next.advance(60)
        XCTAssertTrue(next.server.requests("events").isEmpty)
        XCTAssertEqual(next.logs.all.filter { $0.code == "events.dropped" }.map(\.message),
                       ["2 events were dropped: the SallaPush server stores message ids of up to 40 characters."])
        next.send(.didEnterBackground)
        XCTAssertTrue(next.server.requests("events").isEmpty)
        XCTAssertTrue((next.file("events.json")["pending"] as? [Any] ?? []).isEmpty)
    }

    func test_tapBeforeRegistration_sentAfter() {
        let h = Harness()
        h.initialize()
        _ = h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: compat)
        h.advance(10)
        XCTAssertTrue(h.server.requests.isEmpty)
        h.sendToken()
        h.advance(6)
        XCTAssertEqual(h.server.templates, ["register", "events"])
    }

    func test_tapBeforeInitialize_isBuffered_andSentAfter() {
        let h = Harness()
        _ = h.runtime.router.didReceive(identifier: "req-1", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: compat)
        h.registered()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.1), ["opened"])
    }

    func test_queueOverflow_dropsTheOldest() {
        let h = Harness()
        h.initialize()
        let sentAt = h.clock.now()
        let records = (0..<510).map { index in
            EventRecord(messageId: "msg_\(String(index + 1, radix: 16))", type: .received, at: sentAt, actionId: nil)
        }
        h.submit(.events(records))
        XCTAssertTrue(h.logs.contains("events.queue_full"))
        let pending = h.file("events.json")["pending"] as? [[String: Any]] ?? []
        XCTAssertEqual(pending.count, 500)
        XCTAssertEqual(pending.first?["id"] as? String, "msg_\(String(11, radix: 16))")
    }

    /// As on Android (`EventsTest.test_queueOverflow_dropsOldest`), a full queue is
    /// reported once per full episode, with the events the call that hit the cap dropped. Events recorded while it stays
    /// full (an unregistered device never sends them) add no line; an event that finds room ends the episode, so the next
    /// overflow is reported again.
    func test_queueFull_isReportedOncePerEpisode_notForEveryLaterEvent() throws {
        let h = Harness()
        h.initialize()
        let at = h.clock.now()
        func record(_ index: Int) -> EventRecord {
            EventRecord(messageId: "msg_\(String(index, radix: 16))", type: .received, at: at, actionId: nil)
        }
        h.submit(.events((1...510).map(record)))
        let first = try XCTUnwrap(h.logs.all.last { $0.code == "events.queue_full" })
        XCTAssertEqual(first.metadata["count"], "10")
        XCTAssertEqual(first.message, "Event queue full (500); the 10 oldest events were dropped, and one more is dropped "
                           + "for each new event until events are sent.")
        for index in 511...515 { h.submit(.events([record(index)])) }
        XCTAssertEqual(h.logs.count("events.queue_full"), 1, "nothing more while the queue stays full")
        XCTAssertEqual((h.file("events.json")["pending"] as? [[String: Any]])?.count, 500)

        // The device registers and sends what is pending: the queue has room again.
        h.sendToken()
        h.advance(10)
        XCTAssertEqual((h.file("events.json")["pending"] as? [[String: Any]])?.count, 0)
        h.submit(.events((600...1_100).map(record)))
        XCTAssertEqual(h.logs.count("events.queue_full"), 2, "a new episode")
        let second = try XCTUnwrap(h.logs.all.last { $0.code == "events.queue_full" })
        XCTAssertEqual(second.metadata["count"], "1")
        XCTAssertEqual(second.message, "Event queue full (500); the oldest event was dropped, and one more is dropped for "
                           + "each new event until events are sent.")
    }

    func test_inboxIngested() throws {
        let h = Harness()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        h.appGroupContainer.set(container)
        let inbox = Inbox(folder: Inbox.folder(inContainer: container))
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_cafe", at: h.clock.now()), .written)
        try FileManager.default.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: inbox.folder.appendingPathComponent("1-x.json"))
        h.registered { $0.appGroupIdentifier = "group.salla.test" }
        h.send(.willEnterForeground)
        h.advance(6)
        XCTAssertEqual(sentEvents(h).first?.0, "msg_cafe")
        XCTAssertEqual(sentEvents(h).first?.1, "received")
        XCTAssertEqual(sentTimes(h).first, "2026-09-21T14:13:20.000Z")
        XCTAssertTrue(h.logs.contains("inbox.ingested"))
        XCTAssertTrue(h.logs.contains("inbox.invalid_file"))
        XCTAssertFalse(h.logs.contains("config.no_app_group"))
        XCTAssertFalse(h.logs.contains("storage.failed"), "an available App Group is no error")
    }

    /// An App Group that is configured but not available to the app (the capability is missing or
    /// the id has a typo) would drop every `received` event of the extension without a word in the app: it is an ERROR
    /// once per launch, which names the App Group and the fix.
    func test_configuredAppGroup_unavailableToTheApp_isAnErrorOncePerLaunch() throws {
        let h = Harness()
        h.appGroupContainer.set(nil)
        h.registered { $0.appGroupIdentifier = "group.com.salla.typo" }
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.initialize("st_43_ios") { $0.appGroupIdentifier = "group.com.salla.typo" }
        h.advance(40)
        let errors = h.logs.all.filter { $0.code == "storage.failed" }
        XCTAssertEqual(errors.count, 1, "once per launch")
        let error = try XCTUnwrap(errors.first)
        XCTAssertEqual(error.level, .error)
        XCTAssertEqual(error.message, "The App Group group.com.salla.typo is not available to the app; add it to the app "
                       + "target's App Groups capability; 'received' events from the Notification Service Extension are not "
                       + "read, and SallaPush doesn't count notifications on the app badge.")
        XCTAssertFalse(h.logs.contains("config.no_app_group"))
    }

    func test_willPresent_recordsReceivedAndDisplayed() {
        let h = Harness()
        h.registered()
        let options = h.runtime.router.willPresent(userInfo: compat)
        XCTAssertEqual(options, [.banner, .list, .sound])
        h.settle()
        h.advance(6)
        XCTAssertEqual(Set(sentEvents(h).map(\.1)), ["received", "displayed"])
    }

    /// `didReceiveRemoteNotification` records `received` for a SallaPush payload and
    /// uploads it; another SDK's payload records nothing.
    func test_didReceiveRemoteNotification_recordsReceived() {
        let h = Harness()
        h.registered()
        XCTAssertTrue(h.runtime.router.didReceiveRemoteNotification(userInfo: compat))
        XCTAssertFalse(h.runtime.router.didReceiveRemoteNotification(userInfo: ["aps": ["content-available": 1]]))
        h.settle()
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.0), ["msg_ab12"])
        XCTAssertEqual(sentEvents(h).map(\.1), ["received"])
    }

    func test_eventsWithoutValidId_areNotRecorded() {
        let h = Harness()
        h.registered()
        _ = h.runtime.router.willPresent(userInfo: ["sp_v": "1", "sp_id": "msg_XYZ", "aps": ["alert": "x"]])
        h.settle()
        h.advance(6)
        XCTAssertTrue(h.server.requests("events").isEmpty)
    }

    /// A 400 on events drops that batch (ERROR) and never blocks the events that follow.
    func test_eventsRejected_batchDropped_laterEventsSent() {
        let h = Harness()
        h.registered()
        h.server.script("events") { _ in FakeServer.error(400, "invalid_request") }
        h.submit(.events([EventRecord(messageId: "msg_aa", type: .received, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        XCTAssertEqual(h.server.requests("events").count, 1)
        XCTAssertEqual(h.logs.all.first { $0.code == "net.client_error" }?.level, .error)
        XCTAssertTrue((h.file("events.json")["pending"] as? [Any] ?? []).isEmpty, "the rejected batch is dropped")
        h.submit(.events([EventRecord(messageId: "msg_bb", type: .received, at: h.clock.now(), actionId: nil)]))
        h.advance(6)
        XCTAssertEqual(sentEvents(h).map(\.0), ["msg_aa", "msg_bb"], "the dropped batch is never resent")
    }

    func test_backgroundSendsEventsAtOnce() {
        let h = Harness()
        h.registered()
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .received, at: h.clock.now(), actionId: nil)]))
        h.send(.didEnterBackground)
        h.settle()
        XCTAssertEqual(h.server.requests("events").count, 1)
    }

    /// A foreground flushes the events pending then; the flush is not kept for events
    /// recorded later, which wait for their batch (5 s after the first).
    func test_aForegroundFlush_coversThePendingEvents_notLaterOnes() {
        let h = Harness()
        h.registered()
        h.advance(10)
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .received, at: h.clock.now(), actionId: nil)]))
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .displayed, at: h.clock.now(), actionId: nil)]))
        h.advance(4)
        XCTAssertTrue(h.server.requests("events").isEmpty, "a foreground with nothing pending does not hurry later events")
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(2)
        XCTAssertEqual(sentEvents(h).map(\.1), ["received", "displayed", "opened"], "one batch, 5 s after the first")
        h.submit(.events([EventRecord(messageId: "msg_cd", type: .received, at: h.clock.now(), actionId: nil)]))
        h.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.server.requests("events").count, 2, "a foreground sends what is pending at once")
    }
}
