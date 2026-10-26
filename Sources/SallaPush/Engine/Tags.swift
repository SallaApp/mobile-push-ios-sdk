import Foundation
import SallaPushCore

/// One change of an `addTags` or `removeTags` call, normalised as the engine normalises it; a nil value removes the key.
struct TagChange: Equatable, Sendable {
    let key: String
    let value: String?
}

/// The tag rules, shared by the engine and the getters' anticipation of a call (`GetterView`).
enum TagRules {
    /// The most tags a device may hold.
    static let maximumTags = 100

    /// The locale keys are lowercased in, created once.
    private static let keyLocale = Locale(identifier: "en_US_POSIX")

    /// The key as sent: trimmed and lowercased (`en_US_POSIX`); nil when it still does not match `^[a-z0-9_]{1,64}$`.
    static func normalizedKey(_ raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: keyLocale)
        return Validation.isLowerIdentifier(lowered) ? lowered : nil
    }

    /// The value as sent: at most 255 UTF-16 units, cut on whole scalars.
    static func normalizedValue(_ raw: String) -> String {
        raw.utf16.count > FieldLimit.tagValue ? raw.truncatedUTF16(FieldLimit.tagValue) : raw
    }

    /// The changes of an `addTags` call in the order the engine applies them (by raw key): invalid keys are skipped and
    /// an empty value removes the key.
    static func changes(adding tags: [String: String]) -> [TagChange] {
        tags.sorted { $0.key < $1.key }.compactMap { raw in
            normalizedKey(raw.key).map { TagChange(key: $0, value: raw.value.isEmpty ? nil : normalizedValue(raw.value)) }
        }
    }

    /// The changes of a `removeTags` call; invalid keys are skipped.
    static func changes(removing keys: [String]) -> [TagChange] {
        keys.compactMap { normalizedKey($0).map { TagChange(key: $0, value: nil) } }
    }

    /// Applies changes to the effective `tags` as the engine does: a removal drops the key, and a new key beyond the
    /// limit is dropped. `launchTags`, kept while the identity is unknown, follows every change it accepts.
    static func apply(_ changes: [TagChange], to tags: inout [String: String], recordingIn launchTags: inout [String: String]?) {
        for change in changes {
            guard let value = change.value else {
                tags.removeValue(forKey: change.key)
                launchTags?.removeValue(forKey: change.key)
                continue
            }
            if tags[change.key] != nil || tags.count < maximumTags {
                tags[change.key] = value
                launchTags?[change.key] = value
            }
        }
    }

    /// Whether adding `value` needs no request: the mirror holds that value and is what the server holds
    /// (`mirrorIsServerTruth`). The tags the app sees are the same either way, so the getters need no rule of their own
    /// (Android's `TagRules.addChangesNothing`).
    static func addChangesNothing(mirrorValue: String?, value: String, mirrorIsServerTruth: Bool) -> Bool {
        mirrorIsServerTruth && mirrorValue == value
    }

    /// Whether removing a key needs no request: the key is not in the mirror, the server holds no tags at all, and no
    /// tags request on the wire can add it (Android's `TagRules.removeChangesNothing`).
    static func removeChangesNothing(inMirror: Bool, serverHoldsNoTags: Bool, tagsRequestOnTheWire: Bool) -> Bool {
        !inMirror && serverHoldsNoTags && !tagsRequestOnTheWire
    }
}

extension Engine {
    // MARK: - Calls

    func handleAddTags(_ tags: [String: String], now: Double) {
        var dropped = 0
        for (rawKey, rawValue) in tags.sorted(by: { $0.key < $1.key }) {
            guard let key = normalizedTagKey(rawKey) else { continue }
            if rawValue.isEmpty {
                removeTag(key)
                continue
            }
            let value = TagRules.normalizedValue(rawValue)
            if value != rawValue {
                logger.log(.tagsValueTruncated, "Tag value for \"\(key)\" was longer than 255 characters; truncated.")
            }
            let effective = state.tags.effective
            if effective[key] == nil && effective.count >= TagRules.maximumTags {
                dropped += 1
                continue
            }
            recordLaunchTag(key, value, effective: effective)
            state.tags.pendingRemove.removeValue(forKey: key)
            if TagRules.addChangesNothing(mirrorValue: state.tags.mirror[key], value: value,
                                          mirrorIsServerTruth: mirrorIsServerTruth) {
                // The server already holds this value: a pending change of the key goes, and nothing is sent for it.
                state.tags.pendingAdd.removeValue(forKey: key)
            } else {
                state.tags.pendingAdd[key] = PendingTagAdd(v: value, epoch: epoch)
            }
            stateDirty = true
        }
        if dropped > 0 {
            let additions = dropped == 1 ? "addition" : "additions"
            logger.log(.tagsLimit, "More than \(TagRules.maximumTags) tags; \(dropped) \(additions) dropped.",
                       metadata: [LogMetadataKey.count: String(dropped)])
        }
        scheduleTagsFlush(now: now)
    }

