import Foundation

/// One `received` event written by the Notification Service Extension.
package struct InboxRecord: Sendable, Equatable {
    package let messageId: String
    /// Seconds since 1970.
    package let at: Double
}

/// A record the extension claimed, to send its `received` itself: `<unix_ms>-<uuid>`, its file name without the state.
package struct InboxClaim: Sendable, Equatable {
    package let name: String
    /// The message whose `received` it holds.
    package let messageId: String
}

/// What the settle-only scan found (`Inbox.scan(now:takingOver:)`): the records the extension sent or is sending.
package struct InboxScan: Sendable {
    /// The message ids of the `.sent` records.
    package var reported: [String] = []
    /// The message ids of the fresh `.inflight` records.
    package var reporting: [String] = []
    /// When the earliest of those claims runs out: its name time plus `Inbox.claimLifetime`.
    package var nextCheckAt: Double?
}

/// The App Group folder through which the extension reports `received` events to the app.
///
/// The extension writes `<unix_ms>-<uuid>.json.tmp` and renames it, so a file appears atomically: to `.json`, which the
/// app sends, or to `.sending` when the extension claims the record to send it itself. Every later step is one rename of
/// that file, which is atomic, so when the app and the extension rename a record at once, exactly one of them wins:
/// - `.sending`: claimed, nothing sent. The app takes it over (back to `.json`) whenever it gets there first, and the
///   extension's send lock then fails.
/// - `.inflight`: the extension's request may be on the wire. Only the extension ends it, as `.sent` or back to `.json`,
///   unless it is `claimLifetime` old.
/// - `.sent`: push-service has it. The app remembers it, then deletes it; the extension prunes it after an hour.
///
/// Before the app sends `received` events, it holds their messages (`<message id>.held`, which a full pass deletes
/// after an hour), then looks for their records: a claim the extension writes after that finds its message held, and
/// its send lock fails, so whatever the order of the app's events and the extension's claim, only one of them sends.
///
/// The app reads, validates, enqueues and deletes `.json`. The event time is in the file name, so no file-timestamp API
/// is needed.
package final class Inbox: Sendable {
    /// Records waiting the extension keeps at most (`.json`, `.sending` and `.inflight`); it stops writing beyond this.
    package static let capacity = 500
    /// Age after which an invalid file or a leftover `.json.tmp` is deleted, and the extension prunes a `.sent` record.
    package static let staleAfter: Double = 3_600
    /// How long an `.inflight` record stays the extension's. The extension gives up 30 s after the notification arrived,
    /// so a record this old (or dated this far ahead, after a clock change) belongs to an extension that stopped, and the
    /// app takes it over.
    package static let claimLifetime: Double = 60
    /// The most bytes read from one file; a record takes about 120.
    package static let maximumFileBytes = 4_096

    /// The inbox folder.
    package let folder: URL

    // 2100-01-01: keeps file-name arithmetic far from overflow whatever the clock says.
    private static let latestTimestamp: Double = 4_102_444_800

    /// The JSON written for one record. `at` is UTC with milliseconds (`ISO8601`); a file an earlier (pre-release)
    /// version's extension wrote has no fraction and is read the same.
    private struct File: Encodable {
        let v: Int
        let type: String
        let messageId: String
        let at: String

        enum CodingKeys: String, CodingKey {
            case v, type, at
            case messageId = "message_id"
        }
    }

    /// A record's state: the suffix of its file name.
    private enum RecordState: String, CaseIterable {
        case json = ".json"
        case sending = ".sending"
        case inflight = ".inflight"
        case sent = ".sent"

        /// The states a record can move on to from this one, in order: where one that left it since a listing is.
        var later: [RecordState] {
            switch self {
            case .sending: return [.inflight, .sent, .json]
            case .inflight: return [.sent, .json]
            case .json, .sent: return []
            }
        }
    }

    /// What a pass over the folder does: a full pass reads records into the queue and takes them over; the settle-only
    /// scan only names what the extension sent or is sending, and takes over the claims of the ids the app holds.
    private enum Pass {
        case full
        case settle(takingOver: Set<String>)
    }

    package init(folder: URL) {
        self.folder = folder
    }

    /// `<App Group container>/Library/Application Support/SallaPush/inbox`.
    package static func folder(inContainer container: URL) -> URL {
        container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SallaPush", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    /// The outcome of a write.
    package enum WriteResult: Equatable, Sendable {
        case written
        case full
        case failed
    }

    /// The outcome of a claim: the claimed record, or why there is none.
    package enum ClaimResult: Equatable, Sendable {
        case claimed(InboxClaim)
        case full
        case failed
    }

    // MARK: - Extension side

    /// Writes one `received` record for the app to send (extension side).
    package func writeReceived(messageId: String, at seconds: Double, uuid: UUID = UUID()) -> WriteResult {
        let safeSeconds = Self.safe(seconds)
        return write(messageId: messageId, at: safeSeconds, name: Self.name(at: safeSeconds, uuid: uuid), as: .json)
    }

    /// Writes one `received` record the extension sends itself, claimed (`.sending`): the app takes it over whenever it
    /// gets there first (extension side).
    package func writeClaimed(messageId: String, at seconds: Double, uuid: UUID = UUID()) -> ClaimResult {
        let safeSeconds = Self.safe(seconds)
        let name = Self.name(at: safeSeconds, uuid: uuid)
        switch write(messageId: messageId, at: safeSeconds, name: name, as: .sending) {
        case .written: return .claimed(InboxClaim(name: name, messageId: messageId))
        case .full: return .full
        case .failed: return .failed
        }
    }

    /// The send lock, taken before the extension's request starts: `.sending` becomes `.inflight`. False when the app
    /// took the claim over first, or holds that message (`hold(_:now:)`), also since before the claim was written: the
    /// app sends that `received`, and the extension must not. A held message's claim stays `.sending` for the app.
    package func lock(_ claim: InboxClaim) -> Bool {
        guard !FileManager.default.fileExists(atPath: heldURL(claim.messageId).path) else { return false }
        return move(claim.name, from: .sending, to: .inflight)
    }

    /// The extension's request was answered: `.inflight` becomes `.sent`. False when the record is gone (the app took it
    /// over).
    package func markSent(_ claim: InboxClaim) -> Bool {
        move(claim.name, from: .inflight, to: .sent)
    }

    /// The extension gives the record back to the app: `.inflight`, or `.sending` when no lock was taken, becomes
    /// `.json`. `.inflight` goes first, so a release that races the lock still finds the record. False when it is in
    /// neither state (the app took it over).
    package func release(_ claim: InboxClaim) -> Bool {
        move(claim.name, from: .inflight, to: .json) || move(claim.name, from: .sending, to: .json)
    }

    /// Writes record `name` as `<name>.json.tmp`, then renames it to its `state`, so it appears atomically. It first
    /// deletes the `.sent` records over an hour old, which bounds them while the app isn't opened, and writes nothing
    /// when `capacity` records wait. `seconds` is already within range.
    private func write(messageId: String, at seconds: Double, name: String, as state: RecordState) -> WriteResult {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        let existing = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in existing where file.hasSuffix(RecordState.sent.rawValue) && isStale(name: file, now: seconds) {
            try? manager.removeItem(at: folder.appendingPathComponent(file))
        }
        if existing.filter(Self.isWaiting).count >= Self.capacity {
            return .full
        }
        let record = File(v: 1, type: "received", messageId: messageId, at: ISO8601.string(from: seconds))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return .failed }
        let temporary = folder.appendingPathComponent(name + ".json.tmp")
        do {
            #if os(iOS)
            try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: temporary)
            #endif
            try manager.moveItem(at: temporary, to: url(name, state))
            return .written
        } catch {
            try? manager.removeItem(at: temporary)
            return .failed
        }
    }

    // MARK: - App side

    /// The result of one ingestion pass.
    package struct Ingestion: Sendable {
        /// The records to queue: the `.json` ones, and the claims taken over.
        package var records: [InboxRecord] = []
        package var invalidRemoved = 0
        /// The message ids of the `.sent` records: the extension sent them.
        package var reported: [String] = []
        /// The file names of those records, for `removeSent(_:)`.
        package var sentNames: [String] = []
        /// The message ids of the fresh `.inflight` records, which are kept: the extension is sending them.
        package var reporting: [String] = []
        /// When the earliest of those claims runs out: its name time plus `claimLifetime`.
        package var nextCheckAt: Double?
    }

    /// The full pass (app side). It reads, validates, enqueues and deletes every `.json` record. It takes over every
    /// `.sending` claim, and every `.inflight` one that is `claimLifetime` old (or dated that far ahead), and reads it as
    /// `.json`. It keeps a fresh `.inflight` record and names it, and names every `.sent` one without deleting it. An
    /// invalid file is deleted only once its file-name time is more than an hour old; so is a leftover `.json.tmp`.
    package func ingest(now: Double) -> Ingestion {
        ingest(now: now, names: listing())
    }

    /// `ingest(now:)` over `names`, a listing that may be stale: a `.sending` or `.inflight` record the extension renamed
    /// since is looked for in the states it can have moved on to, in order, once each.
    func ingest(now: Double, names: [String]) -> Ingestion {
        walk(names, .full, now: now)
    }

    /// The settle-only scan (app side), before the app sends its own `received` events, also in a background launch. It
    /// names the `.sent` records and the fresh `.inflight` ones, and takes over the `.sending` claims of `ids` (the
    /// message ids the app holds a `received` of), so the app sends those itself. It never reads a record into the queue
    /// and never deletes a file: the next full pass reads a claim it took over.
    package func scan(now: Double, takingOver ids: Set<String>) -> InboxScan {
        scan(now: now, takingOver: ids, names: listing())
    }

    /// `scan(now:takingOver:)` over `names`, a listing that may be stale, as `ingest(now:names:)`.
    func scan(now: Double, takingOver ids: Set<String>, names: [String]) -> InboxScan {
        let found = walk(names, .settle(takingOver: ids), now: now)
        return InboxScan(reported: found.reported, reporting: found.reporting, nextCheckAt: found.nextCheckAt)
    }

    /// Holds the messages `ids` (app side): the app holds a `received` of each, which it sends unless their records
    /// show that the extension sent or is sending it, and it looks for those records only after this. A claim the
    /// extension writes from now on finds its message held and can't take the send lock. One `<message id>.held` file
    /// each, never written over, with the time the message was first held; a full pass deletes it after an hour. The
    /// extension then leaves that `received` to the app, also when the app's request fails: the app sends it again.
    package func hold(_ ids: Set<String>, now: Double) {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let at = ISO8601.string(from: Self.safe(now))
        for id in ids where MessageId.isValid(id) {
            guard let data = try? encoder.encode(File(v: 1, type: "received", messageId: id, at: at)) else { continue }
            #if os(iOS)
            try? data.write(to: heldURL(id), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: heldURL(id), options: [.withoutOverwriting])
            #endif
        }
    }

    /// Deletes the `.sent` records `names` (app side), once the dedupe list that holds their keys is on disk.
    package func removeSent(_ names: [String]) {
        for name in names where name.hasSuffix(RecordState.sent.rawValue) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The folder's file names; none when it can't be listed (it doesn't exist yet).
    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// Applies `pass` to every record of `names`, in name order (time first).
    private func walk(_ names: [String], _ pass: Pass, now: Double) -> Ingestion {
        var result = Ingestion()
        for file in names.sorted() {
            if file.hasSuffix(".json.tmp") {
                if case .full = pass, isStale(name: file, now: now) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
                }
                continue
            }
            if file.hasSuffix(".held") {
                if case .full = pass { removeIfStale(held: file, now: now) }
                continue
            }
            guard let state = RecordState.allCases.first(where: { file.hasSuffix($0.rawValue) }) else { continue }
            visit(String(file.dropLast(state.rawValue.count)), in: state, pass, now: now, into: &result)
        }
        return result
    }

    /// Applies `pass` to record `name` in `state`. A record that left `state` since the listing (the extension renamed
    /// it) is looked for in the states it can have moved on to, in order, once each, and handled where it is found.
    private func visit(_ name: String, in state: RecordState, _ pass: Pass, now: Double, into result: inout Ingestion) {
        guard !apply(pass, to: name, in: state, now: now, into: &result) else { return }
        for later in state.later where FileManager.default.fileExists(atPath: url(name, later).path) {
            return visit(name, in: later, pass, now: now, into: &result)
        }
    }

    /// The rule of `pass` for record `name` in `state`. False when the record isn't in that state any more.
    private func apply(_ pass: Pass, to name: String, in state: RecordState, now: Double,
                       into result: inout Ingestion) -> Bool {
        switch (state, pass) {
        case (.json, .full):
            readIn(name, now: now, into: &result)
        case (.json, .settle):
            break
        case (.sending, .full):
            // The extension hasn't started sending it: the app takes it over, and the extension's lock then fails.
            guard move(name, from: .sending, to: .json) else { return false }
            readIn(name, now: now, into: &result)
        case let (.sending, .settle(ids)):
            return takeOver(name, ifTheAppHolds: ids)
        case (.inflight, _):
            return applyToInflight(pass, name, now: now, into: &result)
        case (.sent, _):
            noteSent(name, pass, now: now, into: &result)
        }
        return true
    }

    /// Reads `.json` record `name` into the queue and deletes it. An invalid one is deleted once an hour old.
    private func readIn(_ name: String, now: Double, into result: inout Ingestion) {
        if let data = Self.readBounded(url(name, .json)), let record = Self.decode(data) {
            result.records.append(record)
            try? FileManager.default.removeItem(at: url(name, .json))
        } else if isStale(name: name, now: now) {
            try? FileManager.default.removeItem(at: url(name, .json))
            result.invalidRemoved += 1
        }
    }

    /// The settle's rule for claim `name`: taken over when the app holds a `received` of its message id. False when the
    /// claim isn't `.sending` any more.
    private func takeOver(_ name: String, ifTheAppHolds ids: Set<String>) -> Bool {
        guard let data = Self.readBounded(url(name, .sending)) else { return false }
        guard let record = Self.decode(data), ids.contains(record.messageId) else { return true }
        return move(name, from: .sending, to: .json)
    }

    /// The rule for `.inflight` record `name`. A fresh one (dated less than `claimLifetime` from now) is the extension's:
    /// it is kept and named. A full pass takes any other over (a stopped extension's, or one a clock change dated far
    /// from now) and reads it in. False when the record isn't `.inflight` any more.
    private func applyToInflight(_ pass: Pass, _ name: String, now: Double, into result: inout Ingestion) -> Bool {
        if let time = Self.time(of: name), now < time + Self.claimLifetime, time < now + Self.claimLifetime {
            guard let data = Self.readBounded(url(name, .inflight)) else { return false }
            if let record = Self.decode(data) {
                result.reporting.append(record.messageId)
                result.nextCheckAt = min(result.nextCheckAt ?? .infinity, time + Self.claimLifetime)
            }
            return true
        }
        guard case .full = pass else { return true }
        guard move(name, from: .inflight, to: .json) else { return false }
        readIn(name, now: now, into: &result)
        return true
    }

    /// Names `.sent` record `name`, which only `removeSent(_:)` deletes. A full pass deletes an unreadable one once an
    /// hour old.
    private func noteSent(_ name: String, _ pass: Pass, now: Double, into result: inout Ingestion) {
        if let data = Self.readBounded(url(name, .sent)), let record = Self.decode(data) {
            result.reported.append(record.messageId)
            result.sentNames.append(name + RecordState.sent.rawValue)
        } else if case .full = pass, isStale(name: name, now: now) {
            try? FileManager.default.removeItem(at: url(name, .sent))
            result.invalidRemoved += 1
        }
    }

    /// Renames record `name` from one state to another: one `rename(2)`, so when the app and the extension rename a
    /// record at once, exactly one succeeds. False when the record isn't in `source` (any more).
    private func move(_ name: String, from source: RecordState, to target: RecordState) -> Bool {
        (try? FileManager.default.moveItem(at: url(name, source), to: url(name, target))) != nil
    }

    private func url(_ name: String, _ state: RecordState) -> URL {
        folder.appendingPathComponent(name + state.rawValue)
    }

    /// `<message id>.held`: the app holds that message's `received`.
    private func heldURL(_ messageId: String) -> URL {
        folder.appendingPathComponent(messageId + ".held")
    }

    /// Deletes held message `file` once it was held over an hour ago, or when it is unreadable.
    private func removeIfStale(held file: String, now: Double) {
        let url = folder.appendingPathComponent(file)
        if let data = Self.readBounded(url), let held = Self.decode(data), now - held.at <= Self.staleAfter { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether `file` is a record waiting to be sent: `.json`, `.sending` or `.inflight`.
    private static func isWaiting(_ file: String) -> Bool {
        [RecordState.json, .sending, .inflight].contains { file.hasSuffix($0.rawValue) }
    }

    /// `<unix_ms>-<uuid lowercase>`: the time first, so a record sorts and ages by it in every state.
    private static func name(at seconds: Double, uuid: UUID) -> String {
        "\(Int64((seconds * 1_000).rounded(.down)))-\(uuid.uuidString.lowercased())"
    }

    /// `seconds`, within 1970 and 2100.
    private static func safe(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), latestTimestamp) : 0
    }

    private func isStale(name: String, now: Double) -> Bool {
        guard let time = Self.time(of: name) else { return true }
        return now - time > Self.staleAfter
    }

    /// The time a file name starts with, in seconds since 1970.
    private static func time(of name: String) -> Double? {
        Int64(name.prefix(while: { $0 != "-" })).map { Double($0) / 1_000 }
    }

    /// At most `maximumFileBytes + 1` bytes of the file, so a file of any size is never read whole.
    private static func readBounded(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximumFileBytes + 1)
    }

    /// A valid record, or nil. Oversized or deeply nested text never reaches the (recursive) JSON parser.
    static func decode(_ data: Data) -> InboxRecord? {
        guard data.count <= maximumFileBytes, DepthLimit.jsonFits(data, maxDepth: JSONValue.maximumDepth),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["v"] as? NSNumber)?.intValue == 1,
              object["type"] as? String == "received",
              let messageId = MessageId.validated(object["message_id"]),
              let at = (object["at"] as? String).flatMap(ISO8601.seconds(from:))
        else { return nil }
        return InboxRecord(messageId: messageId, at: at)
    }
}
