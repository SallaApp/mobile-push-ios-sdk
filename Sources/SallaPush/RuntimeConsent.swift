import Foundation
import SallaPushCore

/// Consent at the runtime level: `consent.json`, waiting for consent, withdrawal and resumption.
/// `setConsentRequired` and `setConsentGiven` are called from any thread; everything else runs on the control queue.
extension Runtime {
    var consentRequired: Bool {
        state.withLock { $0.consentRequiredByCall || $0.consentRequiredByConfiguration }
    }

    /// Reads `consent.json` until one read succeeds. A file that cannot be read (protected until the first unlock, a
    /// read failure) is never taken as "never given": the answer stays unknown, so a consent-required app
    /// waits, and the file is read again at the next unlock, foreground, consent call or `initialize`. Nothing is written
    /// to it before it was read, so an answer the app gives meanwhile is compared with the stored one first: withdrawing
    /// a consent the file still holds is a withdrawal.
    func loadConsentIfNeeded() {
        guard !consentLoaded else { return }
        let stored = ConsentStore(files: engineEnvironment().files).load()
        let value: Bool?
        switch stored {
        case let .answer(given):
            value = given
        case .none:
            value = nil
        case .corrupt:
            value = nil
            logger.logOnce(.storageStateReset, key: "consent.corrupt",
                           "SallaPush consent (consent.json) was corrupt; it counts as not given until the app sets it again.")
        case let .unreadable(protected, reason):
            watchConsentFile(protected: protected, reason: reason)
            return
        }
        consentLoaded = true
        stopWatchingConsentFile()
        if let answer = appConsentAnswer {
            // An app that gave consent in this process and withdrew it again had its withdrawal carried out then.
            if !answer && value == true && !appGaveConsent { withdrawalPending = true }
        } else {
            consentGiven = value
        }
        retryConsentWriteIfNeeded()
    }

    func setConsentRequired(_ required: Bool) {
        state.withLock { $0.consentRequiredByCall = required }
        controlQueue.async { [self] in reevaluateConsent() }
    }

    func setConsentGiven(_ given: Bool) {
        controlQueue.async { [self] in applyConsent(given) }
    }

    /// The app's answer. Withdrawing a consent that was given (in this process or stored) starts the withdrawal
    /// as soon as consent is required: at once on a running engine, else at `initialize` by an engine started only to
    /// carry it out.
    private func applyConsent(_ given: Bool) {
        loadConsentIfNeeded()
        let previous = consentGiven
        consentGiven = given
        appConsentAnswer = given
        if given { appGaveConsent = true }
        if consentLoaded {
            persistConsent(given)
        } else {
            pendingConsentWrite = given
        }
        if given {
            withdrawalPending = false
            if previous != true {
                logger.log(.consentGiven, "Consent given; SallaPush starts.")
            }
            resumeIfAllowed()
            return
        }
        if previous == true {
            withdrawalPending = true
        }
        withholdConsent()
    }

    /// Writes `consent.json`. When that fails, a withdrawal removes the stale file, so the next launch waits for
    /// consent instead of reading an old `given: true`; the write is retried at the next consent call, `initialize`
    /// or foreground.
    private func persistConsent(_ given: Bool) {
        let store = ConsentStore(files: engineEnvironment().files)
        if store.save(given) {
            pendingConsentWrite = nil
            return
        }
        pendingConsentWrite = given
        let removed = !given && store.remove()
        logger.logOnce(.storageFailed, key: "write.consent.json",
                       "Could not write SallaPush consent (consent.json)"
                           + (removed ? "; the old file was removed, so the next launch waits for consent" : "")
                           + "; it is written again at the next consent call, initialize or foreground.")
    }

    /// Writes a consent answer whose write failed or waited for the file to be read (control queue).
    func retryConsentWriteIfNeeded() {
        guard consentLoaded, let pending = pendingConsentWrite else { return }
        persistConsent(pending)
    }

    func reevaluateConsent() {
        loadConsentIfNeeded()
        retryConsentWriteIfNeeded()
        if !consentRequired || consentGiven == true {
            resumeIfAllowed()
            return
        }
        withholdConsent()
    }

