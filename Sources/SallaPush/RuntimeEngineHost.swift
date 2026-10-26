import Foundation
import SallaPushCore

/// The runtime's side of the engines: starting and switching them, the calls they take, what they publish (it reaches
/// the getters and the observers), and a stopped engine freeing its folder for the engine that waited for it.
extension Runtime {
    /// One publish applied to the getter view: the view before, the merged snapshot, and whether it was the process's
    /// first (the state an earlier launch left).
    private struct Publication {
        let previous: EngineSnapshot
        let merged: EngineSnapshot
        let restored: Bool
    }

    /// What starting an engine found under the state lock: the folders being drained, and the draining engines of the
    /// new engine's own folder, which hand over before it starts.
    private struct Handoff {
        let drainingFolders: [String]
        let predecessors: [Engine]
    }

    // MARK: - Starting and switching engines

    /// Creates and starts the engine of `config`, then (with consent) drain-only engines for other app ids' pending
    /// logouts (control queue). The engine takes the calls kept in the buffer once it loaded its files and runs with
    /// consent (`engineAcceptsCalls`). One engine per (app id, host) folder: when an engine still drains this folder
    /// (the app switched away and back within its 60 s, or a drain-only engine of an earlier launch), it hands over and
    /// the new engine starts once it stopped (`engineDidStop`), loading what it wrote.
    ///
    /// - Parameter withdrawingConsent: consent that was given was withdrawn while no engine ran: the engine starts only
    ///   to carry out the withdrawal and stays idle, paused, until consent is given.
    func startEngine(_ config: EngineConfig, withdrawingConsent: Bool = false) {
        let engineEnvironment = engineEnvironment()
        let engine = Engine(config: config, mode: .main, environment: engineEnvironment, host: self,
                            withdrawsConsent: withdrawingConsent)
        let handoff = state.withLock { state -> Handoff in
            state.phase = withdrawingConsent ? .paused(engine) : .running(engine)
            state.engineAccepts = false
            let predecessors = state.drainEngines.filter { $0.config.folder == config.folder }
            if !predecessors.isEmpty { state.successors[config.folder] = engine }
            return Handoff(drainingFolders: state.drainEngines.map(\.config.folder), predecessors: predecessors)
        }
        if handoff.predecessors.isEmpty {
            engine.start()
        } else {
            for predecessor in handoff.predecessors {
                predecessor.async { $0.handOver() }
            }
        }
        // Consent covers other app ids' requests too: their pending logouts wait while it is withheld.
        if !withdrawingConsent {
            startDrainOnlyEngines(excluding: config.folder)
        }
    }

    /// Starts drain-only engines for the folders of other app ids or hosts that still hold a pending logout (at most
    /// three per launch), except `folder` and the folders being drained.
    func startDrainOnlyEngines(excluding folder: String) {
        let engineEnvironment = engineEnvironment()
        var excluded = Set(drainingEngines.map(\.config.folder))
        excluded.insert(folder)
        let candidates = DrainEngineScanner.candidates(files: engineEnvironment.files,
                                                       keychain: engineEnvironment.keychain,
                                                       excludedFolder: folder)
            .filter { !excluded.contains($0.folder) }
        for candidate in candidates {
            let drain = Engine(config: candidate, mode: .drainOnly, environment: engineEnvironment, host: self)
            state.withLock { $0.drainEngines.append(drain) }
            drain.start()
        }
    }

    /// Another app id or API host: the current engine finishes its pending logout in drain mode. The getters stop
    /// anticipating the calls it was handed: it applies them to its own app id.
    func switchAway(from engine: Engine, to config: EngineConfig) {
        let previous = engine.config
        let change: String
        if previous.appId == config.appId {
            change = "app \(config.appId) on another API host; the previous host"
        } else if previous.base == config.base {
            change = "app \(config.appId) (was \(previous.appId)); the previous app"
        } else {
            change = "app \(config.appId) on another API host (was \(previous.appId)); the previous app"
        }
        logger.log(.initAppIdChanged, "Re-initialized with \(change) finishes its pending logout first.",
                   metadata: [LogMetadataKey.appId: config.appId])
        state.withLock { state in
            state.drainEngines.append(engine)
            state.phase = .starting
            state.engineAccepts = false
            let routed = state.routedThrough
            let buffered = state.buffer.callSequences
            view.withLock { $0.remove(through: routed, keeping: buffered) }
        }
        engine.async { $0.enterDrainMode() }
    }

