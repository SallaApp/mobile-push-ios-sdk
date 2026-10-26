import Foundation
import SallaPushCore

/// The identity values a link sends, checked on the caller thread and when the files are read.
enum IdentityRules {
    /// The longest external id push-service links: 128 characters, counted in UTF-16 units as push-service counts them.
    static let maximumExternalIdLength = 128
    /// The longest identity token SallaPush sends: the cap of an earlier (pre-release) version's customer token.
    static let maximumIdentityTokenLength = 4_096

    /// An external id as SallaPush sends it, trimmed: 1 to 128 UTF-16 units.
    static func isExternalId(_ value: String) -> Bool {
        (1...maximumExternalIdLength).contains(value.utf16.count)
    }

    /// An identity token as SallaPush sends it, trimmed: 1 to 4,096 characters.
    static func isIdentityToken(_ value: String) -> Bool {
        (1...maximumIdentityTokenLength).contains(value.unicodeScalars.count)
    }
}

/// The identity token of a `login` call and the customer it is for (memory only).
struct IdentityToken: Sendable {
    let externalId: String
    let token: SecretString
}

extension Engine {
    // MARK: - login(externalId:identityToken:)

    /// The arguments were validated on the caller thread. The token is kept in memory for this customer: a later login
    /// of the same customer replaces it, so a link waiting for its retry, or a link after a re-registration, goes with
    /// the freshest one. A login of another customer is an account switch: with `clearTagsOnLogout`, the previous
    /// customer's tags leave the device before the new link, and their unsent changes are dropped. So is a login while
    /// a customer whose id SallaPush doesn't hold is signed in (an earlier (pre-release) version saved none, a consent
    /// withdrawal forgets it): that customer may be another one.
    func handleLogin(externalId: String, token: SecretString, now: Double) {
        epoch = epoch.saturatingIncrement
        identityToken = IdentityToken(externalId: externalId, token: token)
        // Only the customer and token push-service refused wait: a new token, or another customer, goes as any login.
        if refusedLogin?.externalId != externalId || refusedLogin?.token != token { refusedLogin = nil }
        let previous = identity.desired == .customer ? identity.desiredExternalId : nil
        let switches = identity.desired == .customer && identity.desiredExternalId != externalId
        // With no identity known (a first launch, a reinstall that kept the Keychain), the row may hold an
        // earlier customer's tags.
        let previousUnknown = identity.desired == .unknown
        if previous == externalId {
            if loginOp(for: externalId) != nil {
                // The same link is queued or on the wire: it keeps its place and its retry state (a 429 or a 24 h
                // client-error wait is never shortened), and goes with this token.
                logger.log(.loginQueued, "Login already queued; this call adds no request.")
                return
            }
            if identity.serverLink == .linked, identity.linkedExternalId == externalId, !hasPendingUnlinkingOp {
                logger.log(.loginSkippedSame, "Already linked to this customer; nothing to send.")
                return
            }
            if skipsRefusedLogin(externalId: externalId, token: token, now: now) { return }
        }
        // Every call that gets here queues a login, so it is a retry trigger; a call that adds no request leaves every
        // wait as it is.
        applyTriggerReset(now: now)
        identity.desired = .customer
        identity.desiredExternalId = externalId
        identityDirty = true
        var clearTags = false
        var tagKeys: [String] = []
        if switches {
            if config.clearTagsOnLogout {
                (clearTags, tagKeys) = tagClearing(keeping: [:])
                dropTagChanges(keeping: [:], now: now)
            }
            let switched = previous == nil
                ? "The previous customer's id is unknown (an upgrade from an earlier SallaPush version, or a consent "
                    + "withdrawal), so this login counts as an account switch"
                : "Account switched"
            logger.log(.loginSwitched, !config.clearTagsOnLogout
                ? "\(switched); this device keeps its tags (clearTagsOnLogout is off)."
                : clearTags
                    ? "\(switched); the previous customer's tags are cleared before the new customer is linked."
                    : "\(switched); this device holds none of the previous customer's tags.")
        } else if previousUnknown, config.clearTagsOnLogout {
            // As the launch logout does: the tags this launch set are this customer's, the others go before the link.
            let kept = keptLaunchTags
            (clearTags, tagKeys) = tagClearing(keeping: kept)
            dropTagChanges(keeping: kept, now: now)
            // Before the first registration there is no row yet: its answer settles the clearing without a request.
            if clearTags, credentials != nil {
                logger.log(.loginSwitched, "The previous customer is unknown (a first launch or a reinstall); tags the "
                               + "device holds from before this launch are cleared before the customer is linked.")
            }
        }
        enqueueLogin(externalId: externalId, clearTags: clearTags, tagKeys: tagKeys, now: now)
        if credentials == nil {
            logger.log(.loginQueued, "Login queued (waiting for registration).")
        }
    }

