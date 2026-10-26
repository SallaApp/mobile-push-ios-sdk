import Foundation
import SallaPushCore
import UserNotifications

/// Notifications: permission, APNs token forwarding, delegate forwarding (no swizzling) and listeners.
@objc public final class SallaPushNotifications: NSObject {
    // Stateless, so one instance serves every thread.
    private static let instance = UncheckedSendable(SallaPushNotifications())
    static var shared: SallaPushNotifications { instance.value }
    private static let defaultDelegate = UncheckedSendable(SallaPushNotificationCenterDelegate())

    override init() {
        super.init()
    }

    // MARK: - Permission

    // The permission getters read the status SallaPush last read from the system. `initialize` reads it at once
    // (also while consent is pending) and SallaPush re-reads it on every activation, token delivery and permission
    // request, asynchronously: right after `initialize` returns, the first read may still be in progress.

    /// Whether notifications are authorized (authorized, provisional or ephemeral); false until the first read.
    @objc public var permission: Bool { Runtime.shared.snapshot.permission?.isGranted ?? false }

    /// The authorization status SallaPush last read; `.notDetermined` until the first read completes.
    @objc public var permissionStatus: UNAuthorizationStatus {
        (Runtime.shared.snapshot.permission ?? .notDetermined).authorizationStatus
    }

    /// Whether the system prompt can still be shown: the status was read and is not determined. False while the
    /// status is still unknown.
    @objc public var canRequestPermission: Bool {
        Runtime.shared.snapshot.permission == .notDetermined
    }

    /// Asks for alert, sound and badge permission. When it was denied before and `fallbackToSettings` is true,
    /// opens the app's notification settings instead. `completion` runs once, on main, after the permission getters
    /// were updated.
    @objc(requestPermissionWithFallbackToSettings:completion:)
    public func requestPermission(fallbackToSettings: Bool, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        Runtime.shared.requestPermission(fallbackToSettings: fallbackToSettings, provisional: false, completion: completion)
    }

    /// Asks for permission and returns whether it was granted.
    public func requestPermission(fallbackToSettings: Bool = false) async -> Bool {
        let logger = Runtime.shared.logger
        return await onceContinuation(onRepeat: {
            logger.log(.apiCallbackRepeated, "The permission request completed more than once; extra calls ignored.")
        }, { resume in
            Runtime.shared.requestPermission(fallbackToSettings: fallbackToSettings, provisional: false) { granted in
                resume(granted)
            }
        })
    }

    /// Asks for provisional authorization (quiet notifications without a prompt).
    @objc(registerForProvisionalAuthorizationWithCompletion:)
    public func registerForProvisionalAuthorization(completion: (@MainActor @Sendable (Bool) -> Void)?) {
        Runtime.shared.requestPermission(fallbackToSettings: false, provisional: true, completion: completion)
    }

    /// Re-reads the permission now, for apps that prompt in their own way.
    @objc public func refreshPermission() {
        Runtime.shared.submit(.refreshPermission)
    }

