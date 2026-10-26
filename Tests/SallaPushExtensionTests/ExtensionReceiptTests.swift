import Foundation
import SallaPushCore
@testable import SallaPushExtension
import Security
import UserNotifications
import XCTest

/// The extension sends `received` itself: it claims the record before the content handler
/// runs, sends after its random wait with all the time left as the timeout, retries only a server error or a failed
/// connection, and gives the record back to the app in every other case. `didReceive` waits for it off the main thread
/// only, and never past the notification's 30 s.
final class ExtensionReceiptTests: XCTestCase {
    // XCTest creates one instance per test method, so every test starts with a fresh rig.
    private let rig = ReceiptRig()
    private let spy = ContentHandlerSpy()

    override func tearDownWithError() throws {
        // No entry of any test holds a secret, whatever its level: the rig collects them all.
        for entry in rig.entries {
            for secret in [ReceiptRig.secret, ReceiptRig.rotatedSecret] {
                XCTAssertFalse(entry.message.contains(secret), "\(entry.code): \(entry.message)")
                XCTAssertFalse(entry.metadata.values.contains { $0.contains(secret) }, entry.code)
            }
        }
        rig.clean()
    }

    /// One row of the answer table: the answer, the record's final state, the code logged with its level, and the
    /// reason it carries.
    private struct Row {
        let answer: HTTPResult
        let state: String
        let code: String
        let level: SallaPushLogLevel
        var reason: String?
    }

    // MARK: - Helpers

    /// Hands notification `messageId` to `handler`, or to a new handler.
    @discardableResult
    private func receive(_ messageId: String = "msg_ab", on handler: SallaPushServiceExtension? = nil) -> Bool {
        (handler ?? rig.makeHandler()).didReceive(rig.notification(messageId), withContentHandler: spy.handler)
    }

    /// The events `request` sends.
    private func events(_ request: HTTPRequest) -> [[String: Any]] {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return body?["events"] as? [[String: Any]] ?? []
    }

    // MARK: - Timing

    func test_constants() {
        XCTAssertEqual(ReceiptTiming.delayBound, 25)
        XCTAssertEqual(ReceiptTiming.lifetime, 30)
        XCTAssertEqual(ReceiptTiming.minimumAttemptTime, 2)
        XCTAssertEqual(ReceiptTiming.maximumAttempts, 3)
        XCTAssertGreaterThan(Inbox.claimLifetime, ReceiptTiming.lifetime + 20,
                             "the app takes an .inflight record over only once its extension can't be running")
        let units: [Double] = [0, 0.04, 0.5, 0.999, 1, .nan, -1, .infinity]
        XCTAssertEqual(units.map(ReceiptTiming.delay(unit:)), [0, 1, 12, 24, 24, 0, 0, 0])
    }

