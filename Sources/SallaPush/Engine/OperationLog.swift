import Foundation
import SallaPushCore

extension Engine {
    // MARK: - Ids

    func makeOpId() -> Int {
        defer { nextOpId = nextOpId.saturatingIncrement }
        return nextOpId
    }

    /// The identity op whose request is in flight (its tag clearing, its link or its unlink), if any.
    var inFlightIdentityOpId: Int? {
        if case let .identity(opId)? = inFlight?.kind { return opId }
        return nil
    }

    // MARK: - State ops (one per kind)

    func stateOp(_ kind: StateOpKind) -> StateOp? {
        state.ops.first { $0.kind == kind }
    }

    /// Creates the op of `kind` when missing; an existing op keeps its retry state.
    func ensureStateOp(_ kind: StateOpKind, nextAt: Double) {
        guard stateOp(kind) == nil else { return }
        state.ops.append(StateOp(id: makeOpId(), kind: kind, nextAt: nextAt))
        stateDirty = true
    }

    func removeStateOp(_ kind: StateOpKind) {
        guard let op = stateOp(kind) else { return }
        state.ops.removeAll { $0.kind == kind }
        forgetRetry(id: op.id)
        stateDirty = true
    }

    /// Mutates the op of `kind` through a copy, so `body` may freely touch other engine state.
    func updateStateOp(_ kind: StateOpKind, _ body: (inout StateOp) -> Void) {
        guard let index = state.ops.firstIndex(where: { $0.kind == kind }) else { return }
        var op = state.ops[index]
        body(&op)
        if let current = state.ops.firstIndex(where: { $0.id == op.id }) {
            state.ops[current] = op
        }
        stateDirty = true
    }

    // MARK: - Identity ops

    func identityOp(id: Int) -> IdentityOp? {
        identity.ops.first { $0.id == id }
    }

    /// Mutates the identity op `id` through a copy, so `body` may freely touch other engine state.
    func updateIdentityOp(id: Int, _ body: (inout IdentityOp) -> Void) {
        guard let index = identity.ops.firstIndex(where: { $0.id == id }) else { return }
        var op = identity.ops[index]
        body(&op)
        if let current = identity.ops.firstIndex(where: { $0.id == id }) {
            identity.ops[current] = op
        }
        identityDirty = true
    }

    func removeIdentityOp(id: Int) {
        identity.ops.removeAll { $0.id == id }
        forgetRetry(id: id)
        identityDirty = true
    }

    /// Removes a login op that will never be sent (a later identity call replaced it, or it has no token). When a request
    /// of its link may have reached the server without a usable answer (`sent`: failed in transit, timed out, or in flight
    /// when the process died, whatever a later retry was answered), the server may have linked the device, or may still:
    /// that is remembered, so the next logout unlinks and is confirmed (Android's rule).
    func dropUnsendableLogin(_ op: IdentityOp) {
        if op.sent { rememberUnknownOutcomeLogin() }
        removeIdentityOp(id: op.id)
    }

    /// A login that may have linked the device leaves the log: remembered for this process, and through `server_link`
    /// for later launches, so the next logout unlinks.
    func rememberUnknownOutcomeLogin() {
        unknownOutcomeLogin = true
        if identity.serverLink == .none {
            identity.serverLink = .unknown
            identityDirty = true
        }
    }

    /// Whether a login may have linked the device: a login op is in flight or may have been applied, or one that was
    /// removed may have been. The logout must then unlink.
    var loginMayHaveLinked: Bool {
        unknownOutcomeLogin || identity.ops.contains { $0.kind == .login && ($0.sent || $0.id == inFlightIdentityOpId) }
    }

    /// Whether a logout or a logout confirmation is pending: such an op settles the link.
    var hasPendingUnlinkingOp: Bool {
        identity.ops.contains { $0.kind != .login }
    }

    /// The login op of `externalId`, queued or in flight.
    func loginOp(for externalId: String) -> IdentityOp? {
        identity.ops.first { $0.kind == .login && $0.externalId == externalId }
    }

