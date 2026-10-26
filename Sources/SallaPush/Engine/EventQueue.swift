import Foundation
import SallaPushCore

extension Engine {
    static let maximumPendingEvents = 500
    static let maximumSeenEvents = 1_000
    /// Events older than 6.5 days are dropped at flush.
    static let maximumEventAge: Double = 6.5 * 86_400
    /// The longest message id push-service stores: 40 characters. One longer id makes it lose the whole batch while
    /// answering 202, so such an event is not recorded, and one queued earlier is dropped at flush.
    static let maximumEventMessageIdLength = MessageId.maximumStoredLength

    // MARK: - Recording

    /// Records events, deduplicated by (message id, type) with a persisted LRU of 1,000 keys. A full queue drops its
    /// oldest event for each new one, and says so once per full episode (WARN `events.queue_full`, `count` = the events
    /// the call that hit the cap dropped): an event that finds room ends the episode, so the next overflow is reported
    /// again (as on Android).
    func recordEvents(_ records: [EventRecord], now: Double) {
        var overflow = 0
        var reported = queueFullReported
        for record in records where MessageId.isValid(record.messageId)
            && record.messageId.utf8.count <= Self.maximumEventMessageIdLength {
            let key = record.messageId + "|" + record.type.rawValue
            guard remember(key) else { continue }
            if events.pending.count >= Self.maximumPendingEvents {
                events.pending.removeFirst(events.pending.count - Self.maximumPendingEvents + 1)
                overflow += 1
            } else {
                reported = false
                queueFullReported = false
            }
            events.pending.append(PendingEvent(id: record.messageId, type: record.type,
                                               at: ISO8601.string(from: record.at), actionId: record.actionId))
            if firstPendingEventAt == nil { firstPendingEventAt = now }
            eventsDirty = true
        }
        guard overflow > 0, !reported else { return }
        queueFullReported = true
        let dropped = overflow == 1 ? "the oldest event was dropped" : "the \(overflow) oldest events were dropped"
        logger.log(.eventsQueueFull,
                   "Event queue full (\(Self.maximumPendingEvents)); \(dropped), and one more is dropped for each new event "
                       + "until events are sent.",
                   metadata: [LogMetadataKey.count: String(overflow)])
    }

    /// Adds `key` to the persisted dedupe list (the oldest dropped past 1,000); false when it was there.
    @discardableResult
    func remember(_ key: String) -> Bool {
        guard seenEvents.insert(key).inserted else { return false }
        events.seen.append(key)
        if events.seen.count > Self.maximumSeenEvents {
            let excess = events.seen.count - Self.maximumSeenEvents
            for old in events.seen.prefix(excess) { seenEvents.remove(old) }
            events.seen.removeFirst(excess)
        }
        eventsDirty = true
        return true
    }

    /// Removes `key` from the dedupe list: the extension is sending that record, and if it gives it back, the app reads
    /// and sends it then.
    func forget(_ key: String) {
        guard seenEvents.remove(key) != nil else { return }
        events.seen.removeAll { $0 == key }
        eventsDirty = true
    }

    // MARK: - Flushing

    /// A foreground, an activation, the background or a background launch sends the events pending now at once. Events
    /// recorded later wait for their batch, 5 s after the first or at 50: the request is not kept for
    /// them, so a foreground with nothing pending makes no later event go alone.
    func requestEventFlush() {
        if !events.pending.isEmpty { forceEventFlush = true }
    }

    /// Events go when 50 are pending, 5 s after the first pending one, or at once on foreground and background;
    /// only once the device is registered.
    func eventsReady(now: Double) -> Bool {
        guard !events.pending.isEmpty, credentials != nil, isReady(eventsRetry, id: eventsRetryId, now: now) else {
            return false
        }
        if forceEventFlush || events.pending.count >= Self.eventsBatch { return true }
        if firstPendingEventAt == nil { firstPendingEventAt = now }
        return now >= (firstPendingEventAt ?? now) + Self.eventsDebounce
    }

