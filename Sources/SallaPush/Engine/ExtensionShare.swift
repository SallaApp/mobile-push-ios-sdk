import Foundation
import SallaPushCore

/// The device credentials the app shares with its Notification Service Extension, in the App Group's Keychain access
/// group (`ExtensionCredentialsStore`), so the extension can send `received` itself. Only the current main engine
/// touches the item: it holds that engine's credentials while it runs registered with consent and has a usable App
/// Group, and is deleted everywhere else. While consent is withheld the item is only ever deleted.
extension Engine {
    /// The configured App Group, when the app can use it (the inbox's rule).
    private var usableAppGroup: String? {
        guard let group = config.appGroupIdentifier, env.appGroupContainer(group) != nil else { return nil }
        return group
    }

    /// Makes the shared item this engine's: its credentials while it runs registered with consent and has a usable App
    /// Group, else none, in any App Group (also without one configured, so a group the app's configuration dropped
    /// keeps nothing). A drain engine, a draining one and one the runtime no longer runs leave the item alone: it
    /// belongs to the current engine. The runtime makes that last check in the step that changes the item, so an engine
    /// it switches away from meanwhile can't overwrite or delete what the new one shared.
    func syncExtensionCredentials() {
        guard mode == .main, !isDraining, let host,
              let store = ExtensionCredentialsStore(appBundleIdentifier: env.bundle.bundleIdentifier,
                                                    access: env.keychain.access)
        else { return }
        if phase == .running, consentMode == .normal, let credentials, let group = usableAppGroup {
            let shared = ExtensionCredentials(appId: config.appId, base: config.base, deviceId: credentials.deviceId,
                                              secret: credentials.secret)
            // A locked Keychain (before the first unlock) is left for the next sync.
            if case let .failed(status)? = host.changeExtensionCredentials(by: self, { store.save(shared, group: group) }) {
                logger.logOnce(.storageFailed, key: "share.write",
                               "Could not share the device credentials with the Notification Service Extension (Keychain "
                                   + "status \(status)); 'received' is sent by the app only.")
            }
        } else if case let .failed(status)? = host.changeExtensionCredentials(by: self, { store.delete() }) {
            logger.logOnce(.storageFailed, key: "share.delete", Self.shareDeleteFailure(status))
        }
    }

    /// The message of a failed delete of the shared item.
    static func shareDeleteFailure(_ status: OSStatus) -> String {
        "Could not remove the device credentials shared with the Notification Service Extension (Keychain status "
            + "\(status))."
    }
}

extension Runtime {
    /// Runs `change` when `engine` is the current engine, checked under the lock that every change of the item takes,
    /// this runtime's delete included. An engine switched away from after that check finishes its change before the
    /// new engine, or this runtime, can make one; an engine that checks after the switch changes nothing.
    func changeExtensionCredentials<Result>(by engine: Engine, _ change: () -> Result) -> Result? {
        withExtensionCredentialsLock { isCurrent(engine) ? change() : nil }
    }

    /// Consent doesn't cover SallaPush and no engine runs (`waitingForConsent`, or before `initialize`): the item an
    /// earlier launch shared is deleted, so the extension can't send `received` with it. The delete reaches every App
    /// Group, so it needs none configured, and waits for an engine's change under way. Control queue.
    func forgetExtensionCredentials() {
        let engineEnvironment = engineEnvironment()
        guard let store = ExtensionCredentialsStore(appBundleIdentifier: engineEnvironment.bundle.bundleIdentifier,
                                                    access: engineEnvironment.keychain.access),
              case let .failed(status) = withExtensionCredentialsLock({ store.delete() })
        else { return }
        logger.logOnce(.storageFailed, key: "share.delete", Engine.shareDeleteFailure(status))
    }

    /// Runs `body` under `extensionCredentialsLock`. When the lock is taken, `onExtensionCredentialsLockWait` runs
    /// first, then this change waits for it.
    private func withExtensionCredentialsLock<Result>(_ body: () -> Result) -> Result {
        if !extensionCredentialsLock.try() {
            onExtensionCredentialsLockWait.current?()
            extensionCredentialsLock.lock()
        }
        defer { extensionCredentialsLock.unlock() }
        return body()
    }
}
