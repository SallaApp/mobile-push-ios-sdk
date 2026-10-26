import Foundation
import SallaPushCore

/// SallaPush's part of the app icon badge: the count of SallaPush notifications that the Notification Service Extension
/// keeps in the App Group (`BadgeStore`), and the number the app sets on the icon. One per runtime, with its own serial
/// queue, so no file or notification-center call runs on the caller's thread: the router calls it from `willPresent`
/// and `didReceive`, on main.
///
/// The current main engine configures it while it runs with consent, and pauses it while consent is withheld; while
/// it is paused, or before it was configured, SallaPush neither counts nor clears.
final class BadgeKeeper: @unchecked Sendable {
    /// The app's two badge settings.
    struct Policy: Equatable, Sendable {
        var autoClearBadge: Bool
        var autoUpdateBadge: Bool
    }

    private struct State {
        /// The settings of the engine that configured the keeper last; nil before.
        var policy: Policy?
        /// That app's badge files; nil without a usable App Group.
        var store: BadgeStore?
        /// Whether consent lets SallaPush count and clear: `configure` sets it, `pause` and `forget` clear it.
        var active = false
        /// Bumped by every `configure`, `pause` and `forget`, so a correction they overtook does nothing.
        var generation = 0
        /// The identifiers that taps and `clearAll()` removed in this process, newest last: a correction made before
        /// iOS removed them from Notification Center doesn't count them again.
        var recentlyRemoved: [String] = []
    }

    /// The most identifiers `recentlyRemoved` keeps.
    static let recentlyRemovedLimit = 100

    let queue = DispatchQueue(label: "com.salla.push.badge", qos: .utility)
    private let state = Locked(State())
    private let notificationCenter: NotificationCenterClient
    private let application: ApplicationClient
    private let clock: Clock
    private let logger: SDKLogger

    init(notificationCenter: NotificationCenterClient, application: ApplicationClient, clock: Clock, logger: SDKLogger) {
        self.notificationCenter = notificationCenter
        self.application = application
        self.clock = clock
        self.logger = logger
    }

    // MARK: - Consent and settings

    /// The current main engine runs with consent: SallaPush counts and clears with `policy`, and writes it to the App
    /// Group, where the extension reads it. With `autoUpdateBadge` off the marks go too.
    func configure(policy: Policy, store: BadgeStore?) {
        state.withLock { state in
            state.policy = policy
            state.store = store
            state.active = true
            state.generation += 1
        }
        guard let store else { return }
        let logger = self.logger
        queue.async {
            if !store.writeSettings(BadgeSettings(autoUpdateBadge: policy.autoUpdateBadge)) {
                logger.logOnce(.storageFailed, key: "badge.settings",
                               "Could not write SallaPush's badge settings to the App Group; the Notification Service "
                                   + "Extension doesn't count notifications on the app badge.")
            }
            if !policy.autoUpdateBadge { store.reset() }
        }
    }

    /// Consent is withheld, or may be (it can't be read yet): SallaPush stops counting and clearing; the files stay.
    func pause() {
        state.withLock { state in
            state.active = false
            state.generation += 1
        }
    }

    /// Consent is known to be withheld: the settings and the marks of `store` go, so the extension stops counting, and
    /// the icon goes to 0 when SallaPush had counted.
    func forget(store: BadgeStore?) {
        pause()
        guard let store else { return }
        queue.async { [self] in
            let counted = store.readSettings()?.autoUpdateBadge == true || store.count() > 0
            store.removeAll()
            if counted { setIcon(0, of: store, delivered: nil) }
        }
    }

    // MARK: - The app's lifecycle

    /// The app became active. With `autoClearBadge`, the count and the icon go to 0 (on iOS 15 only when the icon is
    /// above 0, as `applicationIconBadgeNumber` = 0 also removes the app's delivered notifications). Without it, the
    /// count is corrected from Notification Center.
    func appBecameActive() {
        queue.async { [self] in
            let current = state.current
            guard current.active, let policy = current.policy else { return }
            if policy.autoClearBadge {
                current.store?.reset()
                if !notificationCenter.setBadgeCount(0) { application.setIconBadge(0) }
                logger.log(.badgeCleared, "The app became active: SallaPush set the app badge to 0.")
            } else if policy.autoUpdateBadge, current.store != nil {
                reconcile(generation: current.generation)
            }
        }
    }

    /// The app went to the background: without `autoClearBadge`, the count is corrected from Notification Center.
    func appEnteredBackground() {
        queue.async { [self] in
            let current = state.current
            guard current.active, let policy = current.policy, policy.autoUpdateBadge, !policy.autoClearBadge,
                  current.store != nil
            else { return }
            reconcile(generation: current.generation)
        }
    }