    func sendEvents(now: Double) {
        guard let credentials, let client = apiClient() else { return }
        settleWithInbox(now: now)
        let before = events.pending.count
        events.pending.removeAll { event in
            guard let at = ISO8601.seconds(from: event.at) else { return true }
            return now - at > Self.maximumEventAge
        }
        let removed = before - events.pending.count
        if removed > 0 {
            eventsDirty = true
            logger.log(.eventsDropped, "\(removed) events older than 6.5 days were dropped.",
                       metadata: [LogMetadataKey.count: String(removed)])
        }
        // They leave the queue, not just the batch: a queue of nothing else would send an empty batch every 5 s.
        let current = events.pending.count
        events.pending.removeAll { $0.id.utf8.count > Self.maximumEventMessageIdLength }
        let unstorable = current - events.pending.count
        if unstorable > 0 {
            eventsDirty = true
            logger.log(.eventsDropped,
                       "\(unstorable) \(unstorable == 1 ? "event was" : "events were") dropped: the SallaPush server "
                           + "stores message ids of up to \(Self.maximumEventMessageIdLength) characters.",
                       metadata: [LogMetadataKey.count: String(unstorable)])
        }
        guard !events.pending.isEmpty else {
            firstPendingEventAt = nil
            forceEventFlush = false
            return
        }
        let batch = Array(events.pending.prefix(Self.eventsBatch))
        // `at` goes with milliseconds, which events queued by an earlier (pre-release) version lack: push-service loses
        // a batch without them.
        let body = EventsBody(events: batch.map { event in
            EventItem(type: event.type.rawValue, notificationId: event.id,
                      at: ISO8601.seconds(from: event.at).map { ISO8601.string(from: $0) } ?? event.at)
        })
        eventsRetry.lastAttemptAt = now
        let requestId = beginRequest(.events(keys: batch.map { $0.id + "|" + $0.type.rawValue }), now: now)
        let handle = client.events(deviceId: credentials.deviceId, secret: credentials.secret, body: body,
                                   completion: completion(for: requestId) { engine, result, request in
                                       engine.eventsAnswered(result, request: request)
                                   })
        attach(handle, to: requestId, now: now)
    }

    func eventsAnswered(_ result: APIResult<EventsResponse>, request: InFlight) {
        let now = env.clock.now()
        guard case let .events(keys) = request.kind else { return }
        switch result {
        case .success:
            removeSentEvents(keys)
            eventsRetry = RetryState()
            forgetRetry(id: eventsRetryId)
            logger.log(.eventsFlushed, "\(keys.count) \(keys.count == 1 ? "event" : "events") sent.",
                       metadata: [LogMetadataKey.count: String(keys.count)])
            stopReachabilityIfIdle()
        case let .failure(error):
            if handleDeviceRouteFailure(error, now: now) { return }
            // The push service refused the batch itself (a client error with a code, as on Android): it is dropped. A
            // 4xx without a code is no such answer and is retried, so no event is lost to a proxy's or an edge's error.
            if error.isClientError {
                removeSentEvents(keys)
                eventsRetry = RetryState()
                logger.log(.netClientError,
                           "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); "
                               + "\(keys.count) \(keys.count == 1 ? "event was" : "events were") dropped.",
                           metadata: failureMetadata(error))
                return
            }
            applyTransientFailure(error, to: request.kind, now: now)
        }
    }

    private func removeSentEvents(_ keys: [String]) {
        let sent = Set(keys)
        events.pending.removeAll { sent.contains($0.id + "|" + $0.type.rawValue) }
        eventsDirty = true
        if events.pending.isEmpty {
            firstPendingEventAt = nil
            forceEventFlush = false
        } else {
            firstPendingEventAt = env.clock.now()
        }
    }

    // MARK: - Notification Service Extension inbox

    /// The inbox of the configured App Group, if any.
    var inbox: Inbox? {
        guard let group = config.appGroupIdentifier, let container = env.appGroupContainer(group) else { return nil }
        return Inbox(folder: Inbox.folder(inContainer: container))
    }