    /// The identity token in memory for `externalId`.
    func identityToken(for externalId: String) -> SecretString? {
        guard let identityToken, identityToken.externalId == externalId else { return nil }
        return identityToken.token
    }

    // MARK: - logout()

    /// While the identity is unknown (first launch, reinstall), the tags the app set earlier in this launch
    /// are the signed-out user's, so the launch logout keeps them; whatever the previous install left goes.
    func handleLogout(now: Double) {
        epoch = epoch.saturatingIncrement
        identityToken = nil
        refusedLogin = nil
        if skipsGuestLogout() { return }
        // A sign-out is a retry trigger; a repeated logout() is one only when it queues a request (below).
        let signsOut = identity.desired != .guest
        if signsOut { applyTriggerReset(now: now) }
        let kept = identity.desired == .unknown ? keptLaunchTags : [:]
        let unlinks = logoutUnlinks
        let (clearTags, tagKeys) = tagClearing(keeping: kept)
        identity.desired = .guest
        identity.desiredExternalId = nil
        identityDirty = true
        if config.clearTagsOnLogout {
            dropTagChanges(keeping: kept, now: now)
        }
        guard unlinks || clearTags else {
            // Only logins that were never sent remain here (a sent one makes the logout unlink).
            let live = inFlightIdentityOpId
            for op in identity.ops where op.kind == .login && op.id != live {
                removeIdentityOp(id: op.id)
            }
            logger.log(.logoutSkipped, "Not linked; logout needs no request.")
            return
        }
        let appended = enqueueLogout(clearTags: clearTags, tagKeys: tagKeys, now: now)
        if !signsOut, appended { applyTriggerReset(now: now) }
        logLogoutQueued(appended: appended, now: now)
    }

    /// Already signed out, known unlinked, and no login on the way or possibly applied: a `logout()` needs
    /// nothing and keeps the tags.
    var guestLogoutIsFree: Bool {
        identity.desired == .guest && identity.serverLink == .none && !unknownOutcomeLogin
            && !identity.ops.contains(where: { $0.kind == .login })
    }

    /// A guest's launch logout() is free: nothing to send, and the guest keeps its tags. Returns whether the logout
    /// was settled so.
    private func skipsGuestLogout() -> Bool {
        guard guestLogoutIsFree else { return false }
        logger.log(.logoutSkipped, "Already signed out and not linked; logout needs no request.")
        return true
    }

    /// Whether a logout now unlinks the device: it may be linked (a link, or a login that may have made one).
    var logoutUnlinks: Bool {
        identity.serverLink != .none || loginMayHaveLinked
    }

    /// Whether a logout now removes the device's tags first (`clearTagsOnLogout`).
    var logoutClearsTags: Bool {
        tagClearing(keeping: identity.desired == .unknown ? keptLaunchTags : [:]).clears
    }

    /// What an identity change with `clearTagsOnLogout` removes from the server: every tag key SallaPush holds, except
    /// `kept`. When the mirror is what the server holds (`mirrorIsServerTruth`) only its keys can be there, and nothing
    /// is cleared when they are all kept; otherwise the clearing's answer also names the keys SallaPush did not know of.
    func tagClearing(keeping kept: [String: String]) -> (clears: Bool, keys: [String]) {
        guard config.clearTagsOnLogout, tagsMayBeOnServer else { return (false, []) }
        if mirrorIsServerTruth {
            let keys = state.tags.mirror.keys.filter { kept[$0] == nil }.sorted()
            return (!keys.isEmpty, keys)
        }
        return (true, state.tags.heldKeys.filter { kept[$0] == nil })
    }

    /// Whether the server may hold tags of this device. A tags request still in flight may leave tags on the server, so
    /// the server's tags count as present.
    var tagsMayBeOnServer: Bool {
        identity.serverTags != .none || isTagsRequestInFlight
    }