    /// The tag clearing a new op takes on: its own, and what an unsent op it replaces had still to clear.
    private struct TagClearing {
        var clearTags: Bool
        var keys: Set<String>

        mutating func absorb(_ op: IdentityOp) {
            guard op.clearsTagsNext else { return }
            clearTags = true
            keys.formUnion(op.tagKeys)
        }
    }

    /// Collapse rule: a new login removes every unsent login. A login that was sent but is superseded (the app
    /// asserted another customer) is removed too, never to be sent again, unless it is in flight; `dropUnsendableLogin`
    /// keeps what its request may have done, and the new login clears the tags a removed one had still to clear. The new
    /// login waits behind every unlinking op.
    @discardableResult
    func enqueueLogin(externalId: String, clearTags: Bool, tagKeys: [String], now: Double) -> IdentityOp {
        var clearing = TagClearing(clearTags: clearTags, keys: Set(tagKeys))
        let live = inFlightIdentityOpId
        for op in identity.ops where op.kind == .login && op.id != live {
            clearing.absorb(op)
            dropUnsendableLogin(op)
        }
        let op = IdentityOp(id: makeOpId(), kind: .login, externalId: externalId, clearTags: clearing.clearTags,
                            tagKeys: clearing.keys.sorted(), nextAt: now + Self.debounce)
        identity.ops.append(op)
        identityDirty = true
        return op
    }

    /// Collapse rules for a new logout: every login that is not in flight goes (a sent one is superseded by the
    /// sign-out and never sent again), and the logout clears the tags such a login had still to clear; the new op stays
    /// behind a login in flight. When the log then ends with an unlinking op that clears the tags at least as the new
    /// one would (queued, attempted or waiting, a pending `logout_confirm` included), that op covers the call: it keeps
    /// its place and its wait (a 429 or a 24 h client-error dormancy is never shortened), and a repeated `logout()` adds
    /// no request. Otherwise every unsent logout goes and the new op is appended. When a login may have reached the
    /// server without a usable answer, the unlink is confirmed 60 s after the server answers it
    /// (`unlinkAnswered`), as on Android.
    /// - Returns: false when such an op covered the call and nothing was added.
    @discardableResult
    func enqueueLogout(clearTags: Bool, tagKeys: [String], now: Double) -> Bool {
        var clearing = TagClearing(clearTags: clearTags, keys: Set(tagKeys))
        let live = inFlightIdentityOpId
        for op in identity.ops where op.id != live && op.kind == .login {
            clearing.absorb(op)
            dropUnsendableLogin(op)
        }
        identityDirty = true
        // Checked before unsent ops go, as on Android: an op whose answered error restored it to unsent keeps its wait.
        if let last = identity.ops.last, last.kind != .login, last.clearTags || !clearing.clearTags {
            if last.clearsTagsNext, !clearing.keys.isSubset(of: last.tagKeys) {
                updateIdentityOp(id: last.id) { $0.tagKeys = clearing.keys.union($0.tagKeys).sorted() }
            }
            return false
        }
        for op in identity.ops where op.id != live && op.kind == .logout && !op.sent {
            clearing.absorb(op)
            removeIdentityOp(id: op.id)
        }
        identity.ops.append(IdentityOp(id: makeOpId(), kind: .logout, externalId: nil, clearTags: clearing.clearTags,
                                       tagKeys: clearing.keys.sorted(), nextAt: now + Self.debounce))
        return true
    }

    /// How long after a logout's answer its confirmation goes.
    static let logoutConfirmDelay: Double = 60