    /// Reports the calls the pre-init buffer dropped, once an engine takes the buffer.
    func reportDropped(_ dropped: PreInitBuffer.Dropped) {
        guard dropped.total > 0 else { return }
        logger.log(.initBufferFull,
                   "Too many calls before SallaPush started; \(dropped.summary) \(dropped.verb) dropped "
                       + "(login/logout calls are kept).",
                   metadata: [LogMetadataKey.count: String(dropped.total)])
    }

    // MARK: - EngineHost

    func isCurrent(_ engine: Engine) -> Bool {
        currentEngine === engine
    }

    func engineAcceptsCalls(_ engine: Engine) -> [SequencedCall] {
        let drained: (calls: [SequencedCall], dropped: PreInitBuffer.Dropped)? = state.withLock { state in
            guard case let .running(current) = state.phase, current === engine else { return nil }
            state.engineAccepts = true
            let drained = state.buffer.drain()
            if let last = drained.calls.last?.sequence {
                state.routedThrough = max(state.routedThrough, last)
            }
            return drained
        }
        guard let drained else { return [] }
        reportDropped(drained.dropped)
        return drained.calls
    }

    func engine(_ engine: Engine, returned call: PublicCall, sequence: Int) {
        state.withLock { state in
            if case let .running(current) = state.phase, current === engine {
                state.engineAccepts = false
            }
            let removed = state.buffer.append(call, sequence: sequence)
            view.withLock { $0.remove(sequences: removed) }
        }
    }

    func engine(_ engine: Engine, didPublish snapshot: EngineSnapshot, baseline: Bool) {
        guard isCurrent(engine) else { return }
        let publication = view.withLock { view -> Publication in
            var merged = snapshot
            // The permission of the read that started last wins, the runtime's (initialize, a request) or the engine's.
            if merged.permissionSequence < view.engine.permissionSequence {
                merged.permission = view.engine.permission
                merged.permissionSequence = view.engine.permissionSequence
            }
            let publication = Publication(previous: view.engine, merged: merged, restored: baseline && !view.hasBaseline)
            if baseline { view.hasBaseline = true }
            view.publish(merged)
            return publication
        }
        let previous = publication.previous
        let merged = publication.merged
        if publication.restored {
            // The state an earlier launch left is no change: user observers hear nothing, and subscription observers
            // added before it get the replay form.
            if merged.deviceId != nil {
                let state = SallaPushSubscriptionState(id: merged.deviceId, token: merged.token, optedIn: merged.optedIn)
                observers.notifySubscriptionChanged(SallaPushSubscriptionChangedState(previous: state, current: state))
            }
        } else {
            if previous.externalId != merged.externalId || previous.isLoggedIn != merged.isLoggedIn {
                observers.notifyUserChanged(SallaPushUserChangedState(
                    previous: SallaPushUserState(externalId: previous.externalId, isLoggedIn: previous.isLoggedIn),
                    current: SallaPushUserState(externalId: merged.externalId, isLoggedIn: merged.isLoggedIn)))
            }
            if previous.deviceId != merged.deviceId || previous.token != merged.token || previous.optedIn != merged.optedIn {
                observers.notifySubscriptionChanged(SallaPushSubscriptionChangedState(
                    previous: SallaPushSubscriptionState(id: previous.deviceId, token: previous.token, optedIn: previous.optedIn),
                    current: SallaPushSubscriptionState(id: merged.deviceId, token: merged.token, optedIn: merged.optedIn)))
            }
        }
        if let old = previous.permission, let new = merged.permission, old.isGranted != new.isGranted {
            observers.notifyPermissionChanged(new.isGranted)
        }
    }

    func engine(_ engine: Engine, loginFailed failure: SallaPushLoginFailure) {
        guard isCurrent(engine) else { return }
        observers.notifyLoginFailure(failure)
    }

    func engineDidStop(_ engine: Engine) {
        let (successor, stoppedForConsent) = state.withLock { state -> (Engine?, Bool) in
            state.drainEngines.removeAll { $0 === engine }
            let stoppedForConsent = state.stoppingForConsent.remove(ObjectIdentifier(engine)) != nil
            let folder = engine.config.folder
            guard !state.drainEngines.contains(where: { $0.config.folder == folder }) else { return (nil, stoppedForConsent) }
            return (state.successors.removeValue(forKey: folder), stoppedForConsent)
        }
        // The folder is free: the engine that waited for it loads what the stopped one wrote.
        successor?.start()
        if stoppedForConsent {
            controlQueue.async { [self] in restartDrainEnginesIfAllowed() }
        }
    }

    func engineEnteredForeground(_ engine: Engine) {
        controlQueue.async { [self] in retryConsentWriteIfNeeded() }
    }
}
