import Foundation
import SallaPushCore

/// What `consent.json` holds.
enum StoredConsent: Equatable {
    /// The last answer written: true when consent was given.
    case answer(Bool)
    /// No answer was ever written.
    case none
    /// The file is not valid JSON of the expected shape: it holds no usable answer.
    case corrupt
    /// The file cannot be read now: protected until the first unlock, or a read failure (the reason). Never taken as
    /// "never given".
    case unreadable(protected: Bool, reason: String)
}

/// `consent.json`: the user consents to the app, not to an app id, so one global file.
struct ConsentStore: Sendable {
    static let path = "consent.json"

    let files: FileStore

    /// The persisted answer, or why there is none.
    func load() -> StoredConsent {
        switch files.read(Self.path) {
        case let .data(data):
            guard let file = StoredJSON.decode(ConsentFile.self, from: data), file.v == 1 else { return .corrupt }
            return .answer(file.given)
        case .notFound:
            return .none
        case .protectedDataUnavailable:
            return .unreadable(protected: true, reason: "protected until the first unlock")
        case let .failed(reason):
            return .unreadable(protected: false, reason: reason)
        }
    }

    /// Writes the answer; false when the write failed.
    func save(_ given: Bool) -> Bool {
        guard let data = try? JSONEncoder().encode(ConsentFile(given: given)) else { return false }
        return files.write(Self.path, data: data)
    }

    /// Deletes the file, so the next launch reads "never given"; false when it is still there.
    func remove() -> Bool {
        files.remove(Self.path)
    }
}

/// What a consent withdrawal achieved on the server (memory only), for `consent.revoked`.
struct WithdrawalOutcome: Equatable {
    var registered = false
    /// The device was registered when consent was withdrawn, but an answer that landed meanwhile dropped its
    /// credentials (the server no longer knew them): nothing could be sent.
    var credentialsRefused = false
    /// The device may have been linked or held tags: the withdrawal unlinks it or clears its tags.
    var logoutNeeded = false
    var optedOut = false
    var tagsCleared = false
    var unlinked = false
    /// The steps that were refused or could not be sent, with the reason.
    var problems: [String] = []
    /// The last transient failure, named when the retries of this process run out.
    var lastFailure: String?

    /// What the server was told, in words.
    var summary: String {
        guard registered else {
            return credentialsRefused
                ? "the server refused this device's credentials meanwhile, so it could not be told"
                : "this device was not registered, so the server holds nothing to minimise"
        }
        var done: [String] = []
        if optedOut { done.append("opted out") }
        if unlinked { done.append("unlinked") }
        var parts: [String] = []
        if !done.isEmpty { parts.append(done.joined(separator: " and ") + " on the server") }
        if tagsCleared { parts.append("its tags were cleared") }
        if optedOut && !logoutNeeded { parts.append("it held no link or tags to clear") }
        return (parts + problems).joined(separator: "; ")
    }
}

extension Engine.WithdrawalStep {
    /// The step's name in log lines.
    var name: String {
        switch self {
        case .optOut: return "opt-out"
        case .clearTags: return "tag clearing"
        case .unlink: return "unlink"
        }
    }
}

extension Engine {
    /// Consent is required and not given: no network, and nothing is written but `consent.json`, until consent comes back
    /// (a withdrawal saves its one minimised state before its requests, `withdrawConsent`). Asked for before the files are
    /// loaded, the pause is applied when the load ends, before any start-up work.
    func pauseForConsent() {
        guard phase != .stopped else { return }
        guard phase == .running else {
            if consentAfterLoad == .normal { consentAfterLoad = .paused }
            return
        }
        guard consentMode == .normal else { return }
        persist()
        enterConsentPause()
    }

    /// Stops what consent covers: the request in flight, retries, the checks waiting on timers, the network monitor and
    /// the background task. Nothing is sent, and nothing written but `consent.json`, until consent
    /// comes back.
    private func enterConsentPause() {
        consentMode = .paused
        syncExtensionCredentials()
        pauseBadge()
        inFlight?.handle?.cancel()
        inFlight = nil
        cancelTimer(.pump)
        cancelConsentBoundWork()
        reachability?.cancel()
        reachability = nil
        endBackgroundTask()
    }

    /// Cancels the work that would act on the app's behalf while consent is withheld: the missing-token and
    /// missing-delegate checks. Consent coming back schedules them again.
    private func cancelConsentBoundWork() {
        cancelTimer(.tokenMissing)
        cancelTimer(.delegateCheck)
    }

