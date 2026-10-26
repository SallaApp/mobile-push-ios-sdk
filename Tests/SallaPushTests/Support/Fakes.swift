import Foundation
@testable import SallaPush
@testable import SallaPushCore

/// Time under test control.
final class FakeClock: Clock, @unchecked Sendable {
    private let value: Locked<Double>

    init(start: Double = 1_790_000_000) {
        value = Locked(start)
    }

    func now() -> Double { value.current }

    func set(_ time: Double) { value.set(time) }
}

/// Collects scheduled work items; tests fire them by advancing time. No real sleeps.
final class ManualScheduler: Scheduler, @unchecked Sendable {
    private struct Item {
        let due: Double
        let order: Int
        let queue: DispatchQueue
        let item: DispatchWorkItem
    }

    private let clock: FakeClock
    private let items = Locked<[Item]>([])
    private let counter = Locked(0)

    init(clock: FakeClock) {
        self.clock = clock
    }

    /// How many work items were scheduled so far (each one lives in libdispatch until its deadline).
    var scheduledCount: Int { counter.current }

    func schedule(after seconds: Double, on queue: DispatchQueue, _ item: DispatchWorkItem) {
        let order = counter.withLock { value -> Int in
            value += 1
            return value
        }
        let due = clock.now() + seconds
        items.withLock { $0.append(Item(due: due, order: order, queue: queue, item: item)) }
    }

    /// The earliest due time of a live item.
    var nextDue: Double? {
        items.withLock { items in
            items.removeAll { $0.item.isCancelled }
            return items.map(\.due).min()
        }
    }

    /// Dispatches every live item due by now, in due order. Returns how many fired.
    @discardableResult
    func fireDue() -> Int {
        let now = clock.now()
        let due = items.withLock { items -> [Item] in
            let ready = items.filter { $0.due <= now && !$0.item.isCancelled }
            items.removeAll { ($0.due <= now) || $0.item.isCancelled }
            return ready.sorted { ($0.due, $0.order) < ($1.due, $1.order) }
        }
        for item in due {
            item.queue.async(execute: item.item)
        }
        return due.count
    }
}

/// An in-memory Keychain with scriptable statuses. It holds one item per service and account, in the access group it
/// was added to: a query that names an access group matches the item only in that group, and one that names none
/// matches it in any group, as the Keychain matches every group the app belongs to.
final class InMemoryKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// The attributes each item was added with (its access group and accessibility among them), as updates left them.
    private var itemAttributes: [String: [String: Any]] = [:]
    private var deleteQuery: [String: Any]?
    /// A status forced on every read (nil: behave normally).
    var forcedReadStatus: OSStatus?
    /// A status forced on every add (nil: behave normally).
    var forcedAddStatus: OSStatus?
    /// A status forced on every delete (nil: behave normally).
    var forcedDeleteStatus: OSStatus?
    /// Runs as an add or a delete starts, outside the lock, with the operation and the item's service: a test pauses a
    /// write there, or notes that one started.
    let beforeWrite = Locked<(@Sendable (_ operation: String, _ service: String) -> Void)?>(nil)
    private(set) var readCount = 0
    private(set) var readsOnMain = 0
    private(set) var writeCount = 0

    private func account(_ query: [String: Any]) -> String {
        (query[kSecAttrService as String] as? String ?? "") + "|" + (query[kSecAttrAccount as String] as? String ?? "")
    }

    /// The key of the item `query` matches, if any. Called under the lock.
    private func match(_ query: [String: Any]) -> String? {
        let key = account(query)
        guard items[key] != nil else { return nil }
        guard let group = query[kSecAttrAccessGroup as String] as? String else { return key }
        return itemAttributes[key]?[kSecAttrAccessGroup as String] as? String == group ? key : nil
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if Thread.isMainThread { readsOnMain += 1 }
        if let forcedReadStatus { return (forcedReadStatus, nil) }
        guard let key = match(query), let data = items[key] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        beforeWrite.current?("add", attributes[kSecAttrService as String] as? String ?? "")
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        if let forcedAddStatus { return forcedAddStatus }
        let key = account(attributes)
        if items[key] != nil { return errSecDuplicateItem }
        items[key] = attributes[kSecValueData as String] as? Data
        itemAttributes[key] = attributes
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        guard let key = match(query) else { return errSecItemNotFound }
        items[key] = attributes[kSecValueData as String] as? Data
        itemAttributes[key]?.merge(attributes) { _, new in new }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        beforeWrite.current?("delete", query[kSecAttrService as String] as? String ?? "")
        lock.lock()
        defer { lock.unlock() }
        deleteQuery = query
        if let forcedDeleteStatus { return forcedDeleteStatus }
        guard let key = match(query) else { return errSecItemNotFound }
        items.removeValue(forKey: key)
        itemAttributes.removeValue(forKey: key)
        return errSecSuccess
    }

    /// The attributes of the item of `service` and `account` (its access group, accessibility and data among them),
    /// or nil when there is none.
    func attributes(service: String, account: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return itemAttributes[service + "|" + account]
    }

    /// The query of the last delete, whatever it answered.
    var lastDeleteQuery: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return deleteQuery
    }

    /// Every stored value, for secret-leak checks.
    var allValues: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values)
    }

    func value(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.key.hasSuffix("|" + account) }?.value
    }

    func removeAll(matching suffix: String) {
        lock.lock()
        defer { lock.unlock() }
        items = items.filter { !$0.key.hasSuffix(suffix) }
        itemAttributes = itemAttributes.filter { !$0.key.hasSuffix(suffix) }
    }
}