    /// Consent is required and not given. A running engine pauses, or carries out a pending withdrawal; without an
    /// engine, a pending withdrawal starts one to carry it out, otherwise SallaPush waits for consent. Engines finishing
    /// other app ids' logouts stop: consent covers every request (their logouts stay on disk until consent is back).
    /// Before `initialize`, the device credentials shared with the extension are deleted at once, and a pending
    /// withdrawal waits for `initialize`. Once `consent.json` was read, the badge files go too; until then they stay,
    /// since a file that can't be read is never taken as "never given".
    private func withholdConsent() {
        guard consentRequired else { return }
        let phase = state.withLock { $0.phase }
        switch phase {
        case let .running(engine):
            state.withLock { state in
                state.phase = .paused(engine)
                state.engineAccepts = false
            }
            stopDrainingEngines()
            if withdrawalPending {
                withdrawalPending = false
                engine.async { $0.withdrawConsent() }
            } else {
                engine.async { $0.pauseForConsent() }
                logConsentWaiting()
            }
            if consentLoaded { engine.async { $0.forgetBadgeWhileConsentIsWithheld() } }
        case let .paused(engine):
            if consentLoaded { engine.async { $0.forgetBadgeWhileConsentIsWithheld() } }
            guard withdrawalPending else { return }
            withdrawalPending = false
            engine.async { $0.withdrawConsent() }
        case let .waitingForConsent(config):
            if consentLoaded { forgetBadge(of: config) }
            guard withdrawalPending else { return }
            withdrawalPending = false
            startEngine(config, withdrawingConsent: true)
        case .idle, .starting, .invalid:
            forgetExtensionCredentials()
        }
    }

    func logConsentWaiting() {
        logger.logOnce(.consentWaiting, key: "consent.waiting",
                       "Waiting for setConsentGiven(true); nothing is sent or stored until then.")
    }

    /// Stops the engines finishing other app ids' logouts without writing anything: what they did is already on disk.
    /// Consent given again starts them again (once they stopped: `restartDrainEnginesIfAllowed`), else a launch with
    /// consent does.
    private func stopDrainingEngines() {
        let engines = state.withLock { state -> [Engine] in
            state.stoppingForConsent.formUnion(state.drainEngines.map(ObjectIdentifier.init))
            return state.drainEngines
        }
        for engine in engines {
            engine.async { $0.stop(persistState: false) }
        }
    }

    /// A drain engine stopped for consent has stopped (control queue). Consent given back before that could not restart
    /// it while it still held its folder, so the engines finishing other app ids' logouts start now.
    func restartDrainEnginesIfAllowed() {
        guard !consentRequired || consentGiven == true, case let .running(engine) = state.withLock({ $0.phase }) else { return }
        startDrainOnlyEngines(excluding: engine.config.folder)
    }

    /// Consent allows SallaPush to run: the engine waiting for it starts, a paused one resumes, and so do the engines
    /// finishing other app ids' logouts.
    func resumeIfAllowed() {
        // An engine a switch left finishing its pending logouts while consent was withheld sends them now.
        for engine in drainingEngines {
            engine.async { $0.resumeAfterConsent() }
        }
        let phase = state.withLock { $0.phase }
        switch phase {
        case let .waitingForConsent(config):
            startEngine(config)
        case let .paused(engine):
            // The engine takes the calls kept meanwhile itself, once it resumed (`engineAcceptsCalls`).
            state.withLock { state in
                state.phase = .running(engine)
                state.engineAccepts = false
            }
            engine.async { $0.resumeAfterConsent() }
            startDrainOnlyEngines(excluding: engine.config.folder)
        default:
            break
        }
    }

    // MARK: - An unreadable consent.json

    /// Reads `consent.json` again when it may have become readable: at the first unlock and when the app comes to the
    /// foreground. No engine exists while SallaPush waits for consent, so the runtime watches these itself.
    private func watchConsentFile(protected: Bool, reason: String) {
        guard consentFileWatch == nil else { return }
        if protected {
            logger.logOnce(.storageKeychainLocked, key: "consent.locked",
                           "SallaPush consent (consent.json) is unavailable until first unlock; waiting.")
        } else {
            logger.logOnce(.storageFailed, key: "read.consent.json",
                           "Could not read SallaPush consent (consent.json: \(LogSanitizer.clean(reason))); it is read again "
                               + "at the next foreground, consent call or initialize.")
        }
        consentFileWatch = engineEnvironment().lifecycle.start { [weak self] event in
            switch event {
            case .protectedDataAvailable, .willEnterForeground, .didBecomeActive:
                guard let runtime = self else { return }
                runtime.controlQueue.async { runtime.consentFileMayBeReadable() }
            case .didEnterBackground, .timeZoneChanged, .localeChanged:
                break
            }
        }
    }

    private func stopWatchingConsentFile() {
        let watch = consentFileWatch
        consentFileWatch = nil
        watch?.cancel()
    }

    private func consentFileMayBeReadable() {
        guard !consentLoaded else { return }
        loadConsentIfNeeded()
        guard consentLoaded else { return }
        reevaluateConsent()
    }
}
