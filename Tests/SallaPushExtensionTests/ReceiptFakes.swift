import Foundation
import SallaPushCore
@testable import SallaPushExtension
import Security
import UserNotifications

/// The Keychain the extension reads the app's shared item from: one item per service, account and access group, as the
/// Keychain keeps them. A query that names a group matches only that group's item, and one that names none matches
/// every group's. A read status can be forced, and reads are counted.
final class ReceiptKeychain: KeychainAccess, @unchecked Sendable {
    private let items = Locked<[String: Data]>([:])
    private let reads = Locked(0)
    /// A status every read answers instead (nil: behave normally).
    let forcedReadStatus = Locked<OSStatus?>(nil)

    var readCount: Int { reads.current }

    /// The `<service>|<account>|` every key of `query`'s item starts with, and the group `query` names.
    private static func key(_ query: [String: Any]) -> (prefix: String, group: String?) {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return (service + "|" + account + "|", query[kSecAttrAccessGroup as String] as? String)
    }

    /// The keys of the items `query` matches.
    private static func matches(_ query: [String: Any], in items: [String: Data]) -> [String] {
        let (prefix, group) = key(query)
        guard let group else { return items.keys.filter { $0.hasPrefix(prefix) } }
        return items[prefix + group] == nil ? [] : [prefix + group]
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        reads.withLock { $0 += 1 }
        if let status = forcedReadStatus.current { return (status, nil) }
        return items.withLock { items -> (status: OSStatus, data: Data?) in
            guard let match = Self.matches(query, in: items).first else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, items[match])
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let (prefix, group) = Self.key(attributes)
        return items.withLock { items in
            guard items[prefix + (group ?? "")] == nil else { return errSecDuplicateItem }
            items[prefix + (group ?? "")] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        items.withLock { items in
            let found = Self.matches(query, in: items)
            for match in found { items[match] = attributes[kSecValueData as String] as? Data }
            return found.isEmpty ? errSecItemNotFound : errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        items.withLock { items in
            let found = Self.matches(query, in: items)
            for match in found { items.removeValue(forKey: match) }
            return found.isEmpty ? errSecItemNotFound : errSecSuccess
        }
    }

    /// Stores `data` as the item of `service`, `account` and `group`, whatever it holds.
    func put(_ data: Data, service: String, account: String, group: String) {
        items.withLock { $0[service + "|" + account + "|" + group] = data }
    }
}

/// A receipt's transport under test control. It records each request, runs `onSend` once it started one, and completes
/// one only when a test says so, on the queue the transport was made with, as the live transport delivers. Once
/// invalidated, it starts nothing.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    /// A request in flight; its cancellation is recorded.
    final class Handle: HTTPTaskHandle, @unchecked Sendable {
        private let cancelled = Locked(false)

        var isCancelled: Bool { cancelled.current }

        func cancel() {
            cancelled.set(true)
        }
    }

    private struct Sent {
        let request: HTTPRequest
        let handle: Handle
        var completion: (@Sendable (HTTPResult) -> Void)?
    }

    private struct Requests {
        var sent: [Sent] = []
        var invalidated = false
    }

    let queue: DispatchQueue
    private let state = Locked(Requests())
    private let onSend: Locked<(@Sendable () -> Void)?>

    init(queue: DispatchQueue, onSend: Locked<(@Sendable () -> Void)?>) {
        self.queue = queue
        self.onSend = onSend
    }

    var requests: [HTTPRequest] { state.current.sent.map(\.request) }
    var handles: [Handle] { state.current.sent.map(\.handle) }
    var isInvalidated: Bool { state.current.invalidated }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) -> HTTPTaskHandle? {
        let handle = state.withLock { state -> Handle? in
            guard !state.invalidated else { return nil }
            let handle = Handle()
            state.sent.append(Sent(request: request, handle: handle, completion: completion))
            return handle
        }
        if handle != nil { onSend.current?() }
        return handle
    }

    func invalidate() {
        state.withLock { $0.invalidated = true }
    }

    /// Completes request `index` with `result` (once, as URLSession does) on the transport's queue, and waits until
    /// that ran.
    func complete(_ index: Int, with result: HTTPResult) {
        let completion = state.withLock { state -> (@Sendable (HTTPResult) -> Void)? in
            guard state.sent.indices.contains(index) else { return nil }
            defer { state.sent[index].completion = nil }
            return state.sent[index].completion
        }
        queue.async { completion?(result) }
        queue.sync {}
    }
}

/// Holds every scheduled item until a test fires it. No real waits.
final class StepScheduler: Scheduler, @unchecked Sendable {
    private struct Item {
        let seconds: Double
        let queue: DispatchQueue
        let item: DispatchWorkItem
    }