/// A notification center that never touches the system. By default it answers synchronously; with `callbackQueue`
/// set it answers asynchronously on that queue, as the system does on its own queues.
final class FakeNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    /// Where completions are delivered; nil answers synchronously on the calling thread.
    let callbackQueue = Locked<DispatchQueue?>(nil)

    private let lock = NSLock()
    private var _status: PermissionStatus = .authorized
    private var _readCount = 0
    private var _readsOnMain = 0
    private var _requests: [Bool] = []
    private var _delivered: [DeliveredNotification] = []
    private var _removed: [[String]] = []
    private var _added: [LocalNotificationRequest] = []
    private var _badgeCounts: [Int] = []
    var grantOnRequest = true
    var addError: String?
    var supportsBadgeCount = true
    var hasDelegateValue = true

    var status: PermissionStatus {
        get { lock.guarded { _status } }
        set { lock.guarded { _status = newValue } }
    }

    var readCount: Int { lock.guarded { _readCount } }
    var readsOnMain: Int { lock.guarded { _readsOnMain } }
    var authorizationRequests: [Bool] { lock.guarded { _requests } }
    var removed: [[String]] { lock.guarded { _removed } }
    var added: [LocalNotificationRequest] { lock.guarded { _added } }
    /// Every count `setBadgeCount` set (iOS 16 and later), in order.
    var badgeCounts: [Int] { lock.guarded { _badgeCounts } }
    /// How many times `setBadgeCount` set 0.
    var badgeResets: Int { badgeCounts.filter { $0 == 0 }.count }

    func deliver(_ notifications: [DeliveredNotification]) {
        lock.guarded { _delivered = notifications }
    }

    private func answer(_ body: @escaping @Sendable () -> Void) {
        if let queue = callbackQueue.current {
            queue.async(execute: body)
        } else {
            body()
        }
    }

    func authorizationStatus(_ completion: @escaping @Sendable (PermissionStatus) -> Void) {
        let status = lock.guarded { () -> PermissionStatus in
            _readCount += 1
            if Thread.isMainThread { _readsOnMain += 1 }
            return _status
        }
        answer { completion(status) }
    }

    func requestAuthorization(provisional: Bool, _ completion: @escaping @Sendable (Bool) -> Void) {
        let granted = lock.guarded { () -> Bool in
            _requests.append(provisional)
            if grantOnRequest {
                _status = provisional ? .provisional : .authorized
            } else {
                _status = .denied
            }
            return grantOnRequest
        }
        answer { completion(granted) }
    }

    func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void) {
        let delivered = lock.guarded { _delivered }
        answer { completion(delivered) }
    }

    func removeDeliveredNotifications(identifiers: [String]) {
        lock.guarded { _removed.append(identifiers) }
    }

    func add(_ request: LocalNotificationRequest, _ completion: @escaping @Sendable (String?) -> Void) {
        let error = lock.guarded { () -> String? in
            _added.append(request)
            return addError
        }
        answer { completion(error) }
    }

    func setBadgeCount(_ count: Int) -> Bool {
        lock.guarded {
            if supportsBadgeCount { _badgeCounts.append(count) }
            return supportsBadgeCount
        }
    }

    func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void) {
        let value = hasDelegateValue
        if callbackQueue.current != nil {
            DispatchQueue.main.async { completion(value) }
        } else {
            completion(value)
        }
    }
}

