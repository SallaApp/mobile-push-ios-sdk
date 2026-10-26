import Foundation
import SallaPushCore
import UserNotifications

/// A delivered notification, as `clearAll()` needs it.
struct DeliveredNotification: @unchecked Sendable {
    let identifier: String
    let userInfo: [AnyHashable: Any]
}

/// The local copy that `display()` posts.
struct LocalNotificationRequest: @unchecked Sendable {
    let identifier: String
    let title: String?
    let subtitle: String?
    let body: String?
    let sound: String?
    let badge: NSNumber?
    let threadId: String?
    let userInfo: [AnyHashable: Any]

    /// This request with `badge` instead of its own.
    func with(badge: NSNumber?) -> LocalNotificationRequest {
        LocalNotificationRequest(identifier: identifier, title: title, subtitle: subtitle, body: body, sound: sound,
                                 badge: badge, threadId: threadId, userInfo: userInfo)
    }
}

/// Every `UNUserNotificationCenter` call the SDK makes. Injected so tests run without a notification center.
protocol NotificationCenterClient: AnyObject, Sendable {
    func authorizationStatus(_ completion: @escaping @Sendable (PermissionStatus) -> Void)
    func requestAuthorization(provisional: Bool, _ completion: @escaping @Sendable (Bool) -> Void)
    func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void)
    func removeDeliveredNotifications(identifiers: [String])
    func add(_ request: LocalNotificationRequest, _ completion: @escaping @Sendable (String?) -> Void)
    /// iOS 16+: sets the app icon badge to `count`; returns false where unavailable (iOS 15).
    func setBadgeCount(_ count: Int) -> Bool
    /// Whether the app set a `UNUserNotificationCenter` delegate (read on main).
    func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void)
}

/// Process facts that decide whether system notification APIs may be touched at all.
enum PlatformGuard {
    /// `UNUserNotificationCenter.current()` raises an exception outside an app or app-extension bundle
    /// (test runners, command-line tools), so it is used only inside one.
    static var canUseUserNotifications: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let pathExtension = Bundle.main.bundleURL.pathExtension
        return pathExtension == "app" || pathExtension == "appex"
    }
}

/// The `UNUserNotificationCenter` calls behind `SystemNotificationCenterClient`, as a seam: the live one is the system's,
/// and tests answer its completions twice to prove the client's `Once` guards.
protocol UserNotificationCenterBackend: AnyObject, Sendable {
    func authorizationStatus(_ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void)
    func requestAuthorization(options: UNAuthorizationOptions, _ completion: @escaping @Sendable (Bool) -> Void)
    func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void)
    func removeDeliveredNotifications(identifiers: [String])
    func add(_ request: UNNotificationRequest, _ completion: @escaping @Sendable (Error?) -> Void)
    /// iOS 16+: sets the app icon badge to `count`; returns false where unavailable (iOS 15).
    func setBadgeCount(_ count: Int) -> Bool
    /// Whether the app set a delegate, read on main.
    func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void)
}

/// `UNUserNotificationCenter.current()`.
final class SystemUserNotificationCenter: UserNotificationCenterBackend, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func authorizationStatus(_ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in completion(settings.authorizationStatus) }
    }

    func requestAuthorization(options: UNAuthorizationOptions, _ completion: @escaping @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: options) { granted, _ in completion(granted) }
    }

    func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void) {
        center.getDeliveredNotifications { notifications in
            completion(notifications.map {
                DeliveredNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
            })
        }
    }

    func removeDeliveredNotifications(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest, _ completion: @escaping @Sendable (Error?) -> Void) {
        center.add(request) { error in completion(error) }
    }

    func setBadgeCount(_ count: Int) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            center.setBadgeCount(count, withCompletionHandler: nil)
            return true
        }
        return false
    }

    func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void) {
        let center = UncheckedSendable(center)
        DispatchQueue.main.async {
            completion(center.value.delegate != nil)
        }
    }
}