    /// Consent withdrawn after it was given: drop every unsent non-identity op and stop events; if
    /// registered, send one `PUT {opted_in: false}`, one `PATCH tags` removing every key SallaPush held when the device
    /// may have tags (and once more the keys the answer still names), and one unlink when it may be linked, retried in
    /// this process only; then go idle. The credentials and the pending identity ops stay, so a later consent reuses the
    /// same row and still sends a pending logout.
    ///
    /// A request on the wire is not cancelled: it may already have reached the server, so it is let land or fail, and
    /// its answer is applied in memory (a registration's credentials included, which reach the Keychain only once
    /// consent is given again). The requests above are decided once nothing is on the wire (`pumpWithdrawal`), so a
    /// registration or a login answered after the withdrawal is minimised too (as on Android).
    ///
    /// Asked for before the files are loaded, the withdrawal runs on them when the load ends. A paused engine (consent
    /// required and not given) can be withdrawn too: its files are minimised the same way.
    ///
    /// The write rule while consent is withheld: nothing is written but `consent.json`, except the one
    /// minimised state a withdrawal saves before its requests, the state written now. It already assumes those requests
    /// took effect, whatever their answers: the opt-out is never taken as sent and the link and tags are unknown. So a
    /// later consent, in this process or after a relaunch, sends a full update (`opted_in`) and a login the launch call
    /// never skips (Android's `reconcileAfterWithdrawal`). Neither the file nor the getters keep the customer's id or the
    /// tags; the identity token in memory still links the customer when consent is given again in this process.
    func withdrawConsent() {
        guard phase != .stopped else { return }
        guard phase == .running else {
            withdrawsAfterLoad = true
            consentAfterLoad = .withdrawing
            return
        }
        guard consentMode != .withdrawing else { return }
        // A login or a tags request on the wire may still link the device or leave tags: what is written counts them.
        let mayBeLinked = identity.serverLink != .none || loginMayHaveLinked
        let mayHaveTags = identity.serverTags != .none || isTagsRequestInFlight
        withdrawalTagKeys = state.tags.heldKeys
        withdrawalTagsRechecked = false
        cancelConsentBoundWork()
        // The register op (and its own dormant wait) stays for a later consent, as on Android.
        state.ops.removeAll { $0.kind != .register }
        state.tags.pendingAdd = [:]
        state.tags.pendingRemove = [:]
        launchTags = [:]
        tagsSplitMode = false
        events.pending = []
        firstPendingEventAt = nil
        forceEventFlush = false
        // The getters forget the customer's id and the tags; an answer still on the wire never brings them back. The
        // link and the server's tags stay as known, to decide the withdrawal's requests.
        identity.desiredExternalId = nil
        if mayHaveTags { resetTagMirror() }
        var stateCopy = state
        var identityCopy = identity
        Self.minimise(identity: &identityCopy, state: &stateCopy, mayBeLinked: mayBeLinked, mayHaveTags: mayHaveTags)
        // The customer's id leaves the disk with its unsent logins; a sent one is kept as `server_link` unknown.
        identityCopy.ops.removeAll { $0.kind == .login }
        persistCopies(state: stateCopy, identity: identityCopy)
        consentMode = .withdrawing
        syncExtensionCredentials()
        forgetBadge()
        withdrawnInThisProcess = true
        withdrawalSteps = []
        withdrawalDecided = false
        withdrawalRetry = RetryState()
        forgetRetry(id: Self.withdrawalRetryId)
        withdrawalOutcome = WithdrawalOutcome(registered: credentials != nil)
    }

    /// The state a withdrawal leaves, on disk at once and in memory when consent is given again: as if its requests
    /// took effect, whatever their answers. The update fingerprint is forgotten, so the next update sends `opted_in`;
    /// a link that may exist is unknown, so the launch `login()` is never skipped; tags that may exist are unknown; the
    /// customer's id is not kept.
    static func minimise(identity: inout IdentityState, state: inout DeviceState, mayBeLinked: Bool, mayHaveTags: Bool) {
        state.registration.sentFingerprint = nil
        identity.desiredExternalId = nil
        if mayBeLinked {
            identity.serverLink = .unknown
            identity.linkedExternalId = nil
        }
        if mayHaveTags {
            state.tags.mirror = [:]
            identity.serverTags = .unknown
        }
    }

    /// Decides the withdrawal's requests once nothing is on the wire, from what is known after every answer: the
    /// opt-out when the device is registered, the tag clearing when it may have tags, and the unlink when it may be
    /// linked (a link, a login sent, a login of unknown outcome).
    private func decideWithdrawalSteps() {
        withdrawalDecided = true
        let registered = credentials != nil
        let mayBeLinked = identity.serverLink != .none || loginMayHaveLinked
        let mayHaveTags = identity.serverTags != .none
        withdrawalOutcome = WithdrawalOutcome(registered: registered,
                                              credentialsRefused: !registered && withdrawalOutcome.registered,
                                              logoutNeeded: mayBeLinked || mayHaveTags)
        guard registered else { return }
        withdrawalSteps = [.optOut]
        if mayHaveTags { withdrawalSteps.append(.clearTags) }
        if mayBeLinked { withdrawalSteps.append(.unlink) }
    }