    /// Says why a logout is not on the wire yet: already queued, before registration, routes closed, or behind the
    /// request in flight.
    private func logLogoutQueued(appended: Bool, now: Double) {
        if !appended {
            logger.log(.logoutQueued, "Logout already queued; it is retried until the server answers it.")
        } else if credentials == nil {
            logger.log(.logoutQueued, "Logout queued until this device is registered; the registration answer settles "
                           + "whether it is still needed.")
        } else if deviceRoutesDormant(now: now) {
            logger.log(.logoutQueued, "Logout queued while SallaPush is unavailable; it is sent when SallaPush is back.")
        } else if inFlight != nil {
            logger.log(.logoutQueued, "Logout queued behind the request in flight.")
        }
    }

    // MARK: - Sending

    /// Sends the next request of `op`: its tag clearing, then its link or unlink.
    func sendIdentity(_ op: IdentityOp, now: Double) {
        guard let credentials, let client = apiClient() else { return }
        var op = op
        if op.clearsTagsNext, identity.serverTags == .none {
            // The server is known to hold no tags: there is nothing to clear.
            finishTagClearing(opId: op.id, now: now)
            guard let updated = identityOp(id: op.id) else { return }
            op = updated
        }
        if op.clearsTagsNext {
            sendTagClearing(op, credentials: credentials, client: client, now: now)
            return
        }
        if op.kind == .logout, identity.serverLink == .none, !loginMayHaveLinked {
            // The device is known to be linked to no customer: the logout had only the tags to clear. The pump runs
            // after the turn's commit, so the files and the getters are brought up to date now.
            removeIdentityOp(id: op.id)
            logger.log(.logoutSkipped, "Not linked; the logout needs no unlink.")
            stopReachabilityIfIdle()
            commit()
            return
        }
        var linkToken: SecretString?
        if op.kind == .login {
            guard let externalId = op.externalId, let token = identityToken(for: externalId) else {
                loginWithoutToken(op)
                return
            }
            linkToken = token
        }
        // Whether an earlier request of this op may have changed the server: an answer that applies nothing restores it.
        let sentBefore = op.sent
        updateIdentityOp(id: op.id) { current in
            current.sent = true
            current.retry.lastAttemptAt = now
        }
        // identity.json reaches disk before any link or unlink. If that write fails (logged by persist()), the request
        // still goes: reaching the server is what makes a logout effective.
        persist()
        let opId = op.id
        let requestId = beginRequest(.identity(opId: opId), now: now)
        let handle: HTTPTaskHandle?
        if let linkToken, let externalId = op.externalId {
            handle = client.link(deviceId: credentials.deviceId, secret: credentials.secret,
                                 body: LinkBody(externalId: externalId, identityToken: linkToken),
                                 completion: completion(for: requestId) { engine, result, _ in
                                     engine.linkAnswered(result, opId: opId, sentBefore: sentBefore, token: linkToken)
                                 })
        } else {
            handle = client.unlink(deviceId: credentials.deviceId, secret: credentials.secret,
                                   completion: completion(for: requestId) { engine, result, _ in
                                       engine.unlinkAnswered(result, opId: opId, sentBefore: sentBefore)
                                   })
        }
        attach(handle, to: requestId, now: now)
    }

    /// After a failed link or unlink (Android's rule): the op stays `sent` when this request may have reached the
    /// server without a usable answer, or an earlier one may have; an answer that applied nothing (the identity routes are
    /// transactional: a 5xx, a 429, a redirect, a 4xx) restores what it was before this request. Returns the op's new
    /// value.
    @discardableResult
    func settleSent(after error: APIError, opId: Int, sentBefore: Bool) -> Bool {
        let mayHaveApplied = sentBefore || error.mayHaveApplied
        updateIdentityOp(id: opId) { $0.sent = mayHaveApplied }
        return mayHaveApplied
    }

    /// A device-level answer (a re-registration, closed routes) to a request of an identity op: none of its requests can
    /// apply any more (a re-registration makes a new row), so the op is no longer `sent` (as on Android).
    private func clearSent(opId: Int) {
        updateIdentityOp(id: opId) { $0.sent = false }
    }

    /// A link whose customer has no identity token in memory (one queued before a relaunch): it is dropped, and the
    /// app's next `login` call links the device again. A link whose token is in memory is left as it is.
    func loginWithoutToken(_ op: IdentityOp) {
        guard op.kind == .login, identityToken(for: op.externalId ?? "") == nil else { return }
        dropUnsendableLogin(op)
        logTokenNeeded()
    }