    func handleRemoveTags(_ keys: [String], now: Double) {
        for rawKey in keys {
            guard let key = normalizedTagKey(rawKey) else { continue }
            removeTag(key)
        }
        scheduleTagsFlush(now: now)
    }

    private func removeTag(_ key: String) {
        launchTags.removeValue(forKey: key)
        state.tags.pendingAdd.removeValue(forKey: key)
        let changesNothing = TagRules.removeChangesNothing(
            inMirror: state.tags.mirror[key] != nil,
            serverHoldsNoTags: identity.serverTags == .none && tagsReachTheKnownRow,
            tagsRequestOnTheWire: isTagsRequestInFlight)
        if changesNothing {
            state.tags.pendingRemove.removeValue(forKey: key)
        } else {
            state.tags.pendingRemove[key] = epoch
        }
        stateDirty = true
    }

    /// Whether the tag mirror is what the server holds, now and when the next tags request can go (Android's
    /// `mirrorIsServerTruth`): the device is registered (`tagsReachTheKnownRow`), the last tags answer reported tags
    /// (`server_tags` is `some`, which only a tags answer sets, together with the mirror), no tags request is on the
    /// wire (its answer changes the server's tags), and no identity op queued before the next tags request still clears
    /// the server's tags (a logout, or a login of another customer, with `clearTagsOnLogout`). An empty mirror never
    /// stands for the tags of `some`: a crash between the two file writes of an identity call can leave that pair.
    var mirrorIsServerTruth: Bool {
        identity.serverTags == .some && !state.tags.mirror.isEmpty && tagsReachTheKnownRow && !isTagsRequestInFlight
            && !identity.ops.contains { $0.clearsTagsNext }
    }

    /// Whether the next tags request reaches the row that `server_tags` and the mirror describe. While the device
    /// registers again (its credentials are dropped until that is answered) the row is not known, and the answer sets
    /// `server_tags` again. Until then neither suppression applies.
    var tagsReachTheKnownRow: Bool {
        credentials != nil
    }

    // MARK: - The tags of a launch whose identity is unknown

    /// Records a tag the app set while the identity is unknown, for the launch `logout()`. At the limit the tags the
    /// getters no longer show go first, so at most 100 are kept.
    private func recordLaunchTag(_ key: String, _ value: String, effective: [String: String]) {
        guard identity.desired == .unknown else { return }
        if launchTags[key] == nil, launchTags.count >= TagRules.maximumTags {
            launchTags = launchTags.filter { effective[$0.key] == $0.value }
        }
        launchTags[key] = value
    }

    /// The tags a `logout()` keeps while the identity is unknown: those the app set in this launch that the getters still
    /// show (an answer or a rejected key may have removed one since).
    var keptLaunchTags: [String: String] {
        let effective = state.tags.effective
        return launchTags.filter { effective[$0.key] == $0.value }
    }

    /// What a sign-out or an account switch with `clearTagsOnLogout` does to SallaPush's copy of the tags:
    /// the mirror and every unsent change go, except `kept`, the tags the app set in this launch while the identity was
    /// unknown. Those the server is known to hold stay in the mirror; the others are sent again after the
    /// identity op that clears the server's tags, stamped with the current epoch, so the answer to a tags request still
    /// on the wire never settles them.
    func dropTagChanges(keeping kept: [String: String], now: Double) {
        let confirmed = mirrorIsServerTruth ? state.tags.mirror.filter { kept[$0.key] == $0.value } : [:]
        state.tags.pendingAdd = kept.filter { confirmed[$0.key] == nil }.mapValues { PendingTagAdd(v: $0, epoch: epoch) }
        state.tags.pendingRemove = [:]
        resetTagMirror()
        state.tags.mirror = confirmed
        launchTags = [:]
        if state.tags.pendingAdd.isEmpty {
            removeStateOp(.tags)
            tagsSplitMode = false
        } else {
            scheduleTagsFlush(now: now)
        }
    }

    // MARK: - A new row

    /// Sends the tag mirror again to a new row, which holds no tags (a registration answer): every mirror tag without
    /// a pending change (a change made since is newer and wins) becomes a pending addition stamped with the current
    /// epoch, sent once no identity op is pending. Logs nothing of its own: the tags request logs its answer (as
    /// on Android).
    func requeueTagMirror(now: Double) {
        guard !state.tags.mirror.isEmpty else { return }
        for (key, value) in state.tags.mirror where state.tags.pendingAdd[key] == nil && state.tags.pendingRemove[key] == nil {
            state.tags.pendingAdd[key] = PendingTagAdd(v: value, epoch: epoch)
        }
        state.tags.mirror = [:]
        stateDirty = true
        ensureStateOp(.tags, nextAt: now + Self.debounce)
    }