/// The real notification center. Every system completion goes through `Once`: a completion the system
/// calls again is ignored, with DEBUG `api.callback_repeated` once per call site.
final class SystemNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    /// The system's notification center, only inside an app or app-extension bundle (`PlatformGuard`).
    static let systemBackend: @Sendable () -> UserNotificationCenterBackend? = {
        PlatformGuard.canUseUserNotifications ? SystemUserNotificationCenter(center: UNUserNotificationCenter.current()) : nil
    }

    private let backend: @Sendable () -> UserNotificationCenterBackend?
    private let logger: SDKLogger

    /// - Parameter backend: the center to call, resolved for each call; nil outside an app bundle.
    init(logger: SDKLogger,
         backend: @escaping @Sendable () -> UserNotificationCenterBackend? = SystemNotificationCenterClient.systemBackend) {
        self.logger = logger
        self.backend = backend
    }

    /// A once-guard for one system completion: true for its first call; a later call is logged once per call site.
    private func firstCall(of once: Once, _ completion: String) -> Bool {
        if once.claim() { return true }
        logger.logOnce(.apiCallbackRepeated, key: "callback_repeated.\(completion)",
                       "The system called the \(completion) completion more than once; extra calls ignored.")
        return false
    }

    func authorizationStatus(_ completion: @escaping @Sendable (PermissionStatus) -> Void) {
        guard let center = backend() else {
            completion(.notDetermined)
            return
        }
        let once = Once()
        center.authorizationStatus { [self] status in
            guard firstCall(of: once, "getNotificationSettings") else { return }
            completion(Self.status(status))
        }
    }

    func requestAuthorization(provisional: Bool, _ completion: @escaping @Sendable (Bool) -> Void) {
        guard let center = backend() else {
            completion(false)
            return
        }
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional { options.insert(.provisional) }
        let once = Once()
        center.requestAuthorization(options: options) { [self] granted in
            guard firstCall(of: once, "requestAuthorization") else { return }
            completion(granted)
        }
    }

    func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void) {
        guard let center = backend() else {
            completion([])
            return
        }
        let once = Once()
        center.deliveredNotifications { [self] notifications in
            guard firstCall(of: once, "getDeliveredNotifications") else { return }
            completion(notifications)
        }
    }

    func removeDeliveredNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        backend()?.removeDeliveredNotifications(identifiers: identifiers)
    }

    func add(_ request: LocalNotificationRequest, _ completion: @escaping @Sendable (String?) -> Void) {
        guard let center = backend() else {
            completion("notification center unavailable")
            return
        }
        let content = UNMutableNotificationContent()
        if let title = request.title { content.title = title }
        if let subtitle = request.subtitle { content.subtitle = subtitle }
        if let body = request.body { content.body = body }
        if let sound = request.sound, !sound.isEmpty {
            content.sound = sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
        }
        content.badge = request.badge
        if let threadId = request.threadId { content.threadIdentifier = threadId }
        content.userInfo = request.userInfo
        let notificationRequest = UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
        let once = Once()
        center.add(notificationRequest) { [self] error in
            guard firstCall(of: once, "add") else { return }
            completion(error.map(LogSanitizer.describe))
        }
    }

    func setBadgeCount(_ count: Int) -> Bool {
        guard let center = backend() else { return true }
        return center.setBadgeCount(count)
    }

    func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let center = backend() else {
            completion(true)
            return
        }
        center.hasDelegate(completion)
    }

    static func status(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional: return .provisional
        case .notDetermined: return .notDetermined
        #if os(iOS)
        case .ephemeral: return .ephemeral
        #endif
        @unknown default: return .notDetermined
        }
    }
}

extension PermissionStatus {
    /// The matching system value.
    var authorizationStatus: UNAuthorizationStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral:
            #if os(iOS)
            return .ephemeral
            #else
            return .authorized
            #endif
        }
    }
}