    /// Says once what the app can do: call `login` with the customer's identity token.
    func logTokenNeeded() {
        logger.logOnce(.identityTokenNeeded, key: "token_needed.\(config.folder)",
                       "SallaPush keeps the identity token in memory only and has none for the signed-in customer, so this "
                           + "device is not linked to them; call login(externalId:identityToken:) at every launch while the "
                           + "customer is signed in.")
    }

    // MARK: - Tag clearing

    /// Removes the device's tags before the op's link or unlink: every key SallaPush held when the op was queued.
    /// The answer names the tags the server still holds; those SallaPush did not know of go with one more request.
    private func sendTagClearing(_ op: IdentityOp, credentials: Credentials, client: APIClient, now: Double) {
        updateIdentityOp(id: op.id) { $0.retry.lastAttemptAt = now }
        let mirrorResets = tagMirrorResets
        let opId = op.id
        let requestId = beginRequest(.identity(opId: opId), now: now)
        let handle = client.tags(deviceId: credentials.deviceId, secret: credentials.secret,
                                 body: TagsBody(add: [:], remove: op.tagKeys),
                                 completion: completion(for: requestId) { engine, result, _ in
                                     engine.tagClearingAnswered(result, opId: opId, mirrorResets: mirrorResets)
                                 })
        attach(handle, to: requestId, now: now)
    }

    /// The answer of an op's tag clearing. A tag the getters show is the next identity's (one the app set since the op
    /// was queued, or one a launch logout keeps), so it is never removed.
    func tagClearingAnswered(_ result: APIResult<TagsResponse>, opId: Int, mirrorResets: Int) {
        let now = env.clock.now()
        guard let op = identityOp(id: opId) else { return }
        switch result {
        case let .success(success):
            let held = success.value.tags
            let shown = state.tags.effective
            let unknown = held.keys.filter { shown[$0] == nil }
            if !unknown.isEmpty, !op.tagsRechecked {
                updateIdentityOp(id: op.id) { current in
                    current.tagKeys = unknown.sorted()
                    current.tagsRechecked = true
                    current.retry = RetryState()
                    current.retry.nextAt = now
                }
                forgetRetry(id: op.id)
                let tags = unknown.count == 1 ? "1 tag" : "\(unknown.count) tags"
                logger.log(.tagsFlushed, "The server still holds \(tags) SallaPush did not know of; they are cleared too.")
                return
            }
            // Tags the server still names after one more request (another writer's) are not the next identity's: they
            // stay out of the copy, and the next tags request removes them.
            if mirrorResets == tagMirrorResets {
                state.tags.mirror = held.filter { shown[$0.key] != nil }
                stateDirty = true
            }
            identity.serverTags = !unknown.isEmpty ? .unknown : held.isEmpty ? .none : .some
            identityDirty = true
            finishTagClearing(opId: op.id, now: now)
            if !unknown.isEmpty {
                removeUnclearedTags(unknown, now: now)
                let tags = unknown.count == 1 ? "1 tag" : "\(unknown.count) tags"
                logger.log(.tagsFlushed, "The server still holds \(tags) SallaPush could not clear; the next tags request "
                               + "removes them.")
            } else {
                logger.log(.tagsFlushed, op.kind == .login
                    ? "Tags cleared before the new customer is linked."
                    : "Tags cleared before the unlink.")
            }
            if op.kind == .login, identity.ops.contains(where: { $0.id != op.id }) {
                // A later identity call superseded this login while the tags were cleared: its link is never sent.
                removeIdentityOp(id: op.id)
            }
            stopReachabilityIfIdle()
        case let .failure(error):
            if handleDeviceRouteFailure(error, now: now) { return }
            if error.isClientError {
                // A refused tag clearing never holds the link or the unlink back. The next tags request removes its tags,
                // and the server's tags are unknown until then.
                identity.serverTags = .unknown
                identityDirty = true
                finishTagClearing(opId: op.id, now: now)
                let shown = state.tags.effective
                removeUnclearedTags(op.tagKeys.filter { shown[$0] == nil }, now: now)
                logger.log(.netClientError,
                           "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); the device's tags "
                               + "were not cleared.",
                           metadata: failureMetadata(error))
                return
            }
            applyTransientFailure(error, to: .identity(opId: op.id), now: now)
        }
    }

    /// Tags a clearing left on the server (refused, or written meanwhile) become pending removals: the next tags request,
    /// after the link or the unlink, removes them.
    private func removeUnclearedTags(_ keys: [String], now: Double) {
        guard !keys.isEmpty else { return }
        for key in keys {
            state.tags.pendingRemove[key] = epoch
        }
        stateDirty = true
        scheduleTagsFlush(now: now)
    }