    // MARK: - Notifications

    /// `willPresent` answered for the SallaPush notification `identifier`. Its mark goes when the badge doesn't show it:
    /// `autoClearBadge` keeps the badge at 0 while the app is open, and a notification held back isn't shown.
    func presented(identifier: String, shown: Bool) {
        queue.async { [self] in
            let current = state.current
            guard current.active, let policy = current.policy, policy.autoUpdateBadge, let store = current.store,
                  policy.autoClearBadge || !shown
            else { return }
            store.remove(identifier: identifier)
        }
    }

    /// The SallaPush notification `identifier` was opened or dismissed: it leaves the count at once, and without
    /// `autoClearBadge` the icon shows the new count.
    func opened(identifier: String) {
        queue.async { [self] in
            let current = state.current
            guard current.active, let policy = current.policy, policy.autoUpdateBadge, let store = current.store else { return }
            store.remove(identifier: identifier)
            remember([identifier])
            if !policy.autoClearBadge {
                setIcon(store.count(), of: store, delivered: nil, generation: current.generation)
            }
        }
    }

    /// `clearAll()` removed `removed`, SallaPush's notifications of `delivered`, what Notification Center held: the
    /// count and the icon go to 0.
    func clearedAll(removed: [String], delivered: [DeliveredNotification]) {
        queue.async { [self] in
            let current = state.current
            guard current.active, let policy = current.policy, policy.autoUpdateBadge else { return }
            remember(removed)
            current.store?.reset()
            setIcon(0, of: current.store, delivered: delivered)
        }
    }

    /// Hands the local copy that `display()` posts to `post`, with SallaPush's badge: counted, and carrying the count,
    /// while `autoUpdateBadge` is on, `autoClearBadge` off and the App Group usable; without a badge while
    /// `autoUpdateBadge` is on otherwise; with the push's own badge while SallaPush doesn't count. A change of consent
    /// or settings before the copy is counted decides it again, so a withdrawal never gets a mark back.
    func localCopy(_ request: LocalNotificationRequest, post: @escaping @Sendable (LocalNotificationRequest) -> Void) {
        let current = state.current
        guard current.active, let policy = current.policy, policy.autoUpdateBadge else { return post(request) }
        guard !policy.autoClearBadge, let store = current.store else { return post(request.with(badge: nil)) }
        let generation = current.generation
        queue.async { [self] in
            guard state.current.generation == generation else { return localCopy(request, post: post) }
            _ = store.add(identifier: request.identifier, at: clock.now())
            let count = store.count()
            post(request.with(badge: count > 0 ? NSNumber(value: count) : nil))
        }
    }

    // MARK: - Corrections and the icon

    /// Makes the count match Notification Center: the marks of the SallaPush notifications no longer there go (a
    /// mark of the last minute stays, its notification may still be in the extension), one is added for each SallaPush
    /// notification there without one, unless a tap or `clearAll()` just removed it, and the icon shows the count.
    /// iOS doesn't tell apps of a notification the user clears, so this is when the badge follows one.
    private func reconcile(generation: Int) {
        notificationCenter.deliveredNotifications { [self] delivered in
            queue.async { [self] in
                let current = state.current
                guard current.active, current.generation == generation, let store = current.store else { return }
                let identifiers = delivered.filter { PayloadParser.kind(of: $0.userInfo) != nil }.map(\.identifier)
                let now = clock.now()
                _ = store.prune(keeping: Set(identifiers), now: now)
                store.add(identifiers: identifiers.filter { !current.recentlyRemoved.contains($0) }, at: now)
                setIcon(store.count(), of: store, delivered: delivered)
            }
        }
    }

    /// Sets the icon to `count`: `setBadgeCount` on iOS 16 and later, `applicationIconBadgeNumber` on iOS 15. There a 0
    /// also removes the app's delivered notifications, other SDKs' included, so it is written only when Notification
    /// Center holds no notification but SallaPush's (`delivered`, read now when nil) and `store` still counts none: a
    /// notification counted since would go too. A read for `generation` writes nothing once a change of consent or
    /// settings overtook it; a withdrawal passes none, so its 0 stays due.
    private func setIcon(_ count: Int, of store: BadgeStore?, delivered: [DeliveredNotification]?,
                         generation: Int? = nil) {
        if notificationCenter.setBadgeCount(count) {
            logSet(count)
        } else if count > 0 {
            application.setIconBadge(count)
            logSet(count)
        } else if let delivered {
            setZeroOnIOS15(of: store, delivered: delivered)
        } else {
            notificationCenter.deliveredNotifications { [self] delivered in
                queue.async { [self] in
                    if let generation, state.current.generation != generation { return }
                    setZeroOnIOS15(of: store, delivered: delivered)
                }
            }
        }
    }

