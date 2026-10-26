import Foundation
import SallaPushCore

extension Engine {
    /// Seconds a draining engine may keep running.
    static let drainDeadline: Double = 60
    /// Seconds after coming to the foreground before a missing push token is reported.
    static let tokenMissingDelay: Double = 30
    /// Seconds after the first activation before a missing notification-center delegate is reported.
    static let delegateCheckDelay: Double = 2

    // MARK: - Start

    /// Starts the engine: subscribes to lifecycle events, reads the application state (one main hop), then loads
    /// the persisted state on the engine queue. Nothing here runs on the caller thread.
    func start() {
        queue.async { [self] in
            guard phase == .created else { return }
            phase = .loading
            startedAt = env.clock.now()
            guard mode == .main else {
                perform { engine in engine.load() }
                return
            }
            lifecycleSubscription = env.lifecycle.start { [weak self] event in
                self?.async { engine in engine.handleLifecycle(event) }
            }
            let expectedGeneration = generation
            env.application.applicationState { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard self.phase == .loading, self.generation == expectedGeneration else { return }
                    // A lifecycle event handled before this answer is at least as fresh: UIKit posts
                    // willEnterForeground while applicationState still reads .background.
                    if !self.lifecycleWhileLoading { self.appState = state }
                    self.launchState = state
                    self.perform { engine in engine.load() }
                }
            }
        }
    }

    /// The outcome of reading one persisted file.
    private enum Loaded<Value> {
        case value(Value)
        case absent
        case corrupt
        case protected
        case failed(String)
    }

    private func readFile<Value: Decodable>(_ path: String, as type: Value.Type) -> Loaded<Value> {
        switch env.files.read(path) {
        case let .data(data):
            guard let value = StoredJSON.decode(type, from: data) else { return .corrupt }
            return .value(value)
        case .notFound:
            return .absent
        case .protectedDataUnavailable:
            return .protected
        case let .failed(reason):
            return .failed(reason)
        }
    }

    private func setAside(_ path: String) {
        env.files.move(path, to: path.replacingOccurrences(of: ".json", with: ".corrupt.json"))
    }

    /// Loads credentials and files. A locked Keychain or protected files wait for protected data; a corrupt file is
    /// set aside and logged; the identity log lives in its own file, so a corrupt state file never loses a logout.
    func load() {
        guard phase == .loading || phase == .waitingForProtectedData else { return }
        var loadedCredentials: Credentials?
        switch env.keychain.read(account: credentialsAccount) {
        case let .found(data):
            if let stored = StoredJSON.decode(StoredCredentials.self, from: data), stored.v == 1,
               stored.appId == config.appId, stored.apiHost == config.base.origin,
               Validation.isUUID(stored.deviceId), Validation.isBase64URL(stored.deviceSecret) {
                loadedCredentials = Credentials(deviceId: stored.deviceId.lowercased(),
                                                secret: SecretString(stored.deviceSecret))
            } else {
                logger.log(.storageFailed, "Stored SallaPush credentials were malformed; registering again.")
                _ = env.keychain.delete(account: credentialsAccount)
                syncExtensionCredentials()
            }
        case .notFound:
            break
        case .locked:
            waitForProtectedData()
            return
        case let .unavailable(status):
            keychainUnavailable(status: status)
        }

        switch readFile(identityPath, as: IdentityState.self) {
        case let .value(value) where value.appId == config.appId && value.v == 1:
            identity = value
        case .value, .corrupt:
            setAside(identityPath)
            identity = IdentityState(appId: config.appId, apiBaseURL: config.base.string)
            identityDirty = true
            logger.log(.storageStateReset,
                       "SallaPush identity state was corrupt; it was reset (the app's next login or logout sets it again).")
        case .absent:
            identity = IdentityState(appId: config.appId, apiBaseURL: config.base.string)
            identityDirty = true
        case .protected:
            waitForProtectedData(file: "identity.json")
            return
        case let .failed(reason):
            storageFailed(reason)
        }

        switch readFile(statePath, as: DeviceState.self) {
        case let .value(value) where value.appId == config.appId && value.v == 1:
            state = value
        case .value, .corrupt:
            setAside(statePath)
            state = DeviceState(appId: config.appId)
            stateDirty = true
            logger.log(.storageStateReset, "SallaPush state was corrupt; it was reset (pending logouts were kept).")
        case .absent:
            state = DeviceState(appId: config.appId)
        case .protected:
            waitForProtectedData(file: "state.json")
            return
        case let .failed(reason):
            storageFailed(reason)
        }

        switch readFile(eventsPath, as: EventsState.self) {
        case let .value(value) where value.v == 1:
            events = value
        case .value, .corrupt:
            setAside(eventsPath)
            events = EventsState()
            eventsDirty = true
            logger.log(.storageStateReset, "SallaPush pending events were corrupt; they were reset (the events were dropped).")
        case .absent:
            events = EventsState()
        case .protected:
            waitForProtectedData(file: "events.json")
            return
        case let .failed(reason):
            storageFailed(reason)
        }

        credentials = loadedCredentials
        phase = .running
        afterLoad()
    }

    private func storageFailed(_ reason: String) {
        storageAvailable = false
        logger.log(.storageFailed,
                   "Could not read SallaPush state (\(LogSanitizer.clean(reason))); this launch runs without network registration.")
    }

    /// The Keychain is locked, or `file` is protected, until the first unlock: the load waits for protected data.
    private func waitForProtectedData(file: String? = nil) {
        phase = .waitingForProtectedData
        if let file {
            logger.logOnce(.storageKeychainLocked, key: "keychain.locked.\(config.folder)",
                           "SallaPush data is unavailable until first unlock (\(file) is protected); waiting.")
        } else {
            keychainLocked()
        }
        if mode == .drainOnly { stop(persistState: false) }
    }

    private func afterLoad() {
        let now = env.clock.now()
        dropInvalidIdentifiers()
        restoreMemoryState(now: now)
        reconcileRegistrationStatus(now: now)
        // A launch is a background launch only when the app never came to the foreground while the engine loaded.
        isBackgroundLaunch = mode == .main && launchState == .background && !foregroundWhileLoading
        launchedInBackground = isBackgroundLaunch
        if mode == .drainOnly {
            startDrainOnly(now: now)
            return
        }
        // What was loaded is the getters' baseline: restoring it is no change for user observers.
        publish(baseline: true)
        // A pause or a withdrawal asked for while the files loaded is applied to them now, before any start-up work.
        applyConsentAskedWhileLoading(now: now)
        if isDraining { return }
        guard consentMode == .normal else {
            // Consent is withheld: no registration, timers or inbox reads until it is given.
            startupPending = true
            return
        }
        syncExtensionCredentials()
        configureBadge()
        acceptCalls()
        startup(now: now)
    }

    /// Takes the calls the runtime kept while this engine could not take them (it was loading, or consent was withheld)
    /// and handles them in call order, before any later call.
    func acceptCalls() {
        guard mode == .main, !isDraining, phase == .running, consentMode == .normal, let host else { return }
        for entry in host.engineAcceptsCalls(self) {
            handle(entry.call, sequence: entry.sequence)
        }
    }

    /// The start-up work of a launch, run once the files are loaded and consent allows it (after the calls the app made
    /// meanwhile, so a pending login finds the launch token in memory): permission, retries, registration, pending logins
    /// without a token, remote-notification registration, the App Group check and the foreground work of the state the
    /// app is in.
    func startup(now: Double) {
        startupPending = false
        readPermission()
        applyTriggerReset(now: now)
        if state.push.token != nil, credentials == nil {
            ensureStateOp(.register, nextAt: now)
        }
        // A login whose tag clearing hasn't gone yet stays: the clearing goes first, then the link waits for a token.
        for op in identity.ops where op.kind == .login && op.id != inFlightIdentityOpId && !op.clearsTagsNext {
            loginWithoutToken(op)
        }
        if config.registerOnInit {
            env.application.registerForRemoteNotifications()
        }
        reportAppGroup()
        if isBackgroundLaunch {
            requestEventFlush()
            if !identity.ops.isEmpty || !events.pending.isEmpty { beginBackgroundTask() }
        } else {
            // The work of the foreground transitions seen while loading, then of the state the app is in now.
            foregroundWork(now: now)
            if appState == .active { becameActive(now: now) }
            if appState == .background { enteredBackground(now: now) }
        }
    }

    /// Persisted identifiers the SDK could not have written are dropped, with one ERROR naming them: most
    /// are sent back to the server, which would reject a corrupt or tampered value at every try.
    private func dropInvalidIdentifiers() {
        var dropped: [String] = []
        if let id = state.lastDeviceId, !Validation.isUUID(id) {
            state.lastDeviceId = nil
            dropped.append("last_device_id")
        }
        if let token = state.push.token, !Validation.isPushTokenHex(token) {
            state.push.token = nil
            dropped.append("push.token")
        }
        if let token = state.registration.registeredToken, !Validation.isPushTokenHex(token) {
            state.registration.registeredToken = nil
            dropped.append("registration.registered_token")
        }
        if let fingerprint = state.registration.sentFingerprint, !Validation.isUpdateFingerprint(fingerprint) {
            state.registration.sentFingerprint = nil
            dropped.append("registration.sent_fingerprint")
        }
        if !dropped.isEmpty { stateDirty = true }
        let identityDropped = identity.dropInvalidIdentifiers()
        if !identityDropped.isEmpty { identityDirty = true }
        dropped += identityDropped
        guard !dropped.isEmpty else { return }
        logger.log(.storageStateReset,
                   "SallaPush state held invalid values (\(dropped.joined(separator: ", "))); they were reset.")
    }

    /// Rebuilds the counters and caches that live only in memory from the loaded files. The decoders already bounded
    /// every persisted integer; the arithmetic saturates anyway, so no file content can trap.
    private func restoreMemoryState(now: Double) {
        let maxId = ((identity.ops.map(\.id) + state.ops.map(\.id)).max() ?? 0)
        nextOpId = max(nextOpId, maxId.saturatingIncrement)
        epoch = max(epoch, state.tags.largestEpoch.saturatingIncrement)
        clampFutureTimes(now: now)
        restoreReregistrationHold(now: now)
        seenEvents = Set(events.seen)
        firstPendingEventAt = events.pending.isEmpty ? nil : now
    }

    /// Times more than a day ahead cannot have been written by this SDK at this clock (every wait is at most a day):
    /// the device clock moved back. Such waits are cut to what they could be, so nothing waits for months (as on
    /// Android).
    private func clampFutureTimes(now: Double) {
        let horizon = now + Self.dayInSeconds
        func clamp(_ retry: inout RetryState) {
            if retry.nextAt > horizon { retry.nextAt = now }
            if let until = retry.dormantUntil, until > horizon { retry.dormantUntil = horizon }
            if retry.lastAttemptAt > horizon { retry.lastAttemptAt = now }
        }
        var identityOps = identity.ops
        for index in identityOps.indices { clamp(&identityOps[index].retry) }
        if identityOps != identity.ops {
            identity.ops = identityOps
            identityDirty = true
        }
        var stateOps = state.ops
        for index in stateOps.indices { clamp(&stateOps[index].retry) }
        if stateOps != state.ops {
            state.ops = stateOps
            stateDirty = true
        }
        if let until = state.registration.dormantUntil, until > horizon {
            state.registration.dormantUntil = horizon
            stateDirty = true
        }
    }

    /// Makes the stored registration status agree with the credentials in the Keychain and ends a dormancy that
    /// has run out. A state an earlier (pre-release) version saved may wait for answers push-service no longer gives: a
    /// token it marked dead (`token_dead`) is registered again, and a dormancy for a reason push-service no longer
    /// answers (`app_disabled`, `platform_mismatch`, `app_mismatch`) ends now. The files are kept per host, not per
    /// URL: when they were saved with another API URL, `identity.json` takes the one in use, and a dormancy for closed
    /// routes (`not_found`) ends, since the new URL may be what fixes them; one for the app id (`unknown_app`) or a
    /// refused request stays.
    private func reconcileRegistrationStatus(now: Double) {
        if credentials == nil, state.registration.status == .registered || state.registration.status == .tokenDead {
            state.registration.status = .none
            stateDirty = true
        }
        if credentials != nil, state.registration.status == .none || state.registration.status == .tokenDead {
            // A reinstall keeps the Keychain but not the files: one full update tells the server everything again.
            state.registration.status = .registered
            state.registration.sentFingerprint = nil
            stateDirty = true
        }
        if state.registration.status == .dormant, let reason = state.registration.dormantReason,
           ![DormantReason.notFound, .unknownApp, .invalidRequest].contains(reason) {
            state.registration.dormantUntil = now
        }
        if identity.apiBaseURL != config.base.string {
            identity.apiBaseURL = config.base.string
            identityDirty = true
            if state.registration.status == .dormant, state.registration.dormantReason == .notFound {
                state.registration.dormantUntil = now
            }
        }
        if state.registration.status == .dormant, (state.registration.dormantUntil ?? 0) <= now {
            state.registration.status = credentials == nil ? .none : .registered
            state.registration.dormantUntil = nil
            state.registration.dormantReason = nil
            stateDirty = true
        }
    }

    private func startDrainOnly(now: Double) {
        logger.log(.initDrainStarted, "Finishing a pending logout for app \(config.appId) from an earlier session.",
                   metadata: [LogMetadataKey.appId: config.appId])
        // A launch is a retry trigger.
        applyTriggerReset(now: now)
        schedule(.drainDeadline, after: Self.drainDeadline) { engine in engine.stop() }
    }

    /// Says once when the extension's `received` events cannot reach the app, and its badge counts can't either: no App
    /// Group is configured (INFO), or the configured one is not available to the app (ERROR: a missing App Groups
    /// capability or a typo would otherwise drop every `received` event without a word, because the extension logs its
    /// own failure in its own process).
    private func reportAppGroup() {
        guard let group = config.appGroupIdentifier else {
            guard !hasReportedNoAppGroup else { return }
            hasReportedNoAppGroup = true
            logger.log(.configNoAppGroup,
                       "No App Group configured; notifications received in the extension will not be reported as 'received', "
                           + "and SallaPush doesn't count them on the app badge.")
            return
        }
        guard env.appGroupContainer(group) == nil else { return }
        let shown = LogSanitizer.clean(group)
        logger.logOnce(.storageFailed, key: "appgroup.\(shown)",
                       "The App Group \(shown) is not available to the app; add it to the app target's App Groups capability; "
                           + "'received' events from the Notification Service Extension are not read, and SallaPush doesn't "
                           + "count notifications on the app badge.")
    }

    // MARK: - Lifecycle events

    func handleLifecycle(_ event: LifecycleEvent) {
        switch phase {
        case .created, .loading:
            // Kept for the end of the load (`afterLoad`), which does the work of the state the app is in by then.
            recordWhileLoading(event)
            return
        case .waitingForProtectedData:
            // protectedDataDidBecomeAvailable comes only on a lock-to-unlock transition. An app that comes to the
            // foreground has its data available too, so a spurious locked answer never strands the engine.
            recordWhileLoading(event)
            switch event {
            case .protectedDataAvailable, .didBecomeActive, .willEnterForeground:
                load()
            case .didEnterBackground, .timeZoneChanged, .localeChanged:
                break
            }
            return
        case .stopped:
            return
        case .running:
            break
        }
        let now = env.clock.now()
        switch event {
        case .didBecomeActive:
            appState = .active
            guard consentMode == .normal, !isDraining else {
                // Coming to the foreground ends a background launch, whether or not consent lets the work run now.
                isBackgroundLaunch = false
                return
            }
            becameActive(now: now)
        case .willEnterForeground:
            appState = .inactive
            host?.engineEnteredForeground(self)
            if isBackgroundLaunch {
                isBackgroundLaunch = false
            }
            guard consentMode == .normal, !isDraining else { return }
            foregroundWork(now: now)
        case .didEnterBackground:
            appState = .background
            guard consentMode == .normal else { return }
            enteredBackground(now: now)
        case .protectedDataAvailable:
            guard consentMode == .normal else { return }
            applyTriggerReset(now: now)
        case .timeZoneChanged, .localeChanged:
            guard consentMode == .normal else { return }
            maybeEnqueueUpdate(now: now)
        }
    }

    /// A lifecycle event that arrived before the engine ran: the app state follows it, and a foreground transition is
    /// remembered, so a background launch that came to the foreground meanwhile is not one any more.
    private func recordWhileLoading(_ event: LifecycleEvent) {
        switch event {
        case .didBecomeActive:
            appState = .active
            foregroundWhileLoading = true
            lifecycleWhileLoading = true
        case .willEnterForeground:
            appState = .inactive
            foregroundWhileLoading = true
            lifecycleWhileLoading = true
        case .didEnterBackground:
            appState = .background
            lifecycleWhileLoading = true
        case .protectedDataAvailable, .timeZoneChanged, .localeChanged:
            // The load reads protected data itself, and the first update check reads the current time zone and locale.
            break
        }
    }

    /// Work of every foreground: permission, the inbox, the update check, an event flush, the token check.
    private func foregroundWork(now: Double) {
        readPermission()
        applyTriggerReset(now: now)
        ingestInbox(now: now)
        maybeEnqueueUpdate(now: now)
        requestEventFlush()
        scheduleTokenMissingCheck()
    }

    /// Work of every activation; the first one also schedules the delegate check.
    private func becameActive(now: Double) {
        endBackgroundTask()
        if isBackgroundLaunch {
            isBackgroundLaunch = false
            foregroundWork(now: now)
        }
        readPermission()
        applyTriggerReset(now: now)
        requestEventFlush()
        badgeAppBecameActive()
        maybeEnqueueUpdate(now: now)
        scheduleTokenMissingCheck()
        if !handledFirstActive {
            handledFirstActive = true
            scheduleDelegateCheck()
        }
    }

    /// The missing-delegate check, 2 s after the first activation (never at `initialize`: apps set their delegate
    /// after it). A check that a consent pause cancelled is scheduled again when consent comes back.
    func scheduleDelegateCheck() {
        guard !checkedDelegate else { return }
        schedule(.delegateCheck, after: Self.delegateCheckDelay) { engine in
            guard engine.consentMode == .normal else { return }
            engine.checkDelegate()
        }
    }

    /// The work consent stopped, done again when it comes back: the foreground work of the state the app is in, and the
    /// check a pause cancelled (the missing-delegate check).
    func resumeStartedWork(now: Double) {
        if appState != .background {
            foregroundWork(now: now)
        }
        if handledFirstActive {
            scheduleDelegateCheck()
        }
    }

    /// Flushes at once: work that is only waiting for its debounce becomes ready now, inside a background task.
    /// Deliberate waits stay: a `logout_confirm` (60 s), a backoff, and the re-registration valve's hour.
    private func enteredBackground(now: Double) {
        guard mode == .main else { return }
        badgeAppEnteredBackground()
        requestEventFlush()
        var identityOps = identity.ops
        for index in identityOps.indices where identityOps[index].kind != .logoutConfirm
            && Self.isDebounceWait(identityOps[index].retry, window: Self.debounce, now: now) {
            identityOps[index].retry.nextAt = min(identityOps[index].retry.nextAt, now)
        }
        if identityOps != identity.ops {
            identity.ops = identityOps
            identityDirty = true
        }
        var stateOps = state.ops
        for index in stateOps.indices {
            let window = stateOps[index].kind == .tags ? Self.tagsDebounce : Self.debounce
            if Self.isDebounceWait(stateOps[index].retry, window: window, now: now) {
                stateOps[index].retry.nextAt = min(stateOps[index].retry.nextAt, now)
            }
        }
        if stateOps != state.ops {
            state.ops = stateOps
            stateDirty = true
        }
        if inFlight != nil || !identity.ops.isEmpty || !state.ops.isEmpty || !events.pending.isEmpty {
            beginBackgroundTask()
        }
    }

    /// An op that never failed and is due within its debounce window is only waiting for the debounce.
    private static func isDebounceWait(_ retry: RetryState, window: Double, now: Double) -> Bool {
        retry.lastFailure == nil && retry.dormantUntil == nil && retry.nextAt <= now + window
    }

    private func checkDelegate() {
        checkedDelegate = true
        let logger = self.logger
        env.notificationCenter.hasDelegate { hasDelegate in
            guard !hasDelegate else { return }
            logger.log(.initNoDelegate,
                       "No UNUserNotificationCenter delegate is set; foreground notifications and taps will not reach "
                           + "SallaPush. Forward them or use SallaPush.Notifications.notificationCenterDelegate.")
        }
    }

    private func scheduleTokenMissingCheck() {
        guard state.push.token == nil, !hasReportedTokenMissing, timers[.tokenMissing] == nil else { return }
        schedule(.tokenMissing, after: Self.tokenMissingDelay) { engine in
            // While consent is withheld SallaPush does not register for remote notifications, so no token is expected.
            guard engine.consentMode == .normal, engine.state.push.token == nil, engine.appState != .background,
                  !engine.hasReportedTokenMissing else { return }
            engine.hasReportedTokenMissing = true
            if let failure = engine.registrationFailure {
                engine.logger.log(.tokenMissing,
                                  "No push token 30 s after the app came to the foreground: the OS could not register for "
                                      + "remote notifications (\(failure)). Check the app's Push Notifications capability "
                                      + "(the aps-environment entitlement).")
                return
            }
            engine.logger.log(.tokenMissing,
                              "No push token 30 s after the app came to the foreground. Call "
                                  + "SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken:) from your app "
                                  + "delegate, and from any other SDK that receives the token in your app's place.")
        }
    }

    // MARK: - Stop

    /// The stop protocol, in order: mark stopped and bump the generation; cancel every timer and the network
    /// monitor; persist; end the background task; invalidate the session; remove the lifecycle observers.
    func stop(persistState: Bool = true) {
        guard phase != .stopped else { return }
        let wasRunning = phase == .running
        phase = .stopped
        generation += 1
        for item in timers.values { item.cancel() }
        timers = [:]
        reachability?.cancel()
        reachability = nil
        if persistState && wasRunning { persist() }
        endBackgroundTask()
        inFlight?.handle?.cancel()
        inFlight = nil
        transport?.invalidate()
        lifecycleSubscription?.cancel()
        lifecycleSubscription = nil
        host?.engineDidStop(self)
    }
}
