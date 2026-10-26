import Foundation
import SallaPushCore

extension Engine {
    /// Re-reads the notification permission. Reads are coalesced: at most one is in flight, and a request made
    /// meanwhile reads once more afterwards. Each read carries the sequence taken when it started, so the getters keep
    /// whichever read, the engine's or the runtime's, started last.
    func readPermission() {
        guard phase == .running else { return }
        if permissionReadInFlight {
            permissionReadAgain = true
            return
        }
        permissionReadInFlight = true
        let expectedGeneration = generation
        let sequence = host?.permissionReadStarted() ?? 0
        env.notificationCenter.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.queue.async {
                guard self.phase != .stopped, self.generation == expectedGeneration else { return }
                self.perform { engine in engine.permissionRead(status, sequence: sequence) }
            }
        }
    }

    private func permissionRead(_ status: PermissionStatus, sequence: Int) {
        permissionReadInFlight = false
        let previous = permission
        permission = status
        permissionSequence = sequence
        if let previous, previous != status {
            logger.log(.permissionChanged,
                       "Notification permission \(previous.name) → \(status.name); opted_in = \(currentOptedIn).")
        }
        maybeEnqueueUpdate(now: env.clock.now())
        if permissionReadAgain {
            permissionReadAgain = false
            readPermission()
        }
    }
}

// MARK: - Runtime

/// The permission seen by the public getters, and the app's permission requests.
extension Runtime {
    /// Reads the authorization status for the getters at `initialize`, whatever the consent: it is a read, with no
    /// write and no network. A read the engine starts later supersedes it.
    func seedPermission() {
        guard view.withLock({ $0.engine.permission == nil }) else { return }
        let sequence = permissionReadStarted()
        environment.notificationCenter.authorizationStatus { [weak self] status in
            self?.publishPermission(status, sequence: sequence)
        }
    }

    /// Publishes a permission read that started at `sequence` to the getters, unless a read that started later is
    /// already shown, and tells the permission observers when the grant changed, and the subscription observers when
    /// `optedIn` did. One ordered source of truth: an older read, the engine's included, never replaces a fresher one,
    /// so observers never flap.
    func publishPermission(_ status: PermissionStatus, sequence: Int) {
        let change: (old: EngineSnapshot, new: EngineSnapshot)? = view.withLock { view in
            guard sequence > view.engine.permissionSequence else { return nil }
            let old = view.engine
            view.setPermission(status, sequence: sequence)
            return (old, view.engine)
        }
        guard let change else { return }
        if let old = change.old.permission, old.isGranted != status.isGranted {
            observers.notifyPermissionChanged(status.isGranted)
        }
        if change.old.optedIn != change.new.optedIn {
            observers.notifySubscriptionChanged(SallaPushSubscriptionChangedState(
                previous: SallaPushSubscriptionState(id: change.old.deviceId, token: change.old.token, optedIn: change.old.optedIn),
                current: SallaPushSubscriptionState(id: change.new.deviceId, token: change.new.token, optedIn: change.new.optedIn)))
        }
    }

    /// Asks for permission. When it was denied before and `fallbackToSettings` is set, opens the app's notification
    /// settings instead. The getters are updated before the completion runs, once, on main; the engine then re-reads.
    func requestPermission(fallbackToSettings: Bool, provisional: Bool,
                           completion: (@MainActor @Sendable (Bool) -> Void)?) {
        let center = environment.notificationCenter
        let application = environment.application
        let complete: @Sendable (Bool) -> Void = { [weak self] granted in
            if let completion {
                DispatchQueue.main.async { completion(granted) }
            }
            self?.submit(.refreshPermission)
        }
        let statusSequence = permissionReadStarted()
        center.authorizationStatus { [weak self] status in
            let runtime = self
            if status == .denied && fallbackToSettings && !provisional {
                application.openNotificationSettings()
                runtime?.publishPermission(status, sequence: statusSequence)
                complete(false)
                return
            }
            center.requestAuthorization(provisional: provisional) { granted in
                if granted, let runtime {
                    runtime.controlQueue.async { runtime.registerAfterGrant() }
                }
                let sequence = runtime?.permissionReadStarted() ?? 0
                center.authorizationStatus { status in
                    runtime?.publishPermission(status, sequence: sequence)
                    complete(granted)
                }
            }
        }
    }

    /// After a grant: registers for remote notifications only when `initialize` ran with
    /// `registerForRemoteNotificationsOnInit` and consent allows it; otherwise the engine start registers (control
    /// queue).
    private func registerAfterGrant() {
        guard state.withLock({ $0.options?.registerOnInit }) == true else { return }
        loadConsentIfNeeded()
        guard !consentRequired || consentGiven == true else { return }
        environment.application.registerForRemoteNotifications()
    }
}