    func test_withSharedCredentials_theRecordIsClaimed_theContentHandlerRunsFirst_andReceivedIsSentAfterTheRandomWait() throws {
        rig.share()
        XCTAssertTrue(receive())
        XCTAssertEqual(spy.calls.count, 1, "shown before any request")
        XCTAssertTrue(rig.requests.isEmpty)
        XCTAssertEqual(rig.states, ["msg_ab": "sending"], "claimed")
        XCTAssertEqual(rig.scheduler.waits, [12], "the random wait of 0.5")
        XCTAssertEqual(rig.waited.current, [30], "didReceive waits until the notification's deadline at most")
        XCTAssertEqual(rig.scheduler.fireNext(), 12)
        XCTAssertEqual(rig.states, ["msg_ab": "inflight"], "the send lock")
        let request = try XCTUnwrap(rig.requests.first)
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString,
                       "https://api.salla.dev/notifications/v1/sallapush/devices/\(ReceiptRig.deviceId)/events")
        XCTAssertEqual(request.headers, ["Authorization": "Device \(ReceiptRig.secret)", "Content-Type": "application/json",
                                         "Accept": "application/json"])
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? NSDictionary
        XCTAssertEqual(body, ["events": [["at": "2026-09-21T14:13:20.000Z", "notification_id": "msg_ab",
                                          "type": "received"]]] as NSDictionary)
        XCTAssertEqual(request.timeout, 30, "all the time left")
        rig.transports[0].complete(0, with: .accepted)
        XCTAssertEqual(rig.states, ["msg_ab": "sent"])
        let sent = try XCTUnwrap(rig.entries("nse.received_sent").first)
        XCTAssertEqual(sent.level, .debug)
        XCTAssertEqual(sent.category, "extension")
        XCTAssertEqual(sent.message, "'received' sent from the extension (HTTP 202, attempt 1, after a 12 s wait).")
        XCTAssertEqual(sent.metadata, ["http_status": "202", "request_id": "req-1", "attempt": "1", "delay_s": "12",
                                       "app_id": "st_42_ios"])
        XCTAssertEqual(rig.entries.map(\.code), ["nse.received_sent"], "nothing else is logged")
        XCTAssertTrue(rig.transports[0].isInvalidated, "the receipt's session ends with it")
    }

    /// An attempt's timeout is the time left until the deadline.
    func test_aLateAttempt_getsTheTimeLeftAsItsTimeout() {
        rig.share()
        rig.random.set(0)
        receive("msg_a1")
        rig.random.set(0.999)
        receive("msg_a2")
        XCTAssertEqual(rig.scheduler.waits, [0, 24])
        rig.scheduler.fireNext()
        rig.clock.advance(24)
        rig.scheduler.fireNext()
        XCTAssertEqual(rig.requests.map(\.timeout), [30, 6])
        XCTAssertEqual(rig.requests.flatMap(events).compactMap { $0["at"] as? String },
                       ["2026-09-21T14:13:20.000Z", "2026-09-21T14:13:20.000Z"], "`at` is the arrival, also 24 s later")
    }

    // MARK: - Answers

    func test_eachRetryableAnswer_isRetried_thenReleased() throws {
        rig.share()
        let answers: [HTTPResult] = [.error(500, "server_error"), .failure(.network("offline")), .text(500, "<html>")]
        for (index, answer) in answers.enumerated() {
            let messageId = "msg_a\(index)"
            receive(messageId)
            var fired: [Double?] = []
            for attempt in 0..<ReceiptTiming.maximumAttempts {
                fired.append(rig.scheduler.fireNext())
                rig.transports.last?.complete(attempt, with: answer)
            }
            XCTAssertEqual(fired, [12, 1.5, 3], "the random wait, then the backoff (\(messageId))")
            XCTAssertEqual(rig.transports.last?.requests.count, 3, messageId)
            XCTAssertEqual(rig.states[messageId], "json", "given back to the app (\(messageId))")
            XCTAssertTrue(rig.scheduler.waits.isEmpty, "no fourth attempt (\(messageId))")
        }
        let retries = rig.entries("net.retry")
        XCTAssertEqual(retries.map(\.level), Array(repeating: .info, count: 6))
        XCTAssertEqual(retries.map { $0.metadata[LogMetadataKey.attempt] }, ["1", "2", "1", "2", "1", "2"])
        let first = try XCTUnwrap(retries.first)
        XCTAssertEqual(first.message, "POST /devices/{id}/events failed (500 server_error); retry 1 in 2 s.")
        XCTAssertEqual(first.metadata, ["route": "/devices/{id}/events", "http_status": "500", "error_code": "server_error",
                                        "app_id": "st_42_ios", "attempt": "1", "delay_s": "2"])
        XCTAssertEqual(rig.deferredReasons, ["failed", "failed", "failed"])
        XCTAssertEqual(rig.entries("nse.received_deferred").first?.message,
                       "'received' is left for the app (POST /devices/{id}/events failed: 500 server_error); the app sends "
                           + "it the next time it comes to the foreground.")
    }

    /// A timeout fires only at the deadline, and push-service may have stored the request.
    func test_aTimeout_isNeverRetried() {
        rig.share()
        receive()
        rig.scheduler.fireNext()
        rig.transports.first?.complete(0, with: .failure(.timeout))
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertTrue(rig.scheduler.waits.isEmpty)
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["failed"])
        XCTAssertTrue(rig.entries("net.retry").isEmpty)
    }

    /// An answer 25 s after the notification still counts, and nothing sent the request again meanwhile.
    func test_aSlowAnswer_isSentOnce() {
        rig.share()
        receive()
        rig.scheduler.fireNext()
        rig.clock.advance(25)
        XCTAssertTrue(rig.scheduler.waits.isEmpty, "no timer of the receipt's cuts the request")
        rig.transports.first?.complete(0, with: .accepted)
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertEqual(rig.requests.first?.timeout, 30)
        XCTAssertEqual(rig.states, ["msg_ab": "sent"])
    }

    /// A request that can't start (its session is gone) gives the record back at once.
    func test_aRequestThatCannotStart_givesTheRecordBack() {
        rig.share()
        rig.deadTransports.set(true)
        receive()
        rig.scheduler.fireNext()
        XCTAssertTrue(rig.requests.isEmpty)
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["failed"])
        XCTAssertEqual(rig.entries("nse.received_deferred").first?.message,
                       "'received' is left for the app (the request could not start); the app sends it the next time it "
                           + "comes to the foreground.")
    }

    /// A retry, and any attempt, starts only with 2 s left.
    func test_aRetry_neverPassesTheDeadline() {
        rig.share()
        receive("msg_a1")
        rig.scheduler.fireNext()
        rig.transports.last?.complete(0, with: .error(503, "server_error", headers: ["retry-after": "29"]))
        XCTAssertTrue(rig.scheduler.waits.isEmpty, "29 s later, 1 s would be left")
        XCTAssertEqual(rig.states["msg_a1"], "json")

        receive("msg_a2")
        rig.scheduler.fireNext()
        rig.transports.last?.complete(0, with: .error(503, "server_error", headers: ["retry-after": "28"]))
        XCTAssertEqual(rig.scheduler.waits, [28], "28 s later, 2 s are left")
        rig.clock.advance(28)
        rig.scheduler.fireNext()
        XCTAssertEqual(rig.transports.last?.requests.map(\.timeout), [30, 2], "the retry gets its 2 s")
        rig.transports.last?.complete(1, with: .accepted)
        XCTAssertEqual(rig.states["msg_a2"], "sent")

        receive("msg_a3")
        rig.clock.advance(28.5)
        rig.scheduler.fireNext()
        XCTAssertEqual(rig.transports.count, 2, "1.5 s left when its attempt runs: no request")
        XCTAssertEqual(rig.states["msg_a3"], "json")
        XCTAssertEqual(rig.deferredReasons, ["failed", "time_limit"])
    }

    /// The answer table, one answer per row: a 4xx that isn't push-service's is never retried.
    func test_answerTable() throws {
        rig.share()
        let refused = { (status: Int, code: String) in
            Row(answer: .error(status, code), state: "json", code: "net.client_error", level: .error)
        }
        let rows = [
            Row(answer: .error(429, "rate_limited"), state: "json", code: "net.rate_limited", level: .warn),
            Row(answer: .error(401, "invalid_device_secret"), state: "json", code: "nse.received_deferred", level: .info,
                reason: "stale_credentials"),
            Row(answer: .error(404, "unknown_device"), state: "json", code: "nse.received_deferred", level: .info,
                reason: "stale_credentials"),
            Row(answer: .error(404, "not_found"), state: "json", code: "net.routes_closed", level: .warn),
            refused(400, "invalid_request"), refused(403, "forbidden"), refused(409, "conflict"), refused(422, "invalid"),
            Row(answer: .text(403, #"{"message":"denied"}"#), state: "json", code: "nse.received_deferred", level: .info,
                reason: "failed"),
            Row(answer: .text(403, "<html>denied</html>"), state: "json", code: "nse.received_deferred", level: .info,
                reason: "failed"),
            Row(answer: .text(302, ""), state: "json", code: "net.redirect_refused", level: .error),
            Row(answer: .text(200, "<html>"), state: "sent", code: "nse.received_sent", level: .debug),
            Row(answer: .failure(.cancelled), state: "json", code: "nse.received_deferred", level: .info, reason: "failed"),
            Row(answer: .text(101, "{}"), state: "json", code: "nse.received_deferred", level: .info, reason: "failed"),
        ]
        for (index, row) in rows.enumerated() {
            let messageId = "msg_b\(String(index, radix: 16))"
            let before = rig.entries.count
            receive(messageId)
            rig.scheduler.fireNext()
            rig.transports.last?.complete(0, with: row.answer)
            let logged = Array(rig.entries.dropFirst(before))
            XCTAssertEqual(rig.transports.last?.requests.count, 1, "row \(index): one request")
            XCTAssertTrue(rig.scheduler.waits.isEmpty, "row \(index): never retried")
            XCTAssertEqual(rig.states[messageId], row.state, "row \(index)")
            XCTAssertEqual(logged.map(\.code), [row.code], "row \(index)")
            XCTAssertEqual(logged.first?.level, row.level, "row \(index)")
            XCTAssertEqual(logged.first?.metadata[LogMetadataKey.reason], row.reason, "row \(index)")
        }
        XCTAssertEqual(rig.entries("nse.received_deferred").first?.metadata, [
            "route": "/devices/{id}/events", "http_status": "401", "error_code": "invalid_device_secret",
            "app_id": "st_42_ios", "attempt": "1", "reason": "stale_credentials",
        ])
        XCTAssertEqual(rig.entries("net.client_error").first?.message,
                       "POST /devices/{id}/events was rejected (400 invalid_request: \"invalid_request message\"); "
                           + "'received' is left for the app, which sends it the next time it comes to the foreground.")
    }

    // MARK: - The send lock and the shared item

    /// A claim the app took over before the lock (a tap, a foreground flush) is the app's to send.
    func test_aClaimTheAppTookOver_isNeverSent() throws {
        rig.share()
        receive()
        let claimed = try XCTUnwrap(rig.files.first)
        _ = rig.inbox.scan(now: FixedClock().now(), takingOver: ["msg_ab"])
        rig.scheduler.fireNext()
        XCTAssertTrue(rig.transports.isEmpty, "no request, not even a session")
        XCTAssertEqual(rig.files, [(claimed as NSString).deletingPathExtension + ".json"], "the extension renames nothing")
        XCTAssertEqual(rig.deferredReasons, ["taken_over"])
        XCTAssertEqual(rig.entries("nse.received_deferred").first?.message,
                       "The app took over this 'received' record; the extension doesn't send it.")
    }

    /// The app sent the notification's `received` before the extension wrote its claim, and held the message first:
    /// the lock fails, so the extension sends nothing, and leaves the claim to the app.
    func test_aMessageTheAppHolds_isNeverSent() throws {
        rig.share()
        rig.inbox.hold(["msg_ab"], now: FixedClock().now())
        receive()
        rig.scheduler.fireNext()
        XCTAssertTrue(rig.transports.isEmpty, "no request, not even a session")
        XCTAssertEqual(rig.files.filter { $0.hasSuffix(".sending") }.count, 1, "the claim waits for the app")
        XCTAssertEqual(rig.deferredReasons, ["taken_over"])
    }

    /// A consent withdrawal during the wait, or before a retry, deletes the item, so the attempt finds none and sends
    /// nothing.
    func test_consentWithdrawnDuringTheWait_sendsNothing_andReleases() {
        rig.share()
        receive("msg_a1")
        receive("msg_a2")
        rig.scheduler.fireNext()
        rig.transports.first?.complete(0, with: .error(503, "server_error"))
        rig.unshare()
        while rig.scheduler.fireNext() != nil {}
        XCTAssertEqual(rig.transports.count, 1, "msg_a2: not even a session")
        XCTAssertEqual(rig.requests.count, 1, "msg_a1: no retry")
        XCTAssertEqual(rig.states, ["msg_a1": "json", "msg_a2": "json"])
        XCTAssertEqual(rig.deferredReasons, ["no_credentials", "no_credentials"])
    }

    /// Every attempt reads the item again, so it sends with the credentials the app shares by then, a retry too.
    func test_rotatedCredentials_areReadAgainBeforeSending() throws {
        rig.share()
        receive()
        rig.share(deviceId: ReceiptRig.rotatedDeviceId, secret: ReceiptRig.rotatedSecret)
        rig.scheduler.fireNext()
        let request = try XCTUnwrap(rig.requests.first)
        XCTAssertEqual(request.url.path, "/notifications/v1/sallapush/devices/\(ReceiptRig.rotatedDeviceId)/events")
        XCTAssertEqual(request.headers["Authorization"], "Device \(ReceiptRig.rotatedSecret)")
        rig.transports.first?.complete(0, with: .error(503, "server_error"))
        rig.share()
        rig.scheduler.fireNext()
        let retry = try XCTUnwrap(rig.requests.dropFirst().first, "retried")
        XCTAssertEqual(retry.url.path, "/notifications/v1/sallapush/devices/\(ReceiptRig.deviceId)/events")
        XCTAssertEqual(retry.headers["Authorization"], "Device \(ReceiptRig.secret)")
    }

    func test_withoutCredentials_orLocked_orUnreadable_orMalformed_orWithoutTheAppBundle_theRecordIsPlain_andNothingWaits() {
        let handler = rig.makeHandler()
        receive("msg_c1", on: handler)
        rig.share()
        rig.keychain.forcedReadStatus.set(errSecInteractionNotAllowed)
        receive("msg_c2", on: handler)
        rig.keychain.forcedReadStatus.set(errSecMissingEntitlement)
        receive("msg_c3", on: handler)
        rig.keychain.forcedReadStatus.set(nil)
        rig.keychain.put(Data("{".utf8), service: "com.salla.test.sallapush.extension", account: "device_credentials",
                         group: ReceiptRig.group)
        receive("msg_c4", on: handler)
        rig.share()
        rig.appBundleIdentifier.set(nil)
        receive("msg_c5", on: handler)
        rig.appBundleIdentifier.set(ReceiptRig.appBundle)
        rig.unshare()
        receive("msg_c6", on: handler)
        XCTAssertEqual(rig.states, ["msg_c1": "json", "msg_c2": "json", "msg_c3": "json", "msg_c4": "json",
                                    "msg_c5": "json", "msg_c6": "json"])
        XCTAssertEqual(spy.calls.count, 6)
        XCTAssertTrue(rig.waited.current.isEmpty, "didReceive never waits without a receipt")
        XCTAssertTrue(rig.scheduler.waits.isEmpty)
        XCTAssertTrue(rig.transports.isEmpty)
        XCTAssertEqual(rig.deferredReasons, ["no_credentials", "credentials_locked", "no_app_bundle"], "once each")
        XCTAssertEqual(rig.entries("nse.received_deferred").map(\.level), [.info, .info, .info])
        XCTAssertEqual(rig.entries("storage.failed").map(\.message), [
            "Could not read the device credentials the app shares with the extension (Keychain status -34018); "
                + "'received' is left for the app.",
            "Could not read the device credentials the app shares with the extension (an item SallaPush could not have "
                + "written); 'received' is left for the app.",
        ])
        XCTAssertEqual(rig.entries("storage.failed").map(\.level), [.error, .error])
    }

    /// On the main thread there is no claim, no Keychain read and no wait: today's plain record.
    func test_onTheMainThread_theRecordIsPlain_andNothingWaits() {
        rig.share()
        rig.isMainThread.set(true)
        let handler = rig.makeHandler()
        receive("msg_d1", on: handler)
        receive("msg_d2", on: handler)
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertEqual(rig.keychain.readCount, 0)
        XCTAssertTrue(rig.waited.current.isEmpty)
        XCTAssertTrue(rig.scheduler.waits.isEmpty)
        XCTAssertTrue(rig.transports.isEmpty)
        XCTAssertEqual(rig.states, ["msg_d1": "json", "msg_d2": "json"])
        XCTAssertEqual(rig.deferredReasons, ["main_thread"], "once per process")
        XCTAssertEqual(rig.entries("nse.received_deferred").first?.message,
                       "'received' is left for the app (didReceive ran on the main thread, which SallaPush never blocks); "
                           + "the app sends it the next time it comes to the foreground.")
    }

    func test_aLongMessageId_isNotSentByTheExtension() {
        rig.share()
        let long = "msg_" + String(repeating: "a", count: 37)
        receive(long)
        XCTAssertEqual(rig.states, [long: "json"], "41 characters: push-service can't store it, and the app drops it")
        XCTAssertEqual(rig.keychain.readCount, 0)
        XCTAssertTrue(rig.waited.current.isEmpty)
        XCTAssertTrue(rig.entries.isEmpty)
    }

    func test_noAppGroup_staysAsToday() {
        rig.share()
        receive(on: rig.makeHandler(appGroup: nil))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(rig.files.isEmpty)
        XCTAssertEqual(rig.keychain.readCount, 0)
        XCTAssertTrue(rig.waited.current.isEmpty)
        XCTAssertEqual(rig.entries.map(\.code), ["config.no_app_group"])
    }

    /// A claim the inbox can't write leaves nothing to send: the inbox's log line of today, and no wait.
    func test_aFullOrUnwritableInbox_claimsNothing_andNothingWaits() throws {
        rig.share()
        try FileManager.default.createDirectory(at: rig.inbox.folder, withIntermediateDirectories: true)
        for index in 0..<Inbox.capacity {
            try Data().write(to: rig.inbox.folder.appendingPathComponent("1-\(index).json"))
        }
        receive("msg_1a")
        try FileManager.default.removeItem(at: rig.root)
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: rig.root.appendingPathComponent("group"))
        receive("msg_2a")
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertEqual(rig.entries.map(\.code), ["events.queue_full", "storage.failed"])
        XCTAssertEqual(rig.entries.map(\.level), [.warn, .error])
        XCTAssertTrue(rig.waited.current.isEmpty)
        XCTAssertTrue(rig.scheduler.waits.isEmpty)
    }
}