    /// One idempotent unlink 60 s from now, confirming the logout the server just answered for a login whose outcome is
    /// unknown: a link that request makes late is removed. It goes where that logout was (`position`), and
    /// after any unlinking op still pending: a login the app asked for after that logout stays last, so the server's last
    /// word is still the app's last call and the confirmation never signs out the customer who logged in again (as on
    /// Android). A confirmation still pending does the job: it waits until then, so one request covers both. A late link
    /// brings no tags, so the confirmation clears none.
    func insertLogoutConfirm(at position: Int, now: Double) {
        let confirmAt = now + Self.logoutConfirmDelay
        if let pending = identity.ops.first(where: { $0.kind == .logoutConfirm && !$0.sent }) {
            updateIdentityOp(id: pending.id) { op in
                op.retry.nextAt = max(op.retry.nextAt, confirmAt)
            }
            return
        }
        let afterUnlinking = identity.ops.lastIndex { $0.kind != .login }.map { $0 + 1 } ?? 0
        let index = min(max(position, afterUnlinking), identity.ops.count)
        identity.ops.insert(IdentityOp(id: makeOpId(), kind: .logoutConfirm, externalId: nil, clearTags: false,
                                       tagKeys: [], nextAt: confirmAt), at: index)
        identityDirty = true
    }

    // MARK: - Retry bookkeeping

    func forgetRetry(id: Int) {
        processAttempts.removeValue(forKey: id)
        exhausted.remove(id)
    }

    /// Applies a transient failure (no answer, 5xx, non-JSON, redirect, invalid body, 429): backoff with jitter,
    /// or `Retry-After`. After six attempts in this process the op waits for the next trigger.
    func applyRetry(_ retry: inout RetryState, id: Int, error: APIError, now: Double) {
        retry.recordAttempt()
        var metadata = failureMetadata(error)
        metadata[LogMetadataKey.attempt] = String(retry.attempts)
        if error.isRateLimited {
            retry.lastFailure = .rateLimited
            let delay = error.retryAfter ?? RetryAfter.defaultRateLimitDelay
            retry.nextAt = now + delay
            metadata[LogMetadataKey.delay] = String(Int(delay))
            logger.log(.netRateLimited, "Rate limited (429); retry in \(Int(delay)) s.", metadata: metadata)
            return
        }
        retry.lastFailure = error.outcomeUnknown ? .network : .server
        let delay = Duration.clamped(error.retryAfter ?? Backoff.delay(attempt: retry.attempts, random: env.random()))
        retry.nextAt = now + delay
        let count = (processAttempts[id] ?? 0) + 1
        processAttempts[id] = count
        let operation = "\(error.route.method) \(error.route.template)"
        if count >= Backoff.attemptsPerProcess {
            exhausted.insert(id)
            let next = id == Self.withdrawalRetryId
                ? "the consent withdrawal stops retrying it"
                : "waiting for the next launch, foreground or network change"
            logger.log(.netRetryExhausted, "\(operation) failed \(count) times; \(next).", metadata: metadata)
        } else {
            metadata[LogMetadataKey.delay] = String(Int(delay.rounded()))
            logger.log(.netRetry, "\(operation) failed (\(error.summary)); retry \(retry.attempts) in \(Int(delay.rounded())) s.",
                       metadata: metadata)
        }
        if retry.lastFailure == .network {
            startReachability()
        }
    }

    /// Logs what a transient failure says about the integration, once per launch where noisy. `retried` is false for
    /// a request that a later call superseded: it is not sent again.
    func logTransient(_ error: APIError, retried: Bool = true) {
        let outcome = retried ? "will retry." : "a later call superseded it."
        switch error.kind {
        case .redirect:
            logger.logOnce(.netRedirectRefused, key: "redirect.\(config.folder)",
                           "The server answered with a redirect (\(error.status.map(String.init) ?? "3xx")); "
                               + "SallaPush never follows redirects.",
                           metadata: failureMetadata(error))
        case .invalidResponse:
            logger.log(.netInvalidResponse,
                       "\(error.route.method) \(error.route.template) returned an unexpected body"
                           + "\(error.detail.map { " (\($0))" } ?? ""); \(outcome)",
                       metadata: failureMetadata(error))
        case .nonJSON where error.detail != nil:
            // An error answer too large or too deeply nested to read: never parsed, retried like any other.
            logger.log(.netInvalidResponse,
                       "\(error.route.method) \(error.route.template) returned an answer SallaPush does not read "
                           + "(\(error.detail ?? "")); \(outcome)",
                       metadata: failureMetadata(error))
        default:
            break
        }
    }

