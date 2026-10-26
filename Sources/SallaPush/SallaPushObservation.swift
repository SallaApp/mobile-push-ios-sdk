import Foundation
import SallaPushCore

/// A closure observer's registration. Keep it: the observer lives until `cancel()` or until this object is
/// deallocated (like `NSKeyValueObservation`).
public final class SallaPushObservation: NSObject, @unchecked Sendable {
    private let action: Locked<(@Sendable () -> Void)?>

    init(cancel: @escaping @Sendable () -> Void) {
        action = Locked(cancel)
        super.init()
    }

    /// Stops the observer. Calling it again does nothing.
    public func cancel() {
        let pending = action.exchange(nil)
        pending?()
    }

    deinit {
        cancel()
    }
}

/// A weak reference that can cross queues.
struct WeakReference: @unchecked Sendable {
    weak var object: AnyObject?
}

/// Weakly held protocol observers.
///
/// Inside a lock this list never loads a weak reference: a load retains the object, and if the app drops its last
/// reference meanwhile, releasing that load would run the object's deinit inside the lock, where a call back into
/// SallaPush (a `removeObserver(self)` in deinit, say) would take the same lock again. Entries are matched by identity
/// instead, and loaded only by `resolve(_:)`, outside every lock.
struct WeakObserverList: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        weak var object: AnyObject?
        let id: ObjectIdentifier
        let token: Int
    }

    private(set) var entries: [Entry] = []
    private var nextToken = 0

    /// Adds `object`, replacing an earlier registration of the same object.
    mutating func add(_ object: AnyObject) {
        let id = ObjectIdentifier(object)
        entries.removeAll { $0.id == id }
        nextToken += 1
        entries.append(Entry(object: object, id: id, token: nextToken))
    }

    /// Removes `object` (and any dead entry that had the same address).
    mutating func remove(_ object: AnyObject) {
        let id = ObjectIdentifier(object)
        entries.removeAll { $0.id == id }
    }

    /// Forgets the entries whose objects were found deallocated.
    mutating func prune(_ tokens: Set<Int>) {
        guard !tokens.isEmpty else { return }
        entries.removeAll { tokens.contains($0.token) }
    }

    /// Loads `entries` (outside any lock): the live observers of type `T`, and the tokens of deallocated ones.
    static func resolve<T>(_ entries: [Entry], as type: T.Type) -> (live: [T], dead: Set<Int>) {
        var live: [T] = []
        var dead: Set<Int> = []
        for entry in entries {
            if let observer = entry.object as? T {
                live.append(observer)
            } else {
                dead.insert(entry.token)
            }
        }
        return (live, dead)
    }
}

/// Registries of user, subscription and permission observers. Protocol observers are held weakly; closure
/// observers live until their `SallaPushObservation` is cancelled or released. Callbacks run on main, outside
/// any SDK lock, and no app value is ever released inside one.
final class ObserverHub: @unchecked Sendable {
    typealias UserHandler = @MainActor @Sendable (SallaPushUserChangedState) -> Void
    typealias LoginFailureHandler = @MainActor @Sendable (SallaPushLoginFailure) -> Void
    typealias SubscriptionHandler = @MainActor @Sendable (SallaPushSubscriptionChangedState) -> Void
    typealias PermissionHandler = @MainActor @Sendable (Bool) -> Void
    /// Builds a subscription replay at delivery time; nil when there is nothing to replay.
    typealias Replay = @Sendable () -> SallaPushSubscriptionChangedState?

    private struct Registry {
        var users = WeakObserverList()
        var userHandlers: [Int: UserHandler] = [:]
        var loginFailureHandlers: [Int: LoginFailureHandler] = [:]
        var subscriptions = WeakObserverList()
        var subscriptionHandlers: [Int: SubscriptionHandler] = [:]
        var permissions = WeakObserverList()
        var permissionHandlers: [Int: PermissionHandler] = [:]
        var nextToken = 0

        mutating func token() -> Int {
            nextToken += 1
            return nextToken
        }
    }

    private enum List {
        case users, subscriptions, permissions
    }

    private let registry = Locked(Registry())

    // MARK: - Shared plumbing

    /// The live observers of `list`, loaded outside the lock; deallocated ones are pruned.
    private func liveObservers<T>(_ list: List, as type: T.Type) -> [T] {
        let entries = registry.withLock { registry -> [WeakObserverList.Entry] in
            switch list {
            case .users: return registry.users.entries
            case .subscriptions: return registry.subscriptions.entries
            case .permissions: return registry.permissions.entries
            }
        }
        let resolved = WeakObserverList.resolve(entries, as: type)
        if !resolved.dead.isEmpty {
            registry.withLock { registry in
                switch list {
                case .users: registry.users.prune(resolved.dead)
                case .subscriptions: registry.subscriptions.prune(resolved.dead)
                case .permissions: registry.permissions.prune(resolved.dead)
                }
            }
        }
        return resolved.live
    }