// MARK: - The wait, expiry and lifetime

extension ExtensionReceiptTests {
    /// The `didReceive` thread waits for the time left, never more than 30 s; then the record goes back to the app.
    func test_theDeadline_releasesTheRecord() {
        rig.share()
        let handler = rig.makeHandler(block: { _, _ in false })
        let arrival = FixedClock().now()
        receive("msg_e1", on: handler)
        rig.clock.script([arrival, arrival + 10])
        receive("msg_e2", on: handler)
        rig.clock.script([arrival, arrival - 100])
        receive("msg_e3", on: handler)
        XCTAssertEqual(rig.waited.current, [30, 20, 30], "also when the clock moved back")
        XCTAssertEqual(rig.states, ["msg_e1": "json", "msg_e2": "json", "msg_e3": "json"])
        XCTAssertEqual(rig.deferredReasons, ["time_limit", "time_limit", "time_limit"])
        XCTAssertNil(rig.scheduler.fireNext(), "every attempt was cancelled")
        XCTAssertTrue(rig.transports.isEmpty)
    }

    /// Expiry delivers the best attempt first, then stops the receipt, which gives the record back
    /// and wakes `didReceive`.
    func test_expiry_deliversTheBestAttemptFirst_thenReleases() throws {
        rig.share()
        let handler = rig.makeHandler(block: ReceiptEnvironment.waitForSignal)
        let probe = rig.probe()
        let request = rig.notification(image: "https://cdn.salla.test/p.png")
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            handler.didReceive(request, withContentHandler: probe.handler)
            returned.signal()
        }
        XCTAssertEqual(rig.waitStarted.wait(timeout: .now() + 5), .success, "didReceive waits")
        XCTAssertEqual(rig.waited.current.count, 1)
        XCTAssertEqual(rig.downloader.downloads.count, 1, "the image is downloading")
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertTrue(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(probe.calls.map { $0.map { ($0 as NSString).pathExtension } }, [["sending"]],
                       "delivered while the record was still claimed")
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success, "didReceive returned")
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["expired"])
        XCTAssertEqual(rig.entries("nse.expired").count, 1)
        XCTAssertNil(rig.scheduler.fireNext(), "the attempt was cancelled")
    }

    func test_expiry_withNoOwnedDelivery_stillCancelsTheReceipt_andReturnsFalse() {
        rig.share()
        let handler = rig.makeHandler()
        receive(on: handler)
        XCTAssertEqual(spy.calls.count, 1, "delivered at once: no image")
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire(), "it owns no delivery")
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["expired"])
        XCTAssertTrue(rig.entries("nse.expired").isEmpty)
        XCTAssertNil(rig.scheduler.fireNext())
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(rig.deferredReasons, ["expired"], "a receipt ends once")
        XCTAssertEqual(spy.calls.count, 1)
    }

    /// Expiry stops a request in flight and gives the record back; the request's late answer changes nothing.
    func test_expiry_stopsARequestInFlight_andItsLateAnswerChangesNothing() {
        rig.share()
        let handler = rig.makeHandler()
        receive(on: handler)
        rig.scheduler.fireNext()
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(rig.transports.first?.handles.first?.isCancelled, true)
        XCTAssertEqual(rig.transports.first?.isInvalidated, true)
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        rig.transports.first?.complete(0, with: .failure(.cancelled))
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["expired"], "it ended once")
    }

    /// A receipt that ends while its request starts (expiry, on another thread) stops that request at once.
    func test_aReceiptThatEndsWhileItsRequestStarts_stopsIt() {
        rig.share()
        let handler = rig.makeHandler()
        receive(on: handler)
        rig.onSend.set { _ = handler.serviceExtensionTimeWillExpire() }
        rig.scheduler.fireNext()
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertEqual(rig.transports.first?.handles.first?.isCancelled, true, "stopped at once")
        XCTAssertEqual(rig.transports.first?.isInvalidated, true)
        XCTAssertEqual(rig.states, ["msg_ab": "json"])
        XCTAssertEqual(rig.deferredReasons, ["expired"])
    }

    func test_didReceive_returnsOnlyOnceTheReceiptEnded() {
        rig.share()
        let handler = rig.makeHandler(block: ReceiptEnvironment.waitForSignal)
        let request = rig.notification()
        let spy = self.spy
        let returned = DispatchSemaphore(value: 0)
        let statesAtReturn = Locked<[String: String]>([:])
        DispatchQueue.global().async { [rig] in
            handler.didReceive(request, withContentHandler: spy.handler)
            statesAtReturn.set(rig.states)
            returned.signal()
        }
        XCTAssertEqual(rig.waitStarted.wait(timeout: .now() + 5), .success, "didReceive waits")
        XCTAssertEqual(rig.waited.current.count, 1)
        XCTAssertEqual(spy.calls.count, 1, "shown first")
        XCTAssertEqual(rig.scheduler.fireNext(), 12)
        rig.transports.first?.complete(0, with: .accepted)
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(statesAtReturn.current, ["msg_ab": "sent"], "it returned only once the receipt ended")
        XCTAssertEqual(rig.states, ["msg_ab": "sent"])
    }

    /// An app may create a handler per request and let it go: the receipt holds itself, not the handler.
    func test_releasingTheHandler_doesNotStopTheReceipt() {
        rig.share()
        weak var released: SallaPushServiceExtension?
        autoreleasepool {
            let handler = rig.makeHandler()
            released = handler
            receive(on: handler)
        }
        XCTAssertNil(released, "the app let go of its handler")
        XCTAssertEqual(rig.scheduler.fireNext(), 12)
        rig.transports.first?.complete(0, with: .accepted)
        XCTAssertEqual(rig.states, ["msg_ab": "sent"])
    }

    /// A handler the app reuses lets go of each receipt that ended once the next notification comes, and an ended
    /// receipt holds nothing that keeps it alive (its attempt and its request are let go).
    func test_aReusedHandler_letsGoOfItsEndedReceipts() {
        rig.share()
        let handler = rig.makeHandler()
        receive("msg_a1", on: handler)
        rig.scheduler.fireNext()
        rig.transports.first?.complete(0, with: .accepted)
        XCTAssertEqual(rig.liveReceipts, 1, "ended, and kept by its handler until the next notification")
        receive("msg_a2", on: handler)
        XCTAssertEqual(rig.liveReceipts, 1, "only the new one")
        XCTAssertEqual(rig.states, ["msg_a1": "sent", "msg_a2": "sending"])
    }

    /// One record, one receipt, one session and one waiting thread per notification, on a handler each.
    func test_severalNotificationsAtOnce_areIndependent() {
        rig.share()
        let ids = (0..<20).map { "msg_f\(String($0, radix: 16))" }
        let handlers = ids.map { _ in rig.makeHandler() }
        let requests = ids.map { rig.notification($0) }
        let spy = self.spy
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            _ = handlers[index].didReceive(requests[index], withContentHandler: spy.handler)
        }
        XCTAssertEqual(spy.calls.count, 20)
        XCTAssertEqual(rig.states, Dictionary(uniqueKeysWithValues: ids.map { ($0, "sending") }))
        while rig.scheduler.fireNext() != nil {}
        let transports = rig.transports
        XCTAssertEqual(transports.count, 20, "a session each")
        XCTAssertEqual(Set(rig.requests.flatMap(events).compactMap { $0["notification_id"] as? String }), Set(ids))
        DispatchQueue.concurrentPerform(iterations: transports.count) { index in
            transports[index].complete(0, with: .accepted)
        }
        XCTAssertEqual(rig.states, Dictionary(uniqueKeysWithValues: ids.map { ($0, "sent") }))
        XCTAssertEqual(rig.entries("nse.received_sent").count, 20)
    }

    // MARK: - Secrets

    /// The secret never reaches an entry, also when push-service echoes it in a refusal; the tear-down scans the
    /// entries of every test the same way.
    func test_theSecret_isNeverLogged() throws {
        rig.share()
        receive()
        rig.scheduler.fireNext()
        rig.transports.first?.complete(0, with: .error(403, "forbidden", message: "Device \(ReceiptRig.secret) refused"))
        let refused = try XCTUnwrap(rig.entries("net.client_error").first)
        XCTAssertTrue(refused.message.contains("<redacted>"), refused.message)
        XCTAssertFalse(rig.entries.contains { "\($0.message) \($0.metadata)".contains(ReceiptRig.secret) })
    }
}