    /// Applies the pause, withdrawal or resumption asked for while the files loaded, before any start-up work: a
    /// withdrawal runs on the loaded files, then consent may already be back.
    func applyConsentAskedWhileLoading(now: Double) {
        let target = consentAfterLoad
        let withdraws = withdrawsAfterLoad
        consentAfterLoad = .normal
        withdrawsAfterLoad = false
        if withdraws {
            withdrawConsent()
            if target == .normal {
                restoreConsent(now: now)
            }
        } else if target == .paused {
            enterConsentPause()
        }
    }

    /// Sends the next withdrawal request. The pump calls it only when nothing is on the wire.
    func pumpWithdrawal(now: Double) {
        if !withdrawalDecided {
            decideWithdrawalSteps()
        }
        guard let step = withdrawalSteps.first else {
            finishWithdrawal()
            return
        }
        guard isReady(withdrawalRetry, id: Self.withdrawalRetryId, now: now) else {
            if exhausted.contains(Self.withdrawalRetryId) {
                // The retries of this process ran out: the withdrawal ends here instead of waiting for a trigger.
                withdrawalOutcome.problems.append("the \(step.name) could not be sent in this process "
                                                      + "(\(withdrawalOutcome.lastFailure ?? "no answer"))")
                finishWithdrawal()
            } else {
                scheduleWake(now: now)
            }
            return
        }
        guard let credentials, let client = apiClient() else {
            finishWithdrawal()
            return
        }
        withdrawalRetry.lastAttemptAt = now
        let requestId = beginRequest(.withdrawal(step), now: now)
        let handle: HTTPTaskHandle?
        switch step {
        case .optOut:
            let body = UpdateBody(pushToken: nil, apnsEnv: nil, optedIn: false, metadata: nil)
            handle = client.update(deviceId: credentials.deviceId, secret: credentials.secret, body: body,
                                   completion: completion(for: requestId) { engine, result, _ in
                                       engine.withdrawalAnswered(step, failure: result.failureValue)
                                   })
        case .clearTags:
            handle = client.tags(deviceId: credentials.deviceId, secret: credentials.secret,
                                 body: TagsBody(add: [:], remove: withdrawalTagKeys),
                                 completion: completion(for: requestId) { engine, result, _ in
                                     engine.withdrawalTagsAnswered(result)
                                 })
        case .unlink:
            handle = client.unlink(deviceId: credentials.deviceId, secret: credentials.secret,
                                   completion: completion(for: requestId) { engine, result, _ in
                                       engine.withdrawalAnswered(step, failure: result.failureValue)
                                   })
        }
        attach(handle, to: requestId, now: now)
    }

    /// The withdrawal's tag clearing: tags the answer still names, which SallaPush did not know of, go with one more
    /// request.
    private func withdrawalTagsAnswered(_ result: APIResult<TagsResponse>) {
        guard case let .success(success) = result else {
            withdrawalAnswered(.clearTags, failure: result.failureValue)
            return
        }
        let held = success.value.tags
        if !held.isEmpty, !withdrawalTagsRechecked {
            withdrawalTagKeys = held.keys.sorted()
            withdrawalTagsRechecked = true
            withdrawalRetry = RetryState()
            forgetRetry(id: Self.withdrawalRetryId)
            return
        }
        // Tags the server still names after one more request (another writer's) stay unknown, for the next clearing.
        identity.serverTags = held.isEmpty ? .none : .unknown
        identityDirty = true
        if !held.isEmpty {
            withdrawalOutcome.problems.append("the server still holds tags SallaPush could not clear")
        }
        withdrawalAnswered(.clearTags, failure: nil, tagsCleared: held.isEmpty)
    }

    private func withdrawalAnswered(_ step: WithdrawalStep, failure: APIError?, tagsCleared: Bool = true) {
        let now = env.clock.now()
        if let failure, failure.isTransient || failure.isRateLimited {
            withdrawalOutcome.lastFailure = failure.summary
            applyTransientFailure(failure, to: .withdrawal(step), now: now)
            return
        }
        // Success, or a final answer (4xx): this data-minimising step is done either way. Consent rules out the
        // re-registration a device-route answer would otherwise start.
        withdrawalSteps.removeAll { $0 == step }
        withdrawalRetry = RetryState()
        forgetRetry(id: Self.withdrawalRetryId)
        if let failure {
            withdrawalRefused(step, failure: failure)
        } else {
            switch step {
            case .optOut:
                withdrawalOutcome.optedOut = true
            case .clearTags:
                withdrawalOutcome.tagsCleared = tagsCleared
            case .unlink:
                linkCleared()
                withdrawalOutcome.unlinked = true
            }
        }
        if withdrawalSteps.isEmpty {
            finishWithdrawal()
        }
    }