    /// An observation whose cancel removes the handler under `token` and releases it after the lock.
    private func observation<Handler>(_ token: Int,
                                      _ remove: @escaping @Sendable (inout Registry, Int) -> Handler?) -> SallaPushObservation {
        SallaPushObservation { [weak self] in
            let removed = self?.registry.withLock { remove(&$0, token) }
            withExtendedLifetime(removed) {}
        }
    }

    // MARK: - User

    func addUserObserver(_ observer: SallaPushUserObserver) {
        registry.withLock { $0.users.add(observer) }
    }

    func removeUserObserver(_ observer: SallaPushUserObserver) {
        registry.withLock { $0.users.remove(observer) }
    }

    func addUserHandler(_ handler: @escaping UserHandler) -> SallaPushObservation {
        let token = registry.withLock { registry -> Int in
            let token = registry.token()
            registry.userHandlers[token] = handler
            return token
        }
        return observation(token) { registry, token in registry.userHandlers.removeValue(forKey: token) }
    }

    func addLoginFailureHandler(_ handler: @escaping LoginFailureHandler) -> SallaPushObservation {
        let token = registry.withLock { registry -> Int in
            let token = registry.token()
            registry.loginFailureHandlers[token] = handler
            return token
        }
        return observation(token) { registry, token in registry.loginFailureHandlers.removeValue(forKey: token) }
    }

    func notifyUserChanged(_ change: SallaPushUserChangedState) {
        let handlers = registry.withLock { registry in registry.userHandlers.sorted { $0.key < $1.key }.map(\.value) }
        let observers = UncheckedSendable(liveObservers(.users, as: SallaPushUserObserver.self))
        guard !observers.value.isEmpty || !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in observers.value { observer.onUserStateDidChange(state: change) }
            for handler in handlers { handler(change) }
        }
    }

    func notifyLoginFailure(_ failure: SallaPushLoginFailure) {
        let handlers = registry.withLock { registry in registry.loginFailureHandlers.sorted { $0.key < $1.key }.map(\.value) }
        let observers = UncheckedSendable(liveObservers(.users, as: SallaPushUserObserver.self))
        guard !observers.value.isEmpty || !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in observers.value { observer.onLoginFailure?(failure) }
            for handler in handlers { handler(failure) }
        }
    }

    // MARK: - Subscription

    /// Adds a protocol observer. When `replay` is given, it is evaluated on main when the replay is delivered, after
    /// this call returns, so the replay always carries the state current at delivery.
    func addSubscriptionObserver(_ observer: SallaPushSubscriptionObserver, replay: Replay?) {
        registry.withLock { $0.subscriptions.add(observer) }
        guard let replay else { return }
        let box = WeakReference(object: observer)
        DispatchQueue.main.async {
            guard let observer = box.object as? SallaPushSubscriptionObserver, let state = replay() else { return }
            observer.onPushSubscriptionDidChange(state: state)
        }
    }

    func removeSubscriptionObserver(_ observer: SallaPushSubscriptionObserver) {
        registry.withLock { $0.subscriptions.remove(observer) }
    }

    func addSubscriptionHandler(_ handler: @escaping SubscriptionHandler, replay: Replay?) -> SallaPushObservation {
        let token = registry.withLock { registry -> Int in
            let token = registry.token()
            registry.subscriptionHandlers[token] = handler
            return token
        }
        if let replay {
            DispatchQueue.main.async { [weak self] in
                let live = self?.registry.withLock { $0.subscriptionHandlers[token] != nil } ?? false
                guard live, let state = replay() else { return }
                handler(state)
            }
        }
        return observation(token) { registry, token in registry.subscriptionHandlers.removeValue(forKey: token) }
    }

    func notifySubscriptionChanged(_ change: SallaPushSubscriptionChangedState) {
        let handlers = registry.withLock { registry in registry.subscriptionHandlers.sorted { $0.key < $1.key }.map(\.value) }
        let observers = UncheckedSendable(liveObservers(.subscriptions, as: SallaPushSubscriptionObserver.self))
        guard !observers.value.isEmpty || !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in observers.value { observer.onPushSubscriptionDidChange(state: change) }
            for handler in handlers { handler(change) }
        }
    }

    // MARK: - Permission

    func addPermissionObserver(_ observer: SallaPushPermissionObserver) {
        registry.withLock { $0.permissions.add(observer) }
    }

    func removePermissionObserver(_ observer: SallaPushPermissionObserver) {
        registry.withLock { $0.permissions.remove(observer) }
    }

    func addPermissionHandler(_ handler: @escaping PermissionHandler) -> SallaPushObservation {
        let token = registry.withLock { registry -> Int in
            let token = registry.token()
            registry.permissionHandlers[token] = handler
            return token
        }
        return observation(token) { registry, token in registry.permissionHandlers.removeValue(forKey: token) }
    }

    func notifyPermissionChanged(_ granted: Bool) {
        let handlers = registry.withLock { registry in registry.permissionHandlers.sorted { $0.key < $1.key }.map(\.value) }
        let observers = UncheckedSendable(liveObservers(.permissions, as: SallaPushPermissionObserver.self))
        guard !observers.value.isEmpty || !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in observers.value { observer.onNotificationPermissionDidChange(granted) }
            for handler in handlers { handler(granted) }
        }
    }
}