    /// Adds a permission observer (held weakly).
    @objc public func addPermissionObserver(_ observer: SallaPushPermissionObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "addPermissionObserver", "observer") else { return }
        runtime.observers.addPermissionObserver(observer)
    }

    /// Removes a permission observer.
    @objc public func removePermissionObserver(_ observer: SallaPushPermissionObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "removePermissionObserver", "observer") else { return }
        runtime.observers.removePermissionObserver(observer)
    }

    /// Observes permission changes with a closure on main; keep the returned observation.
    public func addPermissionObserver(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> SallaPushObservation {
        Runtime.shared.observers.addPermissionHandler(handler)
    }

    // MARK: - Remote registration and token forwarding

    /// Calls `UIApplication.registerForRemoteNotifications()` on main.
    @objc public func registerForRemoteNotifications() {
        Runtime.shared.environment.application.registerForRemoteNotifications()
    }

    /// Forward the APNs token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, and from any
    /// other SDK that receives it in your app's place. Safe to call any number of times; it re-reads the permission.
    @objc(didRegisterForRemoteNotificationsWithDeviceToken:)
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard let token = PushToken(deviceToken: deviceToken) else {
            Runtime.shared.logger.log(.tokenInvalid, "The push token passed to SallaPush is empty or malformed; ignored.")
            return
        }
        Runtime.shared.submit(.pushToken(token))
    }

    /// Forward `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    @objc(didFailToRegisterForRemoteNotificationsWithError:)
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(error, of: "didFailToRegisterForRemoteNotifications", "error") else { return }
        runtime.submit(.registrationFailed(LogSanitizer.describe(error)))
    }

    // MARK: - Delegate forwarding

    /// Forward `userNotificationCenter(_:willPresent:withCompletionHandler:)`. Returns the options for a SallaPush
    /// notification, or nil when it belongs to someone else. Never calls your completion handler. While
    /// `autoClearBadge` is on, the options leave out `.badge`, so the app icon doesn't change while the app is open.
    public func willPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions? {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(notification, of: "willPresent", "notification") else { return nil }
        return runtime.router.willPresent(userInfo: notification.request.content.userInfo,
                                          identifier: notification.request.identifier)
    }

    /// Objective-C form of `willPresent(_:)`: YES for a SallaPush notification, with `*presentationOptions` written;
    /// NO otherwise, with the pointer untouched. Swift code calls `willPresent(_:)`.
    @available(swift, obsoleted: 1)
    @objc(willPresentNotification:presentationOptions:)
    public func willPresent(_ notification: UNNotification,
                            presentationOptions: UnsafeMutablePointer<UNNotificationPresentationOptions>?) -> Bool {
        Self.write(willPresent(notification), into: presentationOptions)
    }

    /// Writes SallaPush's options through the Objective-C out pointer; leaves it untouched for other notifications.
    static func write(_ options: UNNotificationPresentationOptions?,
                      into pointer: UnsafeMutablePointer<UNNotificationPresentationOptions>?) -> Bool {
        guard let options else { return false }
        pointer?.pointee = options
        return true
    }

    /// Forward `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Returns true for a SallaPush
    /// notification (the open is recorded and the click delivered). Never calls your completion handler.
    @objc(didReceiveNotificationResponse:) @discardableResult
    public func didReceive(_ response: UNNotificationResponse) -> Bool {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(response, of: "didReceive", "response") else { return false }
        return runtime.router.didReceive(identifier: response.notification.request.identifier,
                                         actionIdentifier: response.actionIdentifier,
                                         userInfo: response.notification.request.content.userInfo)
    }

    /// Forward `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. Returns true for a SallaPush
    /// payload. Never calls the completion handler: always call it yourself.
    @objc(didReceiveRemoteNotification:) @discardableResult
    public func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        Runtime.shared.router.didReceiveRemoteNotification(userInfo: userInfo)
    }

    /// Whether `userInfo` is a SallaPush notification, in either payload format.
    @objc public func isSallaPushNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        PayloadParser.kind(of: userInfo) != nil
    }

    /// Parses a SallaPush notification; nil when it belongs to someone else.
    @objc public func parse(_ userInfo: [AnyHashable: Any]) -> SallaPushNotification? {
        PayloadParser.parse(userInfo, logger: Runtime.shared.logger)?.notification
    }

    /// A ready-made `UNUserNotificationCenterDelegate` for apps that have none. SallaPush never assigns it.
    @objc public var notificationCenterDelegate: SallaPushNotificationCenterDelegate { Self.defaultDelegate.value }

    // MARK: - Listeners

    /// Adds a click listener (held weakly). Taps that arrived before the first listener are delivered to it.
    @objc public func addClickListener(_ listener: SallaPushClickListener) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(listener, of: "addClickListener", "listener") else { return }
        runtime.router.addClickListener(listener)
    }

    /// Removes a click listener.
    @objc public func removeClickListener(_ listener: SallaPushClickListener) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(listener, of: "removeClickListener", "listener") else { return }
        runtime.router.removeClickListener(listener)
    }

    /// Observes clicks with a closure on main; keep the returned observation.
    public func addClickListener(_ handler: @escaping @MainActor @Sendable (SallaPushClickEvent) -> Void) -> SallaPushObservation {
        Runtime.shared.router.addClickHandler(handler)
    }

    /// Adds a foreground listener (held weakly), called synchronously on main before a SallaPush notification shows.
    @objc public func addForegroundLifecycleListener(_ listener: SallaPushForegroundLifecycleListener) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(listener, of: "addForegroundLifecycleListener", "listener") else { return }
        runtime.router.addForegroundListener(listener)
    }

    /// Removes a foreground listener.
    @objc public func removeForegroundLifecycleListener(_ listener: SallaPushForegroundLifecycleListener) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(listener, of: "removeForegroundLifecycleListener", "listener") else { return }
        runtime.router.removeForegroundListener(listener)
    }

    /// Observes foreground display with a closure, synchronously on main; keep the returned observation.
    public func addForegroundLifecycleListener(
        _ handler: @escaping @MainActor @Sendable (SallaPushWillDisplayEvent) -> Void
    ) -> SallaPushObservation {
        Runtime.shared.router.addForegroundHandler(handler)
    }

    /// Removes delivered SallaPush notifications only; other SDKs' notifications stay. While `autoUpdateBadge` is on, it
    /// also sets SallaPush's count and the app icon badge to 0; on iOS 15, where a badge set to 0 also removes the app's
    /// delivered notifications, the icon goes to 0 only when no other SDK's notification is delivered.
    @objc public func clearAll() {
        let runtime = Runtime.shared
        let badge = runtime.badge
        DeliveredNotificationCleaner.clearSallaPushNotifications(using: runtime.environment.notificationCenter) { removed, delivered in
            badge.clearedAll(removed: removed, delivered: delivered)
        }
    }
}