    private func setZeroOnIOS15(of store: BadgeStore?, delivered: [DeliveredNotification]) {
        guard (store?.count() ?? 0) == 0 else { return }
        guard !delivered.contains(where: { PayloadParser.kind(of: $0.userInfo) == nil }) else {
            logger.log(.badgeZeroSkipped, "SallaPush left the app badge as it is: on iOS 15, a badge set to 0 also "
                           + "removes the app's other delivered notifications.")
            return
        }
        application.setIconBadge(0)
        logSet(0)
    }

    private func logSet(_ count: Int) {
        logger.log(.badgeSet, "SallaPush set the app badge to \(count).", metadata: [LogMetadataKey.count: String(count)])
    }

    private func remember(_ identifiers: [String]) {
        state.withLock { state in
            state.recentlyRemoved.append(contentsOf: identifiers)
            let excess = state.recentlyRemoved.count - Self.recentlyRemovedLimit
            if excess > 0 { state.recentlyRemoved.removeFirst(excess) }
        }
    }
}

/// `clearAll()`: removes only delivered SallaPush notifications (and local copies), never other SDKs' ones, then hands
/// the identifiers it removed and the list it read to `completion`.
enum DeliveredNotificationCleaner {
    static func clearSallaPushNotifications(
        using center: NotificationCenterClient,
        then completion: (@Sendable (_ removed: [String], _ delivered: [DeliveredNotification]) -> Void)? = nil
    ) {
        center.deliveredNotifications { delivered in
            let identifiers = delivered
                .filter { PayloadParser.kind(of: $0.userInfo) != nil }
                .map(\.identifier)
            center.removeDeliveredNotifications(identifiers: identifiers)
            completion?(identifiers, delivered)
        }
    }
}

extension EngineEnvironment {
    /// The badge files of this app in `appGroup`, when the app can use that App Group.
    func badgeStore(appGroup: String?) -> BadgeStore? {
        guard let appGroup, let container = appGroupContainer(appGroup) else { return nil }
        return BadgeStore(container: container, appBundleIdentifier: bundle.bundleIdentifier)
    }
}

/// The current main engine drives the badge keeper: with its settings while it runs with consent, paused while consent
/// is withheld. A drain engine and one the app switched away from never touch it.
extension Engine {
    private func changeBadge(_ change: (BadgeKeeper) -> Void) {
        guard mode == .main, !isDraining else { return }
        host?.changeBadge(by: self, change)
    }

    /// The engine runs with consent: the keeper counts and clears with this app's settings.
    func configureBadge() {
        guard consentMode == .normal else { return }
        let policy = BadgeKeeper.Policy(autoClearBadge: config.autoClearBadge, autoUpdateBadge: config.autoUpdateBadge)
        let store = env.badgeStore(appGroup: config.appGroupIdentifier)
        changeBadge { $0.configure(policy: policy, store: store) }
    }

    /// Consent is withheld: the keeper neither counts nor clears; the files stay.
    func pauseBadge() {
        changeBadge { $0.pause() }
    }

    /// Consent is known to be withheld (withdrawn, or `consent.json` read and not given): the badge files go.
    func forgetBadge() {
        let store = env.badgeStore(appGroup: config.appGroupIdentifier)
        changeBadge { $0.forget(store: store) }
    }

    /// The runtime read `consent.json` and consent isn't given, after it paused this engine (or asked it to pause once
    /// its files are loaded): the badge files go.
    func forgetBadgeWhileConsentIsWithheld() {
        guard consentMode != .normal || consentAfterLoad != .normal else { return }
        forgetBadge()
    }

    func badgeAppBecameActive() {
        changeBadge { $0.appBecameActive() }
    }

    func badgeAppEnteredBackground() {
        changeBadge { $0.appEnteredBackground() }
    }
}

extension Runtime {
    /// Runs `change` on the badge keeper when `engine` is the current engine (running or paused), checked under the lock
    /// that every change of the keeper's settings takes: an engine the app switched away from changes nothing.
    func changeBadge(by engine: Engine, _ change: (BadgeKeeper) -> Void) {
        badgeLock.lock()
        defer { badgeLock.unlock() }
        if isCurrent(engine) { change(badge) }
    }

    /// Consent is known to be withheld while no engine runs (control queue): the badge files of `config`'s app go.
    func forgetBadge(of config: EngineConfig) {
        let store = engineEnvironment().badgeStore(appGroup: config.appGroupIdentifier)
        badgeLock.lock()
        defer { badgeLock.unlock() }
        badge.forget(store: store)
    }
}
