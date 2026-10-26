import Foundation
@testable import SallaPushCore
import XCTest

/// The states of an App Group record when the extension sends `received` itself: `.sending` (claimed), `.inflight` (its
/// request may be on the wire), `.sent`, and `.json` for the app. Every step is one rename, so the app and the extension
/// never both own a record.
final class InboxStatesTests: XCTestCase {
    private var folder: URL = FileManager.default.temporaryDirectory
    private var inbox = Inbox(folder: FileManager.default.temporaryDirectory)
    private let now: Double = 1_790_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-states-\(UUID().uuidString)")
        inbox = Inbox(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A claim of `messageId` written at `seconds`, moved on the way the extension moves it: locked (`.inflight`), then
    /// marked sent (`.sent`).
    private func claim(_ messageId: String, at seconds: Double, locked: Bool = false, sent: Bool = false) throws -> InboxClaim {
        let claim = try XCTUnwrap(inbox.writeClaimed(messageId: messageId, at: seconds).claim)
        if locked || sent { XCTAssertTrue(inbox.lock(claim)) }
        if sent { XCTAssertTrue(inbox.markSent(claim)) }
        return claim
    }

    private func write(_ text: String, to file: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(file))
    }

    func test_claim_writesSending() throws {
        let claim = try XCTUnwrap(inbox.writeClaimed(messageId: "msg_ab", at: now + 0.123).claim)
        XCTAssertTrue(claim.name.hasPrefix("1790000000123-"), claim.name)
        XCTAssertEqual(names, [claim.name + ".sending"], "no .json.tmp is left, and no .json is written")
        let data = try Data(contentsOf: folder.appendingPathComponent(claim.name + ".sending"))
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(written as NSDictionary,
                       ["v": 1, "type": "received", "message_id": "msg_ab", "at": "2026-09-21T14:13:20.123Z"] as NSDictionary)
        let record = try XCTUnwrap(Inbox.decode(data), "the record the app reads, once it takes the claim over")
        XCTAssertEqual(record.messageId, "msg_ab")
        XCTAssertEqual(record.at, now + 0.123, accuracy: 0.000_5)
    }

    /// The lock is the claim's one rename to `.inflight`; once the app took the claim over, it fails,
    /// and the record stays the app's.
    func test_lock_renamesSendingToInflight_once_andFailsAfterATakeover() throws {
        let locked = try claim("msg_ab", at: now)
        XCTAssertTrue(inbox.lock(locked))
        XCTAssertEqual(names, [locked.name + ".inflight"])
        XCTAssertFalse(inbox.lock(locked), "a record is locked once")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(locked.name + ".inflight"))