/// Records every application call and the thread it came from. With `callbacksOnMain` set, completions and the
/// expiration handler arrive asynchronously on main, as UIKit's do.
final class FakeApplication: ApplicationClient, @unchecked Sendable {
    /// Whether callbacks are delivered asynchronously on main instead of synchronously.
    let callbacksOnMain = Locked(false)
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _state: AppState = .active
    private var _nextTask = 0
    private var _expirations: [Int: @Sendable () -> Void] = [:]
    private var _ended: [Int] = []
    private var _begun: [Int] = []
    private var _opened: [URL] = []
    private var _iconBadges: [Int] = []

    var state: AppState {
        get { lock.guarded { _state } }
        set { lock.guarded { _state = newValue } }
    }

    var calls: [String] { lock.guarded { _calls } }
    var endedTasks: [Int] { lock.guarded { _ended } }
    var begunTasks: [Int] { lock.guarded { _begun } }
    var openedURLs: [URL] { lock.guarded { _opened } }
    /// Every number `setIconBadge` set (iOS 15), in order.
    var iconBadges: [Int] { lock.guarded { _iconBadges } }

    private func record(_ name: String) {
        lock.guarded { _calls.append(name) }
    }

    func registerForRemoteNotifications() { record("registerForRemoteNotifications") }

    private func callBack(_ body: @escaping @Sendable () -> Void) {
        if callbacksOnMain.current {
            DispatchQueue.main.async(execute: body)
        } else {
            body()
        }
    }

    func applicationState(_ completion: @escaping @Sendable (AppState) -> Void) {
        record("applicationState")
        let current = state
        callBack { completion(current) }
    }

    func setIconBadge(_ count: Int) {
        lock.guarded {
            _iconBadges.append(count)
            _calls.append("setIconBadge:\(count)")
        }
    }

    func open(_ url: URL) {
        record("open")
        lock.guarded { _opened.append(url) }
    }

    func openNotificationSettings() { record("openNotificationSettings") }

    func beginBackgroundTask(name: String, expiration: @escaping @Sendable () -> Void,
                             started: @escaping @Sendable (Int?) -> Void) {
        let identifier = lock.guarded { () -> Int in
            _nextTask += 1
            _expirations[_nextTask] = expiration
            _begun.append(_nextTask)
            _calls.append("beginBackgroundTask:\(name)")
            return _nextTask
        }
        callBack { started(identifier) }
    }

    func endBackgroundTask(_ identifier: Int) {
        lock.guarded {
            _ended.append(identifier)
            _calls.append("endBackgroundTask")
        }
    }

    /// Simulates the system expiring a background task: the client ends it, then runs the handler.
    func expire(_ identifier: Int) {
        let expiration = lock.guarded { () -> (@Sendable () -> Void)? in
            _ended.append(identifier)
            return _expirations.removeValue(forKey: identifier)
        }
        guard let expiration else { return }
        callBack(expiration)
    }
}

/// Lifecycle events sent by the test.
final class FakeLifecycle: LifecycleSource, @unchecked Sendable {
    private let handlers = Locked<[Int: @Sendable (LifecycleEvent) -> Void]>([:])
    private let counter = Locked(0)

    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) -> LifecycleSubscription {
        let token = counter.withLock { value -> Int in
            value += 1
            return value
        }
        handlers.withLock { $0[token] = handler }
        return Subscription { [weak self] in self?.handlers.withLock { _ = $0.removeValue(forKey: token) } }
    }

    var observerCount: Int { handlers.current.count }

    func send(_ event: LifecycleEvent) {
        for handler in handlers.current.values { handler(event) }
    }

    private final class Subscription: LifecycleSubscription, @unchecked Sendable {
        private let action: Locked<(@Sendable () -> Void)?>

        init(_ action: @escaping @Sendable () -> Void) {
            self.action = Locked(action)
        }

        func cancel() {
            let pending = action.withLock { value -> (@Sendable () -> Void)? in
                defer { value = nil }
                return value
            }
            pending?()
        }
    }
}