    /// The op's tag clearing is done: its link or unlink goes next, with a retry state of its own.
    private func finishTagClearing(opId: Int, now: Double) {
        updateIdentityOp(id: opId) { op in
            op.tagsCleared = true
            op.tagKeys = []
            op.retry = RetryState()
            op.retry.nextAt = now
        }
        forgetRetry(id: opId)
    }

    // MARK: - Link answers

    /// A `200` links the device to the op's customer. `403 invalid_identity_token` and `400` are final: the login is
    /// reported and not sent again, unless the app passed a newer token for that customer while this one was on the
    /// wire, and a refused account switch unlinks the previous customer. The app's `login` with the same customer and
    /// token sends nothing for 5 minutes, and a refusal of them is reported once (`RefusedLogin`).
    /// A 4xx without a code (a proxy's or an edge's JSON error, such as a Cloudflare block answered as RFC 9457 JSON) is
    /// no answer of the push service: it is retried with backoff. Another code is a client error: the op waits 24 h,
    /// then is sent again.
    func linkAnswered(_ result: APIResult<EmptyResponse>, opId: Int, sentBefore: Bool, token: SecretString) {
        let now = env.clock.now()
        guard let op = identityOp(id: opId) else { return }
        switch result {
        case .success:
            removeIdentityOp(id: op.id)
            identity.serverLink = .linked
            identity.linkedExternalId = op.externalId
            identityDirty = true
            refusedLogin = nil
            logger.log(.loginOk, "Customer linked.")
            stopReachabilityIfIdle()
        case let .failure(error):
            linkFailed(error, op: op, sentBefore: sentBefore, token: token, now: now)
        }
    }

    private func linkFailed(_ error: APIError, op: IdentityOp, sentBefore: Bool, token: SecretString, now: Double) {
        if handleDeviceRouteFailure(error, now: now) {
            // Closed routes (404 not_found) keep the row, which an earlier request of this link may have linked.
            if sentBefore, error.status == 404, error.code == "not_found" { rememberUnknownOutcomeLogin() }
            clearSent(opId: op.id)
            return
        }
        let mayHaveApplied = settleSent(after: error, opId: op.id, sentBefore: sentBefore)
        // A refusal of a login the app already replaced is logged, never reported as the app's current login failure.
        let superseded = identity.ops.contains { $0.id != op.id }
        switch (error.kind, error.status, error.code) {
        case (.http, 403, "invalid_identity_token"):
            if let latest = identityToken(for: op.externalId ?? ""), latest != token {
                updateIdentityOp(id: op.id) { $0.retry.nextAt = now }
                logger.log(.loginQueued, "The identity token was rejected, and a newer one came since; the link is sent "
                               + "again with it.")
                return
            }
            refuseLogin(op, mayHaveApplied: mayHaveApplied)
            if identityToken(for: op.externalId ?? "") == token { identityToken = nil }
            logger.log(.loginRejected,
                       "The identity token was rejected (403 invalid_identity_token); this device is not linked to the "
                           + "customer. Call login(externalId:identityToken:) with a fresh token.",
                       metadata: failureMetadata(error))
            unlinkPreviousCustomer(after: op, superseded: superseded, now: now)
            if !superseded, rememberRefusal(of: op, token: token, now: now) {
                reportLoginFailure(.tokenRejected)
            }
        case (.http, 400, _?):
            refuseLogin(op, mayHaveApplied: mayHaveApplied)
            logger.log(.identityClientError,
                       "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); the login is not "
                           + "sent again.",
                       metadata: failureMetadata(error))
            unlinkPreviousCustomer(after: op, superseded: superseded, now: now)
            if !superseded, rememberRefusal(of: op, token: token, now: now) {
                reportLoginFailure(.invalidRequest)
            }
        default:
            if supersededLoginFailed(error, op: op, mayHaveApplied: mayHaveApplied) { return }
            if error.isClientError {
                identityClientError(error, opId: op.id, now: now)
                return
            }
            applyTransientFailure(error, to: .identity(opId: op.id), now: now)
        }
    }

    /// Removes a login push-service refused; what an earlier request of it may have done is kept.
    private func refuseLogin(_ op: IdentityOp, mayHaveApplied: Bool) {
        removeIdentityOp(id: op.id)
        if mayHaveApplied { rememberUnknownOutcomeLogin() }
    }