        let taken = try claim("msg_cd", at: now)
        XCTAssertEqual(inbox.scan(now: now, takingOver: ["msg_cd"]).reporting, [])
        XCTAssertEqual(names, [taken.name + ".json"], "the app took the claim over")
        XCTAssertFalse(inbox.lock(taken))
        XCTAssertEqual(names, [taken.name + ".json"], "the failed lock renames nothing")
        XCTAssertEqual(inbox.ingest(now: now).records.map(\.messageId), ["msg_cd"])
    }

    func test_markSent_andRelease_reportAGoneRecord() throws {
        let sent = try claim("msg_a1", at: now, locked: true)
        XCTAssertTrue(inbox.markSent(sent))
        XCTAssertFalse(inbox.markSent(sent), "it is .sent already")
        XCTAssertFalse(inbox.release(sent), "a sent record is never given back")
        XCTAssertTrue(names.contains(sent.name + ".sent"))

        let inflight = try claim("msg_a2", at: now, locked: true)
        XCTAssertTrue(inbox.release(inflight), "from .inflight")
        XCTAssertTrue(names.contains(inflight.name + ".json"))
        XCTAssertFalse(inbox.release(inflight), "neither .inflight nor .sending any more")

        let sending = try claim("msg_a3", at: now)
        XCTAssertTrue(inbox.release(sending), "from .sending, when no lock was taken")
        XCTAssertTrue(names.contains(sending.name + ".json"))

        let taken = try claim("msg_a4", at: now, locked: true)
        try FileManager.default.moveItem(at: folder.appendingPathComponent(taken.name + ".inflight"),
                                         to: folder.appendingPathComponent(taken.name + ".json"))
        XCTAssertFalse(inbox.markSent(taken), "the app took it over")
        XCTAssertFalse(inbox.release(taken))
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 3)
    }

    func test_ingest_takesOverEverySending_atOnce() throws {
        let older = try claim("msg_a1", at: now - 30)
        let fresh = try claim("msg_a2", at: now)
        let ingestion = inbox.ingest(now: now)
        XCTAssertEqual(ingestion.records, [InboxRecord(messageId: "msg_a1", at: now - 30), InboxRecord(messageId: "msg_a2", at: now)])
        XCTAssertTrue(names.isEmpty)
        XCTAssertFalse(inbox.lock(older))
        XCTAssertFalse(inbox.lock(fresh), "the extension's lock fails: the app sends it")
        XCTAssertEqual(ingestion.reporting, [])
        XCTAssertNil(ingestion.nextCheckAt)
    }

    func test_ingest_keepsAFreshInflight_andSaysWhenItRunsOut() throws {
        let first = try claim("msg_a1", at: now - 10.5, locked: true)
        let second = try claim("msg_a2", at: now - 2, locked: true)
        let ingestion = inbox.ingest(now: now)
        XCTAssertTrue(ingestion.records.isEmpty)
        XCTAssertEqual(ingestion.reporting, ["msg_a1", "msg_a2"])
        XCTAssertEqual(try XCTUnwrap(ingestion.nextCheckAt), now - 10.5 + Inbox.claimLifetime, accuracy: 0.000_5,
                       "the earliest claim's end")
        XCTAssertEqual(names, [first.name + ".inflight", second.name + ".inflight"], "kept: the extension is sending them")
        XCTAssertTrue(inbox.markSent(first))
    }

    /// A claim `claimLifetime` old belongs to an extension that stopped; one dated that far ahead too (the clock moved).
    func test_ingest_takesOverAnInflightSixtySecondsOld_andOneFromTheFuture() throws {
        let old = try claim("msg_a1", at: now - Inbox.claimLifetime, locked: true)
        let ahead = try claim("msg_a2", at: now + Inbox.claimLifetime, locked: true)
        let fresh = try claim("msg_a3", at: now - Inbox.claimLifetime + 1, locked: true)
        let ingestion = inbox.ingest(now: now)
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_a1", "msg_a2"])
        XCTAssertEqual(ingestion.reporting, ["msg_a3"])
        XCTAssertEqual(names, [fresh.name + ".inflight"])
        XCTAssertFalse(inbox.markSent(old), "the extension finds it gone")
        XCTAssertFalse(inbox.release(ahead))
    }

    func test_ingest_namesSentRecords_withoutDeletingThem_andRemoveSentDeletesThem() throws {
        let sent = try claim("msg_a1", at: now - 5, sent: true)
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_a2", at: now - 4), .written)
        try write("not json", to: "1789990000000-bad.sent")
        try write("not json", to: "1790000000000-new.sent")
        try write("not json", to: "1790000000000-new.json")
        let ingestion = inbox.ingest(now: now)
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_a2"])
        XCTAssertEqual(ingestion.reported, ["msg_a1"])
        XCTAssertEqual(ingestion.sentNames, [sent.name + ".sent"])
        XCTAssertEqual(ingestion.invalidRemoved, 1, "an unreadable .sent goes once an hour old")
        XCTAssertEqual(names, [sent.name + ".sent", "1790000000000-new.json", "1790000000000-new.sent"],
                       "the valid .sent stays for the app; unreadable fresh files wait for their hour")
        inbox.removeSent(ingestion.sentNames + ["1790000000000-new.json"])
        XCTAssertEqual(names, ["1790000000000-new.json", "1790000000000-new.sent"], "only the .sent records named go")
    }

    /// The extension renames a record between the app's listing and its read; the app finds it where
    /// it went, so it never takes for absent a record the extension sent or is sending.
    func test_ingest_findsARecordRenamedSinceTheListing() throws {
        let locked = try claim("msg_a1", at: now, locked: true)
        let lockedLater = inbox.ingest(now: now, names: [locked.name + ".sending"])
        XCTAssertEqual(lockedLater.reporting, ["msg_a1"], ".sending → .inflight")
        XCTAssertTrue(lockedLater.records.isEmpty)
        XCTAssertEqual(names, [locked.name + ".inflight"])

        XCTAssertTrue(inbox.markSent(locked))
        let sentLater = inbox.ingest(now: now, names: [locked.name + ".inflight"])
        XCTAssertEqual(sentLater.reported, ["msg_a1"], ".inflight → .sent")
        XCTAssertEqual(sentLater.sentNames, [locked.name + ".sent"])
        inbox.removeSent(sentLater.sentNames)

        let released = try claim("msg_a2", at: now)
        XCTAssertTrue(inbox.release(released))
        let releasedLater = inbox.ingest(now: now, names: [released.name + ".sending"])
        XCTAssertEqual(releasedLater.records, [InboxRecord(messageId: "msg_a2", at: now)], ".sending → .json")
        XCTAssertTrue(names.isEmpty)

        let scanned = try claim("msg_a3", at: now, locked: true)
        XCTAssertEqual(inbox.scan(now: now, takingOver: ["msg_a3"], names: [scanned.name + ".sending"]).reporting, ["msg_a3"],
                       "the scan finds it too, and leaves it to the extension")
        XCTAssertEqual(names, [scanned.name + ".inflight"])
    }

    func test_scan_takesOverOnlyTheNamedClaims_andNeverIngestsOrDeletes() throws {
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_a1", at: now - 7_200), .written)
        let named = try claim("msg_a2", at: now - 20)
        let other = try claim("msg_a3", at: now - 20)
        let fresh = try claim("msg_a4", at: now - 10, locked: true)
        let stale = try claim("msg_a5", at: now - 600, locked: true)
        let sent = try claim("msg_a6", at: now - 5, sent: true)
        try write("{}", to: "1789990000000-a.json.tmp")
        try write("not json", to: "1789990000000-b.json")
        try write("not json", to: "1789990000000-c.sent")
        let before = names.filter { !$0.hasPrefix(named.name) }

        let scan = inbox.scan(now: now, takingOver: ["msg_a2", "msg_a4", "msg_a7"])
        XCTAssertEqual(scan.reported, ["msg_a6"])
        XCTAssertEqual(scan.reporting, ["msg_a4"])
        XCTAssertEqual(try XCTUnwrap(scan.nextCheckAt), now - 10 + Inbox.claimLifetime, accuracy: 0.000_5)
        XCTAssertTrue(names.contains(named.name + ".json"), "a claim of an id the app holds is taken over")
        XCTAssertEqual(names.filter { !$0.hasPrefix(named.name) }, before, "nothing else is renamed, read in or deleted")
        XCTAssertTrue(names.contains(other.name + ".sending"))
        XCTAssertTrue(names.contains(fresh.name + ".inflight"))
        XCTAssertTrue(names.contains(stale.name + ".inflight"), "an old claim waits for a full pass")
        XCTAssertTrue(names.contains(sent.name + ".sent"))
        XCTAssertFalse(inbox.lock(named))
        XCTAssertTrue(inbox.lock(other))
    }

    /// The app holds the messages whose `received` it is about to send, before it looks for their records: a claim the
    /// extension writes after that can't take the lock and stays `.sending` for the app, which reads it in at its next
    /// pass. Other messages' claims lock as before.
    func test_aHeldMessage_failsTheLockOfAClaimWrittenLater() throws {
        inbox.hold(["msg_ab"], now: now)
        XCTAssertEqual(names, ["msg_ab.held"])
        XCTAssertEqual(inbox.scan(now: now, takingOver: ["msg_ab"]).reported, [], "a held message is no record")
        let late = try claim("msg_ab", at: now + 1)
        let other = try claim("msg_cd", at: now + 1)
        XCTAssertFalse(inbox.lock(late), "the app sends it")
        XCTAssertTrue(inbox.lock(other))
        XCTAssertEqual(names, [late.name + ".sending", other.name + ".inflight", "msg_ab.held"].sorted())
        XCTAssertEqual(inbox.ingest(now: now + 2).records.map(\.messageId), ["msg_ab"], "taken over and read, as any claim")
    }

    /// A held message's file is no record: no pass reads it in or names it, and it is written once, with the time the
    /// message was first held. A full pass deletes it once that is over an hour ago, or when it is unreadable; the scan
    /// never does.
    func test_heldMessages_areNoRecords_andAFullPassDeletesThemAfterAnHour() throws {
        inbox.hold(["msg_a1"], now: now)
        inbox.hold(["msg_a1", "msg_a2", "not an id"], now: now + 600)
        try write("not json", to: "msg_a3.held")
        XCTAssertEqual(names, ["msg_a1.held", "msg_a2.held", "msg_a3.held"])
        let first = try XCTUnwrap(Inbox.decode(Data(contentsOf: folder.appendingPathComponent("msg_a1.held"))))
        XCTAssertEqual(first.at, now, accuracy: 0.000_5, "never written over")
        let scan = inbox.scan(now: now + 7_200, takingOver: ["msg_a1", "msg_a2"])
        XCTAssertEqual(scan.reported + scan.reporting, [])
        XCTAssertEqual(names.count, 3, "the scan deletes nothing")
        let pass = inbox.ingest(now: now + Inbox.staleAfter + 1)
        XCTAssertTrue(pass.records.isEmpty)
        XCTAssertEqual(pass.invalidRemoved, 0, "the app's own file is no extension record")
        XCTAssertEqual(names, ["msg_a2.held"], "the one held over an hour ago and the unreadable one go")
        _ = inbox.ingest(now: now + 600 + Inbox.staleAfter)
        XCTAssertEqual(names, ["msg_a2.held"], "an hour exactly: kept")
        _ = inbox.ingest(now: now + 601 + Inbox.staleAfter)
        XCTAssertTrue(names.isEmpty)
    }

    func test_capacity_countsSendingAndInflight() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<Inbox.capacity {
            let state = [".json", ".sending", ".inflight"][index % 3]
            try Data().write(to: folder.appendingPathComponent("1790000000000-\(index)\(state)"))
        }
        try Data().write(to: folder.appendingPathComponent("1790000000000-sent.sent"))
        inbox.hold(["msg_cd"], now: now)
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_ab", at: now), .full)
        XCTAssertEqual(inbox.writeClaimed(messageId: "msg_ab", at: now), .full)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("1790000000000-1.sending"))
        XCTAssertNotNil(inbox.writeClaimed(messageId: "msg_ab", at: now).claim,
                        "neither a .sent record nor a held message waits for anything")
    }

    /// The extension bounds the `.sent` records while the app isn't opened: each write deletes those over an hour old.
    func test_extensionWrites_dropSentRecordsOlderThanAnHour() throws {
        let stale = try claim("msg_a1", at: now - Inbox.staleAfter - 1, sent: true)
        let kept = try claim("msg_a2", at: now - Inbox.staleAfter + 1, sent: true)
        let waiting = try claim("msg_a3", at: now - 2 * Inbox.staleAfter, locked: true)
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_a4", at: now), .written)
        XCTAssertFalse(names.contains(stale.name + ".sent"))
        XCTAssertTrue(names.contains(kept.name + ".sent"))
        XCTAssertTrue(names.contains(waiting.name + ".inflight"), "only .sent records are pruned")
        XCTAssertEqual(names.count, 3)
        XCTAssertNotNil(inbox.writeClaimed(messageId: "msg_a5", at: now + 2).claim)
        XCTAssertFalse(names.contains(kept.name + ".sent"), "a claim prunes too")
    }

    func test_anInflight_isNeverTakenOverBeforeItsLifetime() throws {
        XCTAssertEqual(Inbox.claimLifetime, 60)
        let arrival = now + 0.123
        let claim = try claim("msg_ab", at: arrival, locked: true)
        for elapsed in [0, 1, 30, 59.9] {
            XCTAssertEqual(inbox.ingest(now: arrival + elapsed).reporting, ["msg_ab"], "\(elapsed) s")
            XCTAssertEqual(inbox.scan(now: arrival + elapsed, takingOver: ["msg_ab"]).reporting, ["msg_ab"])
        }
        XCTAssertEqual(inbox.scan(now: arrival + 3_600, takingOver: ["msg_ab"]).reporting, [], "the scan never takes it over")
        XCTAssertEqual(names, [claim.name + ".inflight"])
        // The recheck runs at the time the pass named, which is when the claim has run out.
        let end = try XCTUnwrap(inbox.ingest(now: arrival).nextCheckAt)
        XCTAssertEqual(inbox.ingest(now: end).records.map(\.messageId), ["msg_ab"])
        XCTAssertFalse(inbox.markSent(claim))
    }

    /// push-service stores message ids of at most 40 characters: the app records events only for those, and the
    /// extension claims only those.
    func test_storableMessageIds_areAtMostFortyCharacters() {
        XCTAssertEqual(MessageId.maximumStoredLength, 40)
        XCTAssertTrue(MessageId.isStorable("msg_" + String(repeating: "a", count: 36)))
        XCTAssertFalse(MessageId.isStorable("msg_" + String(repeating: "a", count: 37)))
        XCTAssertFalse(MessageId.isStorable("msg_XYZ"))
        XCTAssertFalse(MessageId.isStorable(""))
    }
}

private extension Inbox.ClaimResult {
    /// The claim, when the record was written.
    var claim: InboxClaim? {
        if case let .claimed(claim) = self { return claim }
        return nil
    }
}