    /// Applies a transient failure to whatever the request was for.
    func applyTransientFailure(_ error: APIError, to kind: InFlight.Kind, now: Double) {
        logTransient(error)
        switch kind {
        case .register:
            updateStateOp(.register) { applyRetry(&$0.retry, id: $0.id, error: error, now: now) }
        case .update:
            updateStateOp(.update) { applyRetry(&$0.retry, id: $0.id, error: error, now: now) }
        case .tags:
            updateStateOp(.tags) { applyRetry(&$0.retry, id: $0.id, error: error, now: now) }
        case let .identity(opId):
            updateIdentityOp(id: opId) { applyRetry(&$0.retry, id: $0.id, error: error, now: now) }
        case .events:
            var retry = eventsRetry
            applyRetry(&retry, id: eventsRetryId, error: error, now: now)
            eventsRetry = retry
        case .withdrawal:
            var retry = withdrawalRetry
            applyRetry(&retry, id: Self.withdrawalRetryId, error: error, now: now)
            withdrawalRetry = retry
        }
    }

    /// A trigger (an identity call that changes the desired identity or queues a request, foreground, connectivity
    /// regained) makes every op whose last failure was a network error or a server error ready again, keeping its
    /// attempt count. 429 and dormant waits stay.
    func applyTriggerReset(now: Double) {
        func reset(_ retry: inout RetryState, id: Int) {
            guard retry.lastFailure == .network || retry.lastFailure == .server else { return }
            retry.nextAt = max(now, retry.lastAttemptAt + 2)
            processAttempts[id] = 0
            exhausted.remove(id)
        }
        var identityOps = identity.ops
        for index in identityOps.indices {
            reset(&identityOps[index].retry, id: identityOps[index].id)
        }
        if identityOps != identity.ops {
            identity.ops = identityOps
            identityDirty = true
        }
        var stateOps = state.ops
        for index in stateOps.indices {
            reset(&stateOps[index].retry, id: stateOps[index].id)
        }
        if stateOps != state.ops {
            state.ops = stateOps
            stateDirty = true
        }
        var retry = eventsRetry
        reset(&retry, id: eventsRetryId)
        eventsRetry = retry
        retry = withdrawalRetry
        reset(&retry, id: Self.withdrawalRetryId)
        withdrawalRetry = retry
    }

    // MARK: - Connectivity

    func startReachability() {
        guard reachability == nil, phase == .running else { return }
        let monitor = env.makeReachability()
        reachability = monitor
        let expectedGeneration = generation
        monitor.start(on: queue) { [weak self] in
            guard let self, self.phase != .stopped, self.generation == expectedGeneration else { return }
            self.perform { engine in
                engine.applyTriggerReset(now: engine.env.clock.now())
            }
        }
    }

    /// Stops the monitor once no op is waiting on a network failure.
    func stopReachabilityIfIdle() {
        guard reachability != nil else { return }
        let waiting = identity.ops.contains { $0.retry.lastFailure == .network }
            || state.ops.contains { $0.retry.lastFailure == .network }
            || (!events.pending.isEmpty && eventsRetry.lastFailure == .network)
            || (!withdrawalSteps.isEmpty && withdrawalRetry.lastFailure == .network)
        if !waiting {
            reachability?.cancel()
            reachability = nil
        }
    }

    // MARK: - Shared device-route answers