    /// Trims and lowercases a key; nil (and WARN) when it still does not match `^[a-z0-9_]{1,64}$`.
    func normalizedTagKey(_ raw: String) -> String? {
        guard let key = TagRules.normalizedKey(raw) else {
            let shown = LogSanitizer.clean(String(raw.prefix(64)))
            logger.log(.tagsInvalidKey,
                       "Tag key \"\(shown)\" is invalid after lowercasing (a-z, 0-9, _; max 64); dropped.")
            return nil
        }
        if key != raw {
            logger.log(.tagsNormalized, "Tag key \(LogSanitizer.clean(raw)) sent as \(key).")
        }
        return key
    }

    /// Flushes 10 s after the first pending change in the foreground, at once in the background. A tags op that waits
    /// after a failure keeps its wait for a change made meanwhile.
    func scheduleTagsFlush(now: Double) {
        guard state.tags.hasPendingChanges else {
            dropIdleTagsOp(now: now)
            return
        }
        ensureStateOp(.tags, nextAt: nextTagsRequest(now: now, debounced: true))
    }

    /// Removes a tags op left with nothing to send, unless its request is on the wire (its answer still updates the
    /// mirror) or it waits after a failure (`tagsOpWaits`), as on Android.
    func dropIdleTagsOp(now: Double) {
        guard !isTagsRequestInFlight, let op = stateOp(.tags), !tagsOpWaits(op, now: now) else { return }
        removeStateOp(.tags)
        tagsSplitMode = false
    }

    /// A tags op waiting after a failure (a backoff, a 429 `Retry-After`, a day after a client error) is kept even when
    /// nothing is left to send, until the wait ends: a tag change made meanwhile waits for it too, so the wait is never
    /// shortened (triggers never shorten a 429 wait).
    private func tagsOpWaits(_ op: StateOp, now: Double) -> Bool {
        op.retry.lastFailure != nil && !isReady(op.retry, id: op.id, now: now)
    }

    /// When the next tags request may go: in the foreground no sooner than 10 s after the previous
    /// one, and, for a first change (`debounced`), 10 s after it; at once in the background, where the app may be
    /// suspended soon.
    func nextTagsRequest(now: Double, debounced: Bool) -> Double {
        guard appState != .background else { return now }
        let earliest = debounced ? now + Self.tagsDebounce : now
        guard let last = lastTagsRequestAt, last <= now else { return earliest }
        return max(earliest, last + Self.tagsDebounce)
    }

    // MARK: - Sending

    func sendTags(now: Double) {
        guard let credentials, let client = apiClient() else { return }
        var add: [String: PendingTagAdd] = [:]
        var remove: [String: Int] = [:]
        if tagsSplitMode {
            if let key = state.tags.pendingRemove.keys.sorted().first, let epochValue = state.tags.pendingRemove[key] {
                remove[key] = epochValue
            } else if let key = state.tags.pendingAdd.keys.sorted().first, let value = state.tags.pendingAdd[key] {
                add[key] = value
            }
        } else {
            add = state.tags.pendingAdd
            remove = state.tags.pendingRemove
        }
        guard !add.isEmpty || !remove.isEmpty else {
            removeStateOp(.tags)
            tagsSplitMode = false
            return
        }
        let body = TagsBody(add: add.mapValues(\.v), remove: remove.keys.sorted())
        updateStateOp(.tags) { $0.retry.lastAttemptAt = now }
        lastTagsRequestAt = now
        let requestId = beginRequest(.tags(add: add, remove: remove, mirrorResets: tagMirrorResets), now: now)
        let handle = client.tags(deviceId: credentials.deviceId, secret: credentials.secret, body: body,
                                 completion: completion(for: requestId) { engine, result, request in
                                     engine.tagsAnswered(result, request: request)
                                 })
        attach(handle, to: requestId, now: now)
    }