    /// A refused account switch leaves the device linked to the previous customer, whose notifications would keep
    /// reaching it: an unlink goes. The asserted customer stays as it is, for the getters too, and their next link (the
    /// app's `login`) goes after the unlink. Nothing goes when a later call of the app replaced the refused login (its
    /// link or its logout settles the link), during a consent withdrawal (its own unlink does), or when SallaPush can't
    /// name the customer the device is linked to (after a reinstall, the link is left as it is).
    private func unlinkPreviousCustomer(after op: IdentityOp, superseded: Bool, now: Double) {
        guard !superseded, consentMode == .normal, identity.serverLink == .linked,
              let linked = identity.linkedExternalId, linked != op.externalId
        else { return }
        enqueueLogout(clearTags: false, tagKeys: [], now: now)
        logger.log(.logoutQueued, "The new customer's link was refused; the device is unlinked from the previous "
                       + "customer, whose notifications would otherwise keep reaching it.")
    }

    /// A login that failed after the app superseded it while it was on the wire (a logout, or another customer's
    /// login, is queued behind it) is never retried, so neither a backoff nor a 24 h client-error wait holds the later
    /// call back. What it may have done on the server is kept: when a request of it may have applied (this one or
    /// an earlier one, whatever answered later), the logout behind it, or the next one, unlinks and is confirmed 60 s
    /// after the server answers it. Returns false when nothing superseded it.
    private func supersededLoginFailed(_ error: APIError, op: IdentityOp, mayHaveApplied: Bool) -> Bool {
        guard identity.ops.contains(where: { $0.id != op.id }) else { return false }
        logTransient(error, retried: false)
        removeIdentityOp(id: op.id)
        if mayHaveApplied { rememberUnknownOutcomeLogin() }
        return true
    }

    /// A client error on an identity route: never dropped; dormant 24 h, then retried.
    func identityClientError(_ error: APIError, opId: Int, now: Double) {
        updateIdentityOp(id: opId) { op in
            op.retry.recordAttempt()
            op.retry.lastFailure = .client
            op.retry.dormantUntil = now + Self.dayInSeconds
        }
        logger.log(.identityClientError,
                   "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); retrying in 24 h.",
                   metadata: failureMetadata(error))
    }

    // MARK: - Unlink answers

    /// A logout's unlink, or its confirmation, answered: the device is linked to no customer.
    func unlinkAnswered(_ result: APIResult<EmptyResponse>, opId: Int, sentBefore: Bool) {
        let now = env.clock.now()
        guard let op = identityOp(id: opId) else { return }
        switch result {
        case .success:
            let position = identity.ops.firstIndex { $0.id == op.id } ?? identity.ops.count
            removeIdentityOp(id: op.id)
            linkCleared()
            logger.log(.logoutOk, "Customer unlinked.")
            if op.kind == .logout, unknownOutcomeLogin {
                // A login whose outcome was unknown may still be processed late, so this unlink is confirmed once,
                // 60 s after the server answered it (as on Android).
                unknownOutcomeLogin = false
                insertLogoutConfirm(at: position, now: now)
            }
            stopReachabilityIfIdle()
        case let .failure(error):
            unlinkFailed(error, op: op, sentBefore: sentBefore, now: now)
        }
    }

    /// The server confirmed the device is linked to no customer.
    func linkCleared() {
        identity.serverLink = .none
        identity.linkedExternalId = nil
        identityDirty = true
    }

    /// Empties the tag mirror after an identity change dropped SallaPush's copy of the tags; an answer to a tags request
    /// sent before that never repopulates it.
    func resetTagMirror() {
        state.tags.mirror = [:]
        tagMirrorResets = tagMirrorResets.saturatingIncrement
        stateDirty = true
    }

    /// Whether a tags request is in flight.
    var isTagsRequestInFlight: Bool {
        if case .tags? = inFlight?.kind { return true }
        return false
    }

    private func unlinkFailed(_ error: APIError, op: IdentityOp, sentBefore: Bool, now: Double) {
        if handleDeviceRouteFailure(error, now: now) {
            clearSent(opId: op.id)
            return
        }
        settleSent(after: error, opId: op.id, sentBefore: sentBefore)
        if error.isClientError {
            identityClientError(error, opId: op.id, now: now)
            return
        }
        applyTransientFailure(error, to: .identity(opId: op.id), now: now)
    }
}