/// Network monitors under test control.
final class FakeReachability: @unchecked Sendable {
    final class Monitor: ReachabilityMonitor, @unchecked Sendable {
        private let restored = Locked<(queue: DispatchQueue, handler: @Sendable () -> Void)?>(nil)
        let cancelled = Locked(false)

        func start(on queue: DispatchQueue, onRestored: @escaping @Sendable () -> Void) {
            restored.set((queue, onRestored))
        }

        func cancel() {
            cancelled.set(true)
            restored.set(nil)
        }

        func restore() {
            guard let target = restored.current else { return }
            target.queue.async { target.handler() }
        }
    }

    let monitors = Locked<[Monitor]>([])

    func make() -> ReachabilityMonitor {
        let monitor = Monitor()
        monitors.withLock { $0.append(monitor) }
        return monitor
    }

    var activeCount: Int { monitors.current.filter { !$0.cancelled.current }.count }

    func restoreAll() {
        for monitor in monitors.current where !monitor.cancelled.current { monitor.restore() }
    }
}

/// Bundle facts that count reads and their threads.
final class FakeBundle: BundleInfoSource, @unchecked Sendable {
    private let lock = NSLock()
    private var info: [String: Any]
    private var _reads = 0
    private var _readsOnMain = 0
    /// Runs as `bundleIdentifier` is read, outside the lock: only the device credentials shared with the extension read
    /// it, as the engine or the runtime starts to change them, so a test pauses one there, or notes that it started.
    let onBundleIdentifierRead = Locked<(@Sendable () -> Void)?>(nil)
    var bundleIdentifier: String? {
        onBundleIdentifierRead.current?()
        return lock.guarded { countRead(); return "com.salla.test" }
    }
    var shortVersion: String? { lock.guarded { countRead(); return info["CFBundleShortVersionString"] as? String } }

    init(info: [String: String] = ["CFBundleShortVersionString": "5.0.38"]) {
        self.info = info
    }

    var readsOnMain: Int { lock.guarded { _readsOnMain } }

    func set(_ key: String, _ value: String?) {
        lock.guarded { info[key] = value }
    }

    /// Sets a value of any Info.plist type, such as a Boolean or a number.
    func setObject(_ key: String, _ value: Any?) {
        lock.guarded { info[key] = value }
    }

    func string(forInfoKey key: String) -> String? {
        lock.guarded {
            countRead()
            return info[key] as? String
        }
    }

    func isOn(infoKey key: String) -> Bool {
        lock.guarded {
            countRead()
            return InfoPlistSwitch.isOn(info[key])
        }
    }

    private func countRead() {
        _reads += 1
        if Thread.isMainThread { _readsOnMain += 1 }
    }
}

/// Device facts of a test phone.
final class FakeDeviceFacts: DeviceFactsSource, @unchecked Sendable {
    let language = Locked<String?>("ar")
    let zone = Locked("Asia/Riyadh")

    func osVersion() -> String { "18.0.0" }
    func deviceModel() -> String { "iPhone15,2" }
    func preferredLanguage() -> String? { language.current }
    func timeZone() -> String { zone.current }
}

/// Every log entry of a logger, captured synchronously, and every line it wrote to the console.
final class LogCapture: @unchecked Sendable {
    private let entries = Locked<[SallaPushLogEntry]>([])
    private let lines = Locked<[String]>([])
    let logger: SDKLogger
    /// Where the log handler runs; `handlerQueue.sync {}` waits for it.
    let handlerQueue = DispatchQueue(label: "test.log.handler")

    init(keepsEarlyEntries: Bool = false) {
        let entries = self.entries
        let lines = self.lines
        logger = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, line in lines.withLock { $0.append(line) } },
                           handlerQueue: handlerQueue, keepsEarlyEntries: keepsEarlyEntries)
        logger.setTap { entry in entries.withLock { $0.append(entry) } }
    }

    var all: [SallaPushLogEntry] { entries.current }
    /// The console lines, at the console level (`.warn` unless a test sets another).
    var console: [String] { lines.current }
    var codes: [String] { all.map(\.code) }

    func count(_ code: String) -> Int {
        all.filter { $0.code == code }.count
    }

    func contains(_ code: String) -> Bool {
        all.contains { $0.code == code }
    }

    func clear() {
        entries.set([])
        lines.set([])
    }
}

extension NSLock {
    func guarded<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