// MARK: - Router

/// Foreground presentation, clicks and `display()`. Works before `initialize`: events are buffered by the runtime.
final class NotificationRouter: @unchecked Sendable {
    typealias ClickHandler = @MainActor @Sendable (SallaPushClickEvent) -> Void
    typealias ForegroundHandler = @MainActor @Sendable (SallaPushWillDisplayEvent) -> Void

    static let clickDedupeCapacity = 50
    static let pendingClickLimit = 10
    static let pendingClickLifetime: Double = 300
    static let displayWindow: Double = 600
    static let displayRecordLimit = 20
    static let defaultOptions: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge]

    private struct DisplayRecord {
        let event: SallaPushWillDisplayEvent
        let request: LocalNotificationRequest
        let createdAt: Double
        /// Whether the listeners prevented the default display, fixed once they returned; nil while they run.
        var prevented: Bool?
        var used = false
    }

    private struct State {
        var clickKeys: [String] = []
        var pendingClicks: [(event: SallaPushClickEvent, at: Double)] = []
        var clickListeners = WeakObserverList()
        var clickHandlers: [Int: ClickHandler] = [:]
        var foregroundListeners = WeakObserverList()
        var foregroundHandlers: [Int: ForegroundHandler] = [:]
        var displays: [DisplayRecord] = []
        var nextToken = 0
    }

    weak var runtime: Runtime?
    private let logger: SDKLogger
    private let clock: Clock
    private let notificationCenter: NotificationCenterClient
    private let application: ApplicationClient
    private let state = Locked(State())

    init(logger: SDKLogger, clock: Clock, notificationCenter: NotificationCenterClient, application: ApplicationClient) {
        self.logger = logger
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.application = application
    }

    // MARK: - Forwarding

    /// The options for the SallaPush notification `userInfo` of request `identifier`, or nil for another SDK's.
    func willPresent(userInfo: [AnyHashable: Any], identifier: String? = nil) -> UNNotificationPresentationOptions? {
        guard let payload = PayloadParser.parse(userInfo, logger: logger) else {
            logger.log(.notifForeign, "Ignoring a notification from another SDK.")
            return nil
        }
        let shownOptions = runtime?.foregroundOptions ?? Self.defaultOptions
        if payload.isLocalCopy {
            // The copy display() posted: the listeners ran and `received` was recorded for the original, so showing
            // the copy is the notification's display (Android records `displayed` when display() shows it).
            record(payload, .displayed, now: clock.now())
            presented(identifier, shown: true)
            return shownOptions
        }
        let now = clock.now()
        record(payload, .received, now: now)
        if runtime?.snapshot.userOptedOut == true {
            logger.log(.notifSuppressed, "Notification not shown (opted out).")
            presented(identifier, shown: false)
            return []
        }
        var options = shownOptions
        if Thread.isMainThread {
            let event = SallaPushWillDisplayEvent(notification: payload.notification)
            let handlers = foregroundHandlers(remembering: event, payload: payload, now: now)
            let observers = UncheckedSendable(liveListeners(\.foregroundListeners, as: SallaPushForegroundLifecycleListener.self))
            let boxed = UncheckedSendable(event)
            MainThread.run {
                for listener in observers.value { listener.onWillDisplay(event: boxed.value) }
                for handler in handlers { handler(boxed.value) }
            }
            if decide(event) { options = [] }
        } else {
            logger.logOnce(.notifOffMainThread, key: "notif.off_main_thread",
                           "willPresent/didReceive was forwarded off the main thread; foreground listeners were skipped. "
                               + "Forward on the main thread.")
        }
        let shown = options.contains(.banner) || options.contains(.list)
        if shown {
            record(payload, .displayed, now: now)
        }
        presented(identifier, shown: shown)
        return options
    }

    /// Tells the badge keeper what `willPresent` answered for the notification of request `identifier`.
    private func presented(_ identifier: String?, shown: Bool) {
        guard let identifier else { return }
        runtime?.badge.presented(identifier: identifier, shown: shown)
    }

    func didReceive(identifier: String, actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = PayloadParser.parse(userInfo, logger: logger) else {
            logger.log(.notifForeign, "Ignoring a notification from another SDK.")
            return false
        }
        runtime?.badge.opened(identifier: identifier)
        let now = clock.now()
        let isDismiss = actionIdentifier == UNNotificationDismissActionIdentifier
        let isDefault = actionIdentifier == UNNotificationDefaultActionIdentifier
        let actionId: String? = isDefault || isDismiss ? nil : actionIdentifier
        record(payload, isDismiss ? .dismissed : .opened, actionId: actionId, now: now)
        guard !isDismiss else { return true }
        let key = identifier + "|" + actionIdentifier
        let isNew = state.withLock { state -> Bool in
            guard !state.clickKeys.contains(key) else { return false }
            state.clickKeys.append(key)
            if state.clickKeys.count > Self.clickDedupeCapacity { state.clickKeys.removeFirst() }
            return true
        }
        guard isNew else { return true }
        let event = SallaPushClickEvent(notification: payload.notification,
                                        result: SallaPushClickResult(actionId: actionId, url: payload.notification.launchURL))
        dispatchClick(event, now: now)
        if runtime?.openLaunchURLs == true, let text = payload.notification.launchURL,
           let url = URL(string: text), url.scheme?.lowercased() == "https" {
            application.open(url)
        }
        return true
    }

    func didReceiveRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = PayloadParser.parse(userInfo, logger: logger) else {
            logger.log(.notifForeign, "Ignoring a notification from another SDK.")
            return false
        }
        record(payload, .received, now: clock.now())
        return true
    }

    /// Records an event for a notification that has a valid message id. A `display()` copy records its display and its
    /// tap or dismissal, never a second `received`; the persisted (id, type) dedupe counts each once.
    private func record(_ payload: ParsedPayload, _ type: EventType, actionId: String? = nil, now: Double) {
        guard let messageId = payload.messageId, !(payload.isLocalCopy && type == .received) else { return }
        runtime?.submit(.events([EventRecord(messageId: messageId, type: type, at: now, actionId: actionId)]))
    }

    // MARK: - Clicks

    private func dispatchClick(_ event: SallaPushClickEvent, now: Double) {
        let observers = UncheckedSendable(liveListeners(\.clickListeners, as: SallaPushClickListener.self))
        let handlers: [ClickHandler]? = state.withLock { state in
            let handlers = state.clickHandlers.sorted { $0.key < $1.key }.map(\.value)
            if observers.value.isEmpty && handlers.isEmpty {
                state.pendingClicks.removeAll { now - $0.at > Self.pendingClickLifetime }
                state.pendingClicks.append((event, now))
                if state.pendingClicks.count > Self.pendingClickLimit { state.pendingClicks.removeFirst() }
                return nil
            }
            return handlers
        }
        guard let handlers else {
            logger.log(.notifClickQueued, "Click kept until a click listener is added.")
            return
        }
        deliver([event], observers: observers, handlers: handlers)
    }

    /// The live listeners of one list, loaded outside the lock; deallocated ones are pruned.
    private func liveListeners<T>(_ list: WritableKeyPath<State, WeakObserverList>, as type: T.Type) -> [T] {
        let entries = state.withLock { $0[keyPath: list].entries }
        let resolved = WeakObserverList.resolve(entries, as: type)
        if !resolved.dead.isEmpty {
            state.withLock { $0[keyPath: list].prune(resolved.dead) }
        }
        return resolved.live
    }

    /// An observation whose cancel removes the handler under `token` and releases it after the lock.
    private func observation<Handler>(_ token: Int,
                                      _ remove: @escaping @Sendable (inout State, Int) -> Handler?) -> SallaPushObservation {
        SallaPushObservation { [weak self] in
            let removed = self?.state.withLock { remove(&$0, token) }
            withExtendedLifetime(removed) {}
        }
    }

    private func deliver(_ events: [SallaPushClickEvent], observers: UncheckedSendable<[SallaPushClickListener]>,
                         handlers: [ClickHandler]) {
        let count = observers.value.count + handlers.count
        let boxed = UncheckedSendable(events)
        DispatchQueue.main.async {
            for event in boxed.value {
                for observer in observers.value { observer.onClick(event: event) }
                for handler in handlers { handler(event) }
            }
        }
        logger.log(.notifClickDelivered, "Click delivered to \(count) listener\(count == 1 ? "" : "s").",
                   metadata: [LogMetadataKey.count: String(count)])
    }

    /// Clicks kept for the first listener, emptied.
    private func takePendingClicks() -> [SallaPushClickEvent] {
        let now = clock.now()
        return state.withLock { state in
            let live = state.pendingClicks.filter { now - $0.at <= Self.pendingClickLifetime }.map(\.event)
            state.pendingClicks.removeAll()
            return live
        }
    }

    func addClickListener(_ listener: SallaPushClickListener) {
        state.withLock { $0.clickListeners.add(listener) }
        let pending = takePendingClicks()
        if !pending.isEmpty { deliver(pending, observers: UncheckedSendable([listener]), handlers: []) }
    }

    func removeClickListener(_ listener: SallaPushClickListener) {
        state.withLock { $0.clickListeners.remove(listener) }
    }

    func addClickHandler(_ handler: @escaping ClickHandler) -> SallaPushObservation {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            state.clickHandlers[state.nextToken] = handler
            return state.nextToken
        }
        let pending = takePendingClicks()
        if !pending.isEmpty { deliver(pending, observers: UncheckedSendable([]), handlers: [handler]) }
        return observation(token) { state, token in state.clickHandlers.removeValue(forKey: token) }
    }

    // MARK: - Foreground listeners

    /// Remembers `event` for `display()` and returns the closure listeners.
    private func foregroundHandlers(remembering event: SallaPushWillDisplayEvent, payload: ParsedPayload,
                                    now: Double) -> [ForegroundHandler] {
        let request = LocalNotification.request(for: payload)
        return state.withLock { state in
            state.displays.removeAll { now - $0.createdAt > Self.displayWindow }
            state.displays.append(DisplayRecord(event: event, request: request, createdAt: now))
            if state.displays.count > Self.displayRecordLimit { state.displays.removeFirst() }
            return state.foregroundHandlers.sorted { $0.key < $1.key }.map(\.value)
        }
    }

    func addForegroundListener(_ listener: SallaPushForegroundLifecycleListener) {
        state.withLock { $0.foregroundListeners.add(listener) }
    }

    func removeForegroundListener(_ listener: SallaPushForegroundLifecycleListener) {
        state.withLock { $0.foregroundListeners.remove(listener) }
    }

    func addForegroundHandler(_ handler: @escaping ForegroundHandler) -> SallaPushObservation {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            state.foregroundHandlers[state.nextToken] = handler
            return state.nextToken
        }
        return observation(token) { state, token in state.foregroundHandlers.removeValue(forKey: token) }
    }

    // MARK: - display()

    /// Why `display()` posts nothing.
    private enum DisplayRefusal: Error {
        case unknown, notPrevented, preventedTooLate, alreadyDisplayed
    }

    /// Fixes, once the listeners returned, whether they prevented the default display: `willPresent` answers with it,
    /// and a `preventDefault()` after that changes nothing (`display()` then says it came too late), so a notification
    /// is never shown twice (Android's `DisplayHandle.decide`).
    private func decide(_ event: SallaPushWillDisplayEvent) -> Bool {
        state.withLock { state in
            let prevented = event.isPrevented
            if let index = state.displays.firstIndex(where: { $0.event === event }) {
                state.displays[index].prevented = prevented
            }
            return prevented
        }
    }

    /// Posts the local copy of a foreground notification the listeners prevented, once, within 10 minutes. While the
    /// listeners run, a `display()` right after `preventDefault()` posts it; once they returned, only a notification
    /// they prevented by then is posted.
    func display(_ notification: SallaPushNotification) {
        let now = clock.now()
        let outcome: Result<LocalNotificationRequest, DisplayRefusal> = state.withLock { state in
            state.displays.removeAll { now - $0.createdAt > Self.displayWindow }
            guard let index = state.displays.firstIndex(where: { $0.event.notification === notification }) else {
                return .failure(.unknown)
            }
            let record = state.displays[index]
            let isPrevented = record.event.isPrevented
            if record.prevented == false { return .failure(isPrevented ? .preventedTooLate : .notPrevented) }
            guard isPrevented else { return .failure(.notPrevented) }
            guard !record.used else { return .failure(.alreadyDisplayed) }
            state.displays[index].used = true
            return .success(record.request)
        }
        switch outcome {
        case let .success(request):
            let logger = self.logger
            let notificationCenter = self.notificationCenter
            let post: @Sendable (LocalNotificationRequest) -> Void = { request in
                notificationCenter.add(request) { error in
                    if let error {
                        logger.log(.notifDisplayFailed, "Could not show the notification (\(error)).")
                    }
                }
            }
            if let badge = runtime?.badge { badge.localCopy(request, post: post) } else { post(request) }
        case .failure(.unknown):
            logger.log(.notifDisplayFailed,
                       "Could not show the notification (display() works only within 10 minutes of the foreground "
                           + "listener event, for a notification SallaPush presented in the foreground).")
        case .failure(.notPrevented):
            logger.log(.notifDisplayFailed,
                       "Could not show the notification (it was not prevented: call event.preventDefault() first).")
        case .failure(.preventedTooLate):
            logger.log(.notifDisplayFailed,
                       "Could not show the notification (it was prevented too late: willPresent had already answered to "
                           + "show it; call event.preventDefault() before the listener returns).")
        case .failure(.alreadyDisplayed):
            logger.log(.notifDisplayFailed, "Could not show the notification (display() was already called for it).")
        }
    }
}
