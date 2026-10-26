import Foundation
import SallaPushCore
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// The application state the engine caches from lifecycle notifications.
enum AppState: Sendable, Equatable {
    case active, inactive, background
}

/// Every `UIApplication` call the SDK makes. The live client hops to main for each UIKit call, except the
/// thread-safe background-task calls. Injected so tests record calls and their threads.
protocol ApplicationClient: AnyObject, Sendable {
    func registerForRemoteNotifications()
    func applicationState(_ completion: @escaping @Sendable (AppState) -> Void)
    /// iOS 15: sets the app icon badge number to `count` (on main); a 0 only when the number is above 0, since a 0 also
    /// removes the app's delivered notifications.
    func setIconBadge(_ count: Int)
    func open(_ url: URL)
    func openNotificationSettings()
    /// Begins a background task on main; `started` receives its identifier, or nil when none could start.
    /// When time runs out, the task is ended before `expiration` runs.
    func beginBackgroundTask(name: String, expiration: @escaping @Sendable () -> Void,
                             started: @escaping @Sendable (Int?) -> Void)
    func endBackgroundTask(_ identifier: Int)
}

/// The single place that may assume main-actor isolation, and only after checking the thread.
enum MainThread {
    /// Runs `body` synchronously when called on the main thread and returns true; returns false otherwise.
    @discardableResult
    static func run(_ body: @MainActor @Sendable () -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        MainActor.assumeIsolated { body() }
        return true
    }
}

#if canImport(UIKit) && os(iOS)
/// The real application. Inert outside an app bundle (test runners).
@available(iOSApplicationExtension, unavailable)
final class SystemApplicationClient: ApplicationClient, @unchecked Sendable {
    private var isApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func registerForRemoteNotifications() {
        guard isApp else { return }
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func applicationState(_ completion: @escaping @Sendable (AppState) -> Void) {
        guard isApp else {
            completion(.active)
            return
        }
        DispatchQueue.main.async {
            switch UIApplication.shared.applicationState {
            case .active: completion(.active)
            case .inactive: completion(.inactive)
            case .background: completion(.background)
            @unknown default: completion(.active)
            }
        }
    }

    func setIconBadge(_ count: Int) {
        guard isApp else { return }
        DispatchQueue.main.async {
            let application = UIApplication.shared
            if count > 0 || application.applicationIconBadgeNumber > 0 {
                application.applicationIconBadgeNumber = count
            }
        }
    }

    func open(_ url: URL) {
        guard isApp else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func openNotificationSettings() {
        guard isApp else { return }
        DispatchQueue.main.async {
            let address: String
            if #available(iOS 16.0, *) {
                address = UIApplication.openNotificationSettingsURLString
            } else {
                address = UIApplication.openSettingsURLString
            }
            guard let url = URL(string: address) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func beginBackgroundTask(name: String, expiration: @escaping @Sendable () -> Void,
                             started: @escaping @Sendable (Int?) -> Void) {
        guard isApp else {
            started(nil)
            return
        }
        DispatchQueue.main.async {
            let pending = Locked<Int?>(nil)
            let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                // Ended synchronously, before the handler returns, so the app is never held past its time.
                if let raw = pending.withLock({ value -> Int? in defer { value = nil }; return value }) {
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
                }
                expiration()
            }
            guard identifier != .invalid else {
                started(nil)
                return
            }
            pending.set(identifier.rawValue)
            started(identifier.rawValue)
        }
    }

    func endBackgroundTask(_ identifier: Int) {
        guard isApp else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
        }
    }
}
#endif

/// The application client of platforms without UIKit (macOS test runs): always active, no background tasks.
final class InertApplicationClient: ApplicationClient, @unchecked Sendable {
    func registerForRemoteNotifications() {}
    func applicationState(_ completion: @escaping @Sendable (AppState) -> Void) { completion(.active) }
    func setIconBadge(_ count: Int) {}
    func open(_ url: URL) {}
    func openNotificationSettings() {}
    func beginBackgroundTask(name: String, expiration: @escaping @Sendable () -> Void,
                             started: @escaping @Sendable (Int?) -> Void) {
        started(nil)
    }
    func endBackgroundTask(_ identifier: Int) {}
}
