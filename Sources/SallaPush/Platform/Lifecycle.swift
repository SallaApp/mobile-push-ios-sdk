import Foundation
import SallaPushCore
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// App and system events the engine reacts to.
enum LifecycleEvent: Sendable, Equatable {
    case didBecomeActive
    case willEnterForeground
    case didEnterBackground
    case protectedDataAvailable
    case timeZoneChanged
    case localeChanged
}

/// A started observation; `cancel()` removes every observer it added.
protocol LifecycleSubscription: AnyObject, Sendable {
    func cancel()
}

/// Delivers lifecycle events. Injected so tests trigger them by hand.
protocol LifecycleSource: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) -> LifecycleSubscription
}

/// Observes `NotificationCenter.default`.
final class SystemLifecycleSource: LifecycleSource, @unchecked Sendable {
    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) -> LifecycleSubscription {
        var names: [(Notification.Name, LifecycleEvent)] = [
            (.NSSystemTimeZoneDidChange, .timeZoneChanged),
            (NSLocale.currentLocaleDidChangeNotification, .localeChanged),
        ]
        #if canImport(UIKit) && os(iOS)
        names += [
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.protectedDataDidBecomeAvailableNotification, .protectedDataAvailable),
        ]
        #endif
        let center = NotificationCenter.default
        let tokens = names.map { name, event in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in handler(event) }
        }
        return SystemLifecycleSubscription(tokens: tokens)
    }
}

private final class SystemLifecycleSubscription: LifecycleSubscription, @unchecked Sendable {
    private let tokens: Locked<[NSObjectProtocol]>

    init(tokens: [NSObjectProtocol]) {
        self.tokens = Locked(tokens)
    }

    func cancel() {
        let removed = tokens.withLock { current -> [NSObjectProtocol] in
            defer { current = [] }
            return current
        }
        for token in removed {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