    /// Handles the answers every device route shares. Returns true when the failure was fully handled; the op that
    /// failed is then left untouched and continues once the device is usable again.
    func handleDeviceRouteFailure(_ error: APIError, now: Double) -> Bool {
        guard error.kind == .http, let status = error.status else { return false }
        switch (status, error.code) {
        case (401, "invalid_device_secret"):
            reregister(reason: "invalid_device_secret", after: error, now: now)
            return true
        case (404, "unknown_device"):
            // The new row has no link and no tags: the registration answer links the customer again and sends the tags.
            reregister(reason: "unknown_device", after: error, now: now)
            return true
        case (404, "not_found"):
            state.registration.status = .dormant
            state.registration.dormantReason = .notFound
            state.registration.dormantUntil = now + Self.dayInSeconds
            stateDirty = true
            logger.log(.netRoutesClosed,
                       "SallaPush is unavailable (404 not_found); pending work is kept and retried in 24 h.",
                       metadata: failureMetadata(error))
            return true
        default:
            return false
        }
    }

    /// The re-registration valve (Android's rule exactly) for every device-level re-registration:
    /// `401 invalid_device_secret` and `404 unknown_device`. The credentials are dropped and the device registers
    /// again, which push-service answers with a new device. The first re-registration runs at once; one within an hour
    /// of the previous re-registration is held until an hour after it, with an ERROR, so a misbehaving server can never
    /// make the SDK loop on registration. The hold is a dormant wait on the register op: no trigger, debounce or
    /// background flush shortens it, and it is persisted with the op, so it also holds after a relaunch
    /// (`restoreReregistrationHold`).
    func reregister(reason: String, after error: APIError, now: Double) {
        // A previous re-registration later than now means the clock moved back: this one is not held.
        let heldUntil = lastReregisterAt.flatMap { last in
            last <= now && now - last < Self.reregisterInterval ? last + Self.reregisterInterval : nil
        }
        let runAt = heldUntil ?? now
        lastReregisterAt = runAt
        dropCredentials()
        ensureStateOp(.register, nextAt: runAt)
        updateStateOp(.register) { op in
            // A 429 wait is never shortened.
            op.retry.nextAt = op.retry.lastFailure == .rateLimited ? max(op.retry.nextAt, runAt) : runAt
            op.retry.dormantUntil = heldUntil
        }
        removeStateOp(.update)
        guard let heldUntil else {
            logger.log(.registerReregistering, "Registering again (reason: \(reason)).",
                       metadata: [LogMetadataKey.reason: reason])
            return
        }
        let wait = heldUntil - now
        var metadata = failureMetadata(error)
        metadata[LogMetadataKey.reason] = reason
        metadata[LogMetadataKey.delay] = String(Int(wait.rounded(.up)))
        let cause = "\(error.route.method) \(error.route.template) (\(error.summary)) asked for a new registration"
        logger.log(.netClientError,
                   "\(cause) within an hour of the previous registration; registering again in "
                       + "\(Int((wait / 60).rounded(.up))) min (reason: \(reason)).",
                   metadata: metadata)
    }

    /// At engine start: a re-registration held before a relaunch keeps holding, at most an hour from now even if the
    /// clock moved back, and counts as the previous re-registration of this process (as on Android).
    func restoreReregistrationHold(now: Double) {
        guard let until = stateOp(.register)?.retry.dormantUntil else { return }
        let latest = now + Self.reregisterInterval
        if until > latest {
            updateStateOp(.register) { op in
                op.retry.dormantUntil = latest
                op.retry.nextAt = min(op.retry.nextAt, latest)
            }
        }
        lastReregisterAt = min(until, latest)
    }

    func dropCredentials() {
        credentials = nil
        credentialsUnsaved = false
        syncExtensionCredentials()
        // While consent is withheld nothing is written but consent.json, except the one minimised state a withdrawal
        // saves before its requests. A stale item left in the Keychain then is replaced by the next
        // registration, or refused by the server at the next launch, which registers again.
        if consentMode == .normal, case .failed = env.keychain.delete(account: credentialsAccount) {
            logger.log(.storageFailed, "Could not delete stale SallaPush credentials from the Keychain.")
        }
        if state.registration.status != .dormant {
            state.registration.status = .none
        }
        stateDirty = true
    }
}