    private let items = Locked<[Item]>([])

    /// The waits of the items neither fired nor cancelled, oldest first.
    var waits: [Double] { items.current.filter { !$0.item.isCancelled }.map(\.seconds) }

    func schedule(after seconds: Double, on queue: DispatchQueue, _ item: DispatchWorkItem) {
        items.withLock { $0.append(Item(seconds: seconds, queue: queue, item: item)) }
    }

    /// Runs the oldest live item on its queue and waits until it ran; returns its wait, nil when there is none.
    @discardableResult
    func fireNext() -> Double? {
        let next = items.withLock { items -> Item? in
            items.removeAll { $0.item.isCancelled }
            return items.isEmpty ? nil : items.removeFirst()
        }
        guard let next else { return nil }
        next.queue.async(execute: next.item)
        next.queue.sync {}
        return next.seconds
    }
}

/// Time a test moves by hand, from 2026-09-21 14:13:20 UTC (`FixedClock`). Scripted readings, when set, are answered
/// first, one per read.
final class StepClock: Clock, @unchecked Sendable {
    private let time = Locked(FixedClock().now())
    private let scripted = Locked<[Double]>([])

    func now() -> Double {
        scripted.withLock { readings -> Double? in readings.isEmpty ? nil : readings.removeFirst() } ?? time.current
    }

    func advance(_ seconds: Double) {
        time.withLock { $0 += seconds }
    }

    /// The next reads answer `readings`, in order.
    func script(_ readings: [Double]) {
        scripted.set(readings)
    }
}

/// A semaphore held weakly: a receipt's lives exactly as long as the receipt.
struct WeakSemaphore {
    weak var semaphore: DispatchSemaphore?
}

/// A content handler that records, at each call, the inbox's file names.
final class DeliveryProbe: @unchecked Sendable {
    private let seen = Locked<[[String]]>([])
    private let files: @Sendable () -> [String]

    init(files: @escaping @Sendable () -> [String]) {
        self.files = files
    }

    var calls: [[String]] { seen.current }

    var handler: (UNNotificationContent) -> Void {
        { [seen, files] _ in
            let names = files()
            seen.withLock { $0.append(names) }
        }
    }
}

/// One extension with the receipts on: a temporary App Group, the item the app shares, and the network, the waits,
/// the clock and the `didReceive` thread's wait under test control. Every entry is collected, whatever its level.
final class ReceiptRig: @unchecked Sendable {
    static let group = "group.com.salla.test"
    static let appBundle = "com.salla.test"
    static let deviceId = "6f1c2a4e-9b7d-4c3a-8e5f-1a2b3c4d5e6f"
    static let secret = "c2VjcmV0LXJlY2VpcHRzLWE"
    static let rotatedDeviceId = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    static let rotatedSecret = "c2VjcmV0LXJlY2VpcHRzLWI"

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-receipts-\(UUID().uuidString)")
    let keychain = ReceiptKeychain()
    let scheduler = StepScheduler()
    let clock = StepClock()
    let downloader = FakeDownloader()
    let logger: SDKLogger
    /// What `random()` answers: 0.5 is a 12 s wait.
    let random = Locked(0.5)
    let isMainThread = Locked(false)
    let appBundleIdentifier = Locked<String?>(ReceiptRig.appBundle)
    /// The `seconds` of each wait a `didReceive` thread asked for.
    let waited = Locked<[Double]>([])
    /// Signalled as each of those waits starts: a test learns there that a `didReceive` on another thread waits.
    let waitStarted = DispatchSemaphore(value: 0)
    /// The semaphore of each wait, weakly: one per receipt, freed with it.
    private let semaphores = Locked<[WeakSemaphore]>([])
    /// Runs on the receipt's queue each time one of its transports started a request.
    let onSend = Locked<(@Sendable () -> Void)?>(nil)
    /// When set, every transport is made invalidated: no request can start.
    let deadTransports = Locked(false)
    private let made = Locked<[ScriptedTransport]>([])
    private let logged = Locked<[SallaPushLogEntry]>([])

    init() {
        logger = SDKLogger(categoryOverride: "extension", plistLevelReader: { nil }, consoleSink: { _, _, _ in })
        let logged = self.logged
        logger.setTap { entry in logged.withLock { $0.append(entry) } }
    }

    /// The transports the receipts made, one each, in order.
    var transports: [ScriptedTransport] { made.current }
    /// How many receipts that a `didReceive` waited for are still alive.
    var liveReceipts: Int { semaphores.current.filter { $0.semaphore != nil }.count }
    /// Every request, in the order of the transports.
    var requests: [HTTPRequest] { transports.flatMap(\.requests) }
    /// Every entry but the badge's (`nse.badge_*`, which `BadgeTests` covers).
    var entries: [SallaPushLogEntry] { logged.current.filter { !$0.code.hasPrefix("nse.badge_") } }