    /// Reads the `received` events the extension wrote, and settles the app's own against the ones the extension sent or
    /// is sending. Runs on foreground and when a claim of the extension runs out, never in a background launch.
    func ingestInbox(now: Double) {
        guard mode == .main, !isDraining, !isBackgroundLaunch, let inbox else { return }
        let ingestion = inbox.ingest(now: now)
        if ingestion.invalidRemoved > 0 {
            logger.log(.inboxInvalidFile, "An unreadable extension event file was removed.",
                       metadata: [LogMetadataKey.count: String(ingestion.invalidRemoved)])
        }
        for id in ingestion.reported { remember(id + "|" + EventType.received.rawValue) }
        settlePendingReceived(reported: ingestion.reported, reporting: ingestion.reporting)
        // A `.sent` file goes only once the key it gave is on disk: otherwise a relaunch could send its `received` again.
        if !ingestion.sentNames.isEmpty {
            if eventsDirty { persist() }
            if !eventsDirty { inbox.removeSent(ingestion.sentNames) }
        }
        armInboxRecheck(ingestion.nextCheckAt, now: now)
        guard !ingestion.records.isEmpty else { return }
        recordEvents(ingestion.records.map { EventRecord(messageId: $0.messageId, type: .received, at: $0.at, actionId: nil) },
                     now: now)
        logger.log(.inboxIngested, "\(ingestion.records.count) received events read from the notification extension.",
                   metadata: [LogMetadataKey.count: String(ingestion.records.count)])
    }

    /// A pending `received` the extension sent (`reported`) or is sending (`reporting`) is not the app's to send: it
    /// leaves the queue, and for one still being sent its key goes too, so a record the extension gives back is read
    /// and sent then. True when one was removed.
    @discardableResult
    func settlePendingReceived(reported: [String], reporting: [String]) -> Bool {
        let sent = Set(reported)
        let sending = Set(reporting)
        guard !sent.isEmpty || !sending.isEmpty else { return false }
        var removed: Set<String> = []
        events.pending.removeAll { event in
            guard event.type == .received, sent.contains(event.id) || sending.contains(event.id) else { return false }
            removed.insert(event.id)
            return true
        }
        guard !removed.isEmpty else { return false }
        for id in removed.intersection(sending).subtracting(sent) { forget(id + "|" + EventType.received.rawValue) }
        eventsDirty = true
        if events.pending.isEmpty {
            firstPendingEventAt = nil
            forceEventFlush = false
        }
        return true
    }

    /// Before every events request that holds a `received`, also in a background launch: settles those against the
    /// extension's records, and takes over the claims of their ids that the extension hasn't started sending, so the app
    /// sends them itself. It holds those ids first: a claim the extension writes after the scan (the app's
    /// `didReceiveRemoteNotification` can come before the extension runs) then can't be locked, so the extension never
    /// sends one this request sends. The scan never reads a record into the queue or deletes a file, so a background
    /// launch still doesn't upload the inbox.
    func settleWithInbox(now: Double) {
        let ids = Set(events.pending.filter { $0.type == .received }.map(\.id))
        guard !ids.isEmpty, let inbox else { return }
        inbox.hold(ids, now: now)
        let scan = inbox.scan(now: now, takingOver: ids)
        settlePendingReceived(reported: scan.reported, reporting: scan.reporting)
        armInboxRecheck(scan.nextCheckAt, now: now)
    }

    /// Runs a full pass when the earliest fresh `.inflight` claim runs out: the record the extension gave back, or the
    /// one a stopped extension left, is then the app's to send.
    func armInboxRecheck(_ next: Double?, now: Double) {
        guard let next else { return }
        schedule(.inboxRecheck, after: next - now) { engine in
            guard engine.consentMode == .normal else { return }
            engine.ingestInbox(now: engine.env.clock.now())
            engine.requestEventFlush()
        }
    }
}