    /// A withdrawal step the server refused: the refusal is logged with what support needs, and named by
    /// `consent.revoked`.
    private func withdrawalRefused(_ step: WithdrawalStep, failure: APIError) {
        withdrawalOutcome.problems.append("the \(step.name) was refused (\(failure.summary))")
        if failure.status == 404 && failure.code == "not_found" {
            logger.log(.netRoutesClosed,
                       "SallaPush is unavailable (404 not_found); the consent withdrawal's \(step.name) was not applied.",
                       metadata: failureMetadata(failure))
        } else {
            logger.log(.netClientError,
                       "\(failure.route.method) \(failure.route.template) was rejected (\(failure.summary)); the consent "
                           + "withdrawal's \(step.name) was not applied.",
                       metadata: failureMetadata(failure))
        }
    }

    private func finishWithdrawal() {
        withdrawalSteps = []
        enterConsentPause()
        logger.log(.consentRevoked, "Consent withdrawn; \(withdrawalOutcome.summary). SallaPush is now idle.")
        finishDrainIfDone()
    }

    /// Consent given again in this process: resume with the in-memory state and write it out, then take the calls the
    /// runtime kept meanwhile and do the work consent stopped (the whole start-up work when consent was withheld from
    /// the start). That state already assumes every withdrawal request took effect, one still on the wire included: the
    /// next update sends `opted_in` again, and the asserted customer is logged in again with the token in memory
    /// (Android's `resumeAfterConsent`). Before the files are loaded, the load simply ends without a pause. An engine a
    /// switch left finishing its pending logouts while consent was withheld sends them now, and nothing else.
    func resumeAfterConsent() {
        guard phase != .stopped else { return }
        guard phase == .running else {
            consentAfterLoad = .normal
            return
        }
        guard consentMode != .normal else { return }
        let now = env.clock.now()
        restoreConsent(now: now)
        // An engine finishing its pending logouts is done here: the pump sends them, then stops it.
        guard mode == .main, !isDraining else { return }
        acceptCalls()
        if startupPending {
            startup(now: now)
        } else {
            resumeStartedWork(now: now)
        }
    }

    /// Leaves the consent pause or withdrawal. A withdrawal request still on the wire is left behind and its effect
    /// assumed; a request that was on the wire before the withdrawal lands as usual. After a withdrawal, the state in
    /// memory becomes what was written for it (`minimise`), with what the server confirmed; credentials a registration
    /// answered meanwhile reach the Keychain; every file is written again; the permission is read, the asserted customer
    /// is linked again and an update re-sends `opted_in` (not by an engine finishing its pending logouts, which sends
    /// nothing else).
    private func restoreConsent(now: Double) {
        if case .withdrawal? = inFlight?.kind {
            inFlight?.handle?.cancel()
            inFlight = nil
        }
        if withdrawnInThisProcess {
            withdrawnInThisProcess = false
            let mayBeLinked = identity.serverLink != .none || loginMayHaveLinked
            let mayHaveTags = identity.serverTags != .none || isTagsRequestInFlight
            if mayHaveTags { resetTagMirror() }
            Self.minimise(identity: &identity, state: &state, mayBeLinked: mayBeLinked, mayHaveTags: mayHaveTags)
        }
        consentMode = .normal
        withdrawalSteps = []
        withdrawalDecided = false
        forgetRetry(id: Self.withdrawalRetryId)
        if credentialsUnsaved, let credentials {
            credentialsUnsaved = false
            saveCredentials(credentials)
        }
        syncExtensionCredentials()
        configureBadge()
        identityDirty = true
        stateDirty = true
        eventsDirty = true
        guard mode == .main, !isDraining else { return }
        readPermission()
        relinkAfterConsent(now: now)
        maybeEnqueueUpdate(now: now)
    }

    /// The withdrawal forgot the asserted customer's id and may have unlinked them: the identity token in memory names
    /// the customer again and links them again; without one, the app's next `login` call does.
    private func relinkAfterConsent(now: Double) {
        guard identity.desired == .customer, let token = identityToken else { return }
        if identity.desiredExternalId == nil {
            identity.desiredExternalId = token.externalId
            identityDirty = true
        }
        guard identity.desiredExternalId == token.externalId, loginOp(for: token.externalId) == nil,
              identity.serverLink != .linked || identity.linkedExternalId != token.externalId
        else { return }
        enqueueLogin(externalId: token.externalId, clearTags: false, tagKeys: [], now: now)
    }
}

extension Result {
    /// The failure, or nil on success.
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