    /// The `reason` of every `nse.received_deferred` entry, in order.
    var deferredReasons: [String] {
        entries.filter { $0.code == "nse.received_deferred" }.map { $0.metadata[LogMetadataKey.reason] ?? "" }
    }

    func entries(_ code: String) -> [SallaPushLogEntry] {
        entries.filter { $0.code == code }
    }

    var inbox: Inbox {
        Inbox(folder: Inbox.folder(inContainer: root.appendingPathComponent("group", isDirectory: true)))
    }

    /// The inbox's file names, sorted.
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.folder.path)) ?? []).sorted()
    }

    /// The state of each record (`sending`, `inflight`, `sent` or `json`), by message id.
    var states: [String: String] {
        var states: [String: String] = [:]
        for name in files {
            let data = (try? Data(contentsOf: inbox.folder.appendingPathComponent(name))) ?? Data()
            let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            states[record?["message_id"] as? String ?? name] = (name as NSString).pathExtension
        }
        return states
    }

    /// A handler of `appGroup`, whose `didReceive` waits with `block`: by default it returns at once, and the test drives
    /// the receipt.
    func makeHandler(appGroup: String? = ReceiptRig.group,
                     block: @escaping ReceiptEnvironment.Block = { _, _ in true }) -> SallaPushServiceExtension {
        let receipts = ReceiptEnvironment(
            keychain: keychain,
            appBundleIdentifier: { [appBundleIdentifier] in appBundleIdentifier.current },
            makeTransport: { [made, onSend, deadTransports] queue in
                let transport = ScriptedTransport(queue: queue, onSend: onSend)
                if deadTransports.current { transport.invalidate() }
                made.withLock { $0.append(transport) }
                return transport
            },
            scheduler: scheduler,
            random: { [random] in random.current },
            block: { [waited, semaphores, waitStarted] semaphore, seconds in
                waited.withLock { $0.append(seconds) }
                semaphores.withLock { $0.append(WeakSemaphore(semaphore: semaphore)) }
                waitStarted.signal()
                return block(semaphore, seconds)
            },
            isMainThread: { [isMainThread] in isMainThread.current })
        let container = root.appendingPathComponent("group", isDirectory: true)
        let environment = ExtensionEnvironment(downloader: downloader, containerURL: { _ in container }, clock: clock,
                                               logger: logger, prepareAttachment: { _ in { _ in } }, receipts: receipts)
        return SallaPushServiceExtension(appGroupIdentifier: appGroup, environment: environment)
    }

    /// The app shares these credentials, as it does while consent allows.
    func share(deviceId: String = ReceiptRig.deviceId, secret: String = ReceiptRig.secret) {
        let credentials = ExtensionCredentials(appId: "st_42_ios", base: .production, deviceId: deviceId,
                                               secret: SecretString(secret))
        _ = ExtensionCredentialsStore(appBundleIdentifier: Self.appBundle, access: keychain)?
            .save(credentials, group: Self.group)
    }

    /// The app stops sharing them (consent withdrawn).
    func unshare() {
        _ = ExtensionCredentialsStore(appBundleIdentifier: Self.appBundle, access: keychain)?.delete()
    }

    /// A SallaPush notification of `messageId`, with an image when `image` is set.
    func notification(_ messageId: String = "msg_ab", image: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        var userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Title", "body": "Body"], "mutable-content": 1],
                                            "sp_v": "1", "sp_id": messageId]
        if let image { userInfo["sp_image"] = image }
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: messageId, content: content, trigger: nil)
    }

    /// A probe of this inbox.
    func probe() -> DeliveryProbe {
        let folder = inbox.folder
        return DeliveryProbe { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension HTTPResult {
    /// push-service's `202 {}`, with a request id.
    static let accepted = HTTPResult.response(status: 202, headers: ["x-request-id": "req-1"], body: Data("{}".utf8))

    /// An answer of status `status` with push-service's error envelope.
    static func error(_ status: Int, _ code: String, message: String? = nil, headers: [String: String] = [:]) -> HTTPResult {
        let envelope: [String: Any] = ["error": ["code": code, "message": message ?? "\(code) message"]]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return .response(status: status, headers: headers, body: body)
    }

    /// An answer of status `status` with `text` as its body.
    static func text(_ status: Int, _ text: String) -> HTTPResult {
        .response(status: status, headers: [:], body: Data(text.utf8))
    }
}