    func tagsAnswered(_ result: APIResult<TagsResponse>, request: InFlight) {
        let now = env.clock.now()
        guard case let .tags(sentAdd, sentRemove, mirrorResets) = request.kind else { return }
        switch result {
        case let .success(success):
            if mirrorResets == tagMirrorResets {
                state.tags.mirror = success.value.tags
            }
            // A tags answer settles what the server holds, also when a logout or a consent withdrawal reset the mirror
            // while this request was on the wire (as on Android). That answer never repopulates the mirror: a logout
            // queued since clears these tags, and until then they exist; no tags means none is known again.
            identity.serverTags = success.value.tags.isEmpty ? .none : .some
            identityDirty = true
            settleSentTags(add: sentAdd, remove: sentRemove)
            logger.log(.tagsFlushed, "Tags updated (+\(sentAdd.count) −\(sentRemove.count)).")
            finishTagsRequest(now: now)
            stopReachabilityIfIdle()
        case let .failure(error):
            if error.mayHaveApplied, identity.serverTags == .some || !sentAdd.isEmpty {
                // No usable answer (a transport failure, a timeout, an unreadable 2xx): the request may have changed the
                // server's tags. Tags it may have added mean "none" is no longer known (a request that only removes
                // cannot add any), and any change means the mirror no longer stands for what the server holds: either
                // way it is unknown until a tags answer says. A logout then clears them (unknown counts as
                // present), and so does a consent withdrawal's logout. An answered error applied nothing.
                identity.serverTags = .unknown
                identityDirty = true
            }
            if handleDeviceRouteFailure(error, now: now) { return }
            // Only the push service's own 400 (an error code) says a tag was refused; a 400 without one (a proxy's or
            // an edge's JSON error) is retried like any other unreadable answer, and no tag is dropped for it.
            if error.isClientError, error.status == 400 {
                tagsRejected(error, sentAdd: sentAdd, sentRemove: sentRemove, now: now)
                return
            }
            if error.isClientError {
                updateStateOp(.tags) { op in
                    op.retry.recordAttempt()
                    op.retry.lastFailure = .client
                    op.retry.dormantUntil = now + Self.dayInSeconds
                }
                logger.log(.netClientError,
                           "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); retrying in 24 h.",
                           metadata: failureMetadata(error))
                return
            }
            applyTransientFailure(error, to: request.kind, now: now)
        }
    }

    /// Removes the sent changes that were not changed again while the request was in flight.
    private func settleSentTags(add: [String: PendingTagAdd], remove: [String: Int]) {
        for (key, value) in add where state.tags.pendingAdd[key] == value {
            state.tags.pendingAdd.removeValue(forKey: key)
        }
        for (key, value) in remove where state.tags.pendingRemove[key] == value {
            state.tags.pendingRemove.removeValue(forKey: key)
        }
        stateDirty = true
    }

    /// Changes made while the request was on the wire go in the next one: at once while a rejected key is isolated,
    /// else by the foreground rate (one request per 10 s) or at once in the background.
    private func finishTagsRequest(now: Double) {
        removeStateOp(.tags)
        if state.tags.hasPendingChanges {
            ensureStateOp(.tags, nextAt: tagsSplitMode ? now : nextTagsRequest(now: now, debounced: false))
        } else {
            tagsSplitMode = false
        }
    }

    /// A 400 on tags never drops valid pending tags: invalid keys and values are dropped after local
    /// re-validation; if everything looks valid, the op is split once into single-key requests to isolate the bad key.
    private func tagsRejected(_ error: APIError, sentAdd: [String: PendingTagAdd], sentRemove: [String: Int], now: Double) {
        if tagsSplitMode {
            for key in sentAdd.keys { dropRejectedTag(key, error: error) }
            for key in sentRemove.keys { dropRejectedTag(key, error: error) }
            finishTagsRequest(now: now)
            return
        }
        var dropped = false
        for (key, value) in state.tags.pendingAdd {
            if !Validation.isLowerIdentifier(key) || value.v.utf16.count > FieldLimit.tagValue {
                dropRejectedTag(key, error: error)
                dropped = true
            }
        }
        for key in state.tags.pendingRemove.keys where !Validation.isLowerIdentifier(key) {
            dropRejectedTag(key, error: error)
            dropped = true
        }
        var effective = state.tags.effective
        while effective.count > TagRules.maximumTags,
              let key = state.tags.pendingAdd.filter({ state.tags.mirror[$0.key] == nil })
                  .max(by: { ($0.value.epoch, $0.key) < ($1.value.epoch, $1.key) })?.key {
            dropRejectedTag(key, error: error)
            dropped = true
            effective = state.tags.effective
        }
        if !dropped {
            tagsSplitMode = true
        }
        finishTagsRequest(now: now)
        updateStateOp(.tags) { $0.retry.nextAt = now }
    }

    private func dropRejectedTag(_ key: String, error: APIError) {
        state.tags.pendingAdd.removeValue(forKey: key)
        state.tags.pendingRemove.removeValue(forKey: key)
        stateDirty = true
        logger.log(.tagsRejectedKey,
                   "The server rejected tag \"\(LogSanitizer.clean(key))\"; it was dropped and the other tags were kept.",
                   metadata: failureMetadata(error))
    }
}
