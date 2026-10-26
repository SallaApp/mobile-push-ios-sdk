@_exported import SallaPushCore
import Foundation
import UserNotifications

/// The Notification Service Extension handler. Create one per `NotificationService` instance and forward
/// `didReceive` and `serviceExtensionTimeWillExpire` to it.
///
/// For a SallaPush notification it attaches the image (https only), reports `received`, counts the notification on the
/// app icon badge while the app's `autoUpdateBadge` is on, and calls the content handler exactly once. Call it directly
/// from your `NotificationService`'s `didReceive`, never from a completion block or a serial queue: it shows the
/// notification first, then may wait up to 30 s before it returns. For any other notification it returns false and
/// never touches the content handler, so another SDK's handler can run.
@objc public final class SallaPushServiceExtension: NSObject {
    private let appGroupIdentifier: String?
    private let environment: ExtensionEnvironment
    private let ownership = Ownership()
    /// The receipts of this handler's notifications, which expiry stops.
    private let receipts = Locked<[ExtensionReceipt]>([])

    /// Creates a handler that uses the App Group `appGroupIdentifier` (nil or blank: no App Group).
    @objc public init(appGroupIdentifier: String?) {
        let trimmed = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appGroupIdentifier = (trimmed?.isEmpty ?? true) ? nil : trimmed
        environment = .live
        super.init()
    }

    /// Creates a handler that reads the App Group from the extension's Info.plist key `SallaPushAppGroup`.
    @objc public override convenience init() {
        self.init(appGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "SallaPushAppGroup") as? String)
    }

    init(appGroupIdentifier: String?, environment: ExtensionEnvironment) {
        let trimmed = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appGroupIdentifier = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.environment = environment
        super.init()
    }

    /// Whether `request` is a SallaPush notification, in either payload format; false for a nil request.
    @objc public static func isSallaPushNotification(_ request: UNNotificationRequest) -> Bool {
        // Objective-C callers can pass nil for this nonnull parameter; using it would crash.
        guard !isNullReference(request) else { return false }
        return PayloadParser.kind(of: request.content.userInfo) != nil
    }

    /// Handles a SallaPush notification and returns true; returns false, without calling `contentHandler`, for any
    /// other notification, and for a nil request (Objective-C callers can pass one). For a SallaPush notification it
    /// may return up to 30 s after it was called; the content handler runs first.
    @objc @discardableResult
    public func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) -> Bool {
        let logger = environment.logger
        guard !isNullReference(request) else {
            logger.log(.apiInvalidArgument, "didReceive ignored: the request is nil.")
            return false
        }
        guard let payload = PayloadParser.parse(request.content.userInfo, logger: logger) else {
            logger.log(.notifForeign, "Ignoring a notification from another SDK.")
            return false
        }
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        let delivery = Delivery(contentHandler: contentHandler, bestAttempt: mutable ?? request.content, mutable: mutable,
                                badgeCount: prepareBadge(for: request), logger: logger)
        if let replaced = ownership.replace(with: delivery) {
            logger.log(.nseReplacedRequest,
                       "A new notification arrived on the same extension instance; the previous one was delivered first.")
            replaced.cancelDownload()
            replaced.deliverBestAttempt()
        }
        let receipt = payload.isLocalCopy ? nil : payload.messageId.flatMap { recordReceived($0) }
        deliver(delivery, imageURL: payload.notification.imageURL, mutable: mutable)
        // Shown first, then kept alive until `received` is sent, at most 30 s after the notification arrived. This thread
        // waits; the receipt runs on its own queue, so nothing it needs runs here.
        receipt?.waitUntilEnded()
        return true
    }

    /// Delivers the best attempt of the notification this handler owns and returns true; false when it owns none.
    @objc @discardableResult
    public func serviceExtensionTimeWillExpire() -> Bool {
        let owned = ownership.take()
        if let owned {
            owned.cancelDownload()
            if !owned.isDelivered {
                environment.logger.log(.nseExpired, "The extension ran out of time; delivered the best attempt.")
            }
            owned.deliverBestAttempt()
        }
        // Delivered first, as quickly as possible: on this path the best attempt is all the user sees.
        for receipt in receipts.exchange([]) {
            receipt.cancel(reason: "expired", text: "the extension ran out of time")
        }
        return owned != nil
    }

    /// Calls the content handler now, or once the image is downloaded and attached.
    private func deliver(_ delivery: Delivery, imageURL: URL?, mutable: UNMutableNotificationContent?) {
        guard let imageURL, mutable != nil else {
            ownership.finish(delivery)
            return
        }
        let logger = environment.logger
        let ownership = self.ownership
        let prepare = environment.prepareAttachment
        let task = environment.downloader.download(imageURL) { result in
            switch result {
            case let .success(file):
                delivery.attach(file, using: prepare, logger: logger)
            case let .failure(reason):
                // A download this handler cancelled itself (expiry, a newer request) is not a failure to report.
                if !delivery.wasCancelled {
                    logger.log(.nseAttachmentFailed, "Image not attached (\(reason)); delivering without it.")
                }
            }
            ownership.finish(delivery)
        }
        delivery.setDownload(task)
    }

    /// Counts `request` on the app icon badge, and returns what reads the count when the notification is handed over;
    /// nil when SallaPush doesn't count it: no App Group, no app bundle id, no settings from the app (it hasn't run this
    /// SallaPush version with consent, or it uses another App Group), or `autoUpdateBadge` off. One listing and one
    /// file create, on the calling thread.
    private func prepareBadge(for request: UNNotificationRequest) -> (@Sendable () -> Int)? {
        guard let group = appGroupIdentifier, let container = environment.containerURL(group) else {
            skipBadgeOnce("no_app_group", "no App Group is available to the extension")
            return nil
        }
        guard let store = BadgeStore(container: container, appBundleIdentifier: environment.appBundleIdentifier()) else {
            skipBadgeOnce("no_app_bundle", "the bundle id of the extension's app is unknown")
            return nil
        }
        guard let settings = store.readSettings() else {
            skipBadgeOnce("no_settings", "the app hasn't run this SallaPush version with consent, or it uses another "
                              + "App Group")
            return nil
        }
        guard settings.autoUpdateBadge else { return nil }
        if store.add(identifier: request.identifier, at: environment.clock.now()) == .failed {
            environment.logger.logOnce(.storageFailed, key: "nse.badge_mark",
                                       "Could not count a notification on the app badge in the App Group; the badge "
                                           + "shows the notifications counted before it.")
        }
        return { store.count() }
    }

    /// Logs, once per process for each reason, why the extension doesn't count notifications on the app badge.
    private func skipBadgeOnce(_ reason: String, _ why: String) {
        environment.logger.logOnce(.nseBadgeSkipped, key: "nse.badge_skipped." + reason,
                                   "SallaPush doesn't count notifications on the app badge (\(why)).",
                                   metadata: [LogMetadataKey.reason: reason])
    }

    /// Writes `received` to the App Group inbox, claimed when the extension sends it itself, and returns the receipt
    /// that sends it; failures never block delivery.
    private func recordReceived(_ messageId: String) -> ExtensionReceipt? {
        let logger = environment.logger
        guard let group = appGroupIdentifier else {
            logger.logOnce(.configNoAppGroup, key: "nse.no_app_group",
                           "No App Group configured; notifications received in the extension will not be reported as 'received'.")
            return nil
        }
        guard let container = environment.containerURL(group) else {
            logger.log(.storageFailed,
                       "The App Group \(LogSanitizer.clean(group)) is not available to the extension; 'received' not recorded. "
                           + "Add it to the extension's App Groups capability.")
            return nil
        }
        let inbox = Inbox(folder: Inbox.folder(inContainer: container))
        let now = environment.clock.now()
        guard let start = receiptStart(group: group, messageId: messageId) else {
            report(inbox.writeReceived(messageId: messageId, at: now))
            return nil
        }
        switch inbox.writeClaimed(messageId: messageId, at: now) {
        case let .claimed(claim):
            return startReceipt(ExtensionReceipt(messageId: messageId, arrival: now, claim: claim, inbox: inbox,
                                                 store: start.store, group: group, receipts: start.receipts,
                                                 clock: environment.clock, logger: logger))
        case .full:
            report(.full)
        case .failed:
            report(.failed)
        }
        return nil
    }

    /// Logs an inbox write that recorded nothing; it never blocks delivery.
    private func report(_ result: Inbox.WriteResult) {
        let logger = environment.logger
        switch result {
        case .written:
            break
        case .full:
            logger.log(.eventsQueueFull,
                       "Event queue full (\(Inbox.capacity) files in the extension inbox); 'received' is not recorded until "
                           + "the app is opened.")
        case .failed:
            logger.log(.storageFailed, "Could not write the extension inbox; 'received' not recorded.")
        }
    }

    /// Whether the extension sends this `received` itself: the receipts' environment and
    /// the store of the item the app shares when it does. Otherwise the record is the app's, as before, and a miss
    /// worth knowing is logged once per process.
    private func receiptStart(group: String,
                              messageId: String) -> (receipts: ReceiptEnvironment, store: ExtensionCredentialsStore)? {
        guard let receiptEnvironment = environment.receipts else { return nil }
        // SallaPush never blocks the main thread: no claim, no Keychain read and no wait there.
        guard !receiptEnvironment.isMainThread() else {
            deferOnce("main_thread", "didReceive ran on the main thread, which SallaPush never blocks")
            return nil
        }
        // The app drops such an id too.
        guard MessageId.isStorable(messageId) else { return nil }
        guard let store = ExtensionCredentialsStore(appBundleIdentifier: receiptEnvironment.appBundleIdentifier(),
                                                    access: receiptEnvironment.keychain)
        else {
            deferOnce("no_app_bundle", "the bundle id of the extension's app is unknown")
            return nil
        }
        let logger = environment.logger
        switch store.read(group: group) {
        case .found:
            return (receiptEnvironment, store)
        case .absent:
            deferOnce("no_credentials", "the app shares no device credentials: it hasn't run registered with this SallaPush "
                          + "version yet, or consent is withheld")
        case .locked:
            deferOnce("credentials_locked", "the device credentials are unavailable until the first unlock")
        case let .unavailable(status):
            logger.logOnce(.storageFailed, key: "nse.credentials_unavailable",
                           "Could not read the device credentials the app shares with the extension (Keychain status "
                               + "\(status)); 'received' is left for the app.")
        case .malformed:
            logger.logOnce(.storageFailed, key: "nse.credentials_malformed",
                           "Could not read the device credentials the app shares with the extension (an item SallaPush "
                               + "could not have written); 'received' is left for the app.")
        }
        return nil
    }

    /// Logs, once per process for each reason, why the extension leaves `received` to the app.
    private func deferOnce(_ reason: String, _ why: String) {
        environment.logger.logOnce(.nseReceivedDeferred, key: "nse." + reason, ExtensionReceipt.deferred(why),
                                   metadata: [LogMetadataKey.reason: reason])
    }

    /// Keeps `receipt` until it ended, so that expiry can stop it, and starts it.
    private func startReceipt(_ receipt: ExtensionReceipt) -> ExtensionReceipt {
        receipts.withLock { running in
            running.removeAll { $0.hasEnded }
            running.append(receipt)
        }
        receipt.start()
        return receipt
    }
}

/// The dependencies of the extension handler.
struct ExtensionEnvironment: Sendable {
    /// Puts a prepared attachment into the content; cheap, it runs under the delivery lock.
    typealias ApplyAttachment = @Sendable (UNMutableNotificationContent) -> Void
    /// Creates the attachment of a downloaded image. Slow (the system moves the file into its attachment store), so
    /// it runs outside every lock.
    typealias PrepareAttachment = @Sendable (DownloadedAttachment) throws -> ApplyAttachment

    var downloader: AttachmentDownloading
    var containerURL: @Sendable (String) -> URL?
    var clock: Clock
    var logger: SDKLogger
    var prepareAttachment: PrepareAttachment = ExtensionEnvironment.systemAttachment
    /// What sending `received` from the extension needs; nil sends nothing, and the app sends every `received`.
    var receipts: ReceiptEnvironment?
    /// The bundle id of the app that contains the extension, which names the app's badge folder; nil when it is unknown.
    var appBundleIdentifier: @Sendable () -> String? = { nil }

    /// The extension logs with category `extension` at the level of its own Info.plist (default warn).
    static let live = ExtensionEnvironment(
        downloader: URLSessionAttachmentDownloader(),
        containerURL: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
        clock: SystemClock(),
        logger: SDKLogger(categoryOverride: "extension"),
        receipts: .live,
        appBundleIdentifier: { ReceiptEnvironment.containingAppBundleIdentifier })

    /// The live step: a `UNNotificationAttachment` with the type hint; the system moves the file into its store.
    static let systemAttachment: PrepareAttachment = { file in
        let attachment = try UNNotificationAttachment(
            identifier: "sallapush-image", url: file.fileURL,
            options: [UNNotificationAttachmentOptionsTypeHintKey: file.typeIdentifier])
        let boxed = UncheckedSendable(attachment)
        return { content in content.attachments = [boxed.value] }
    }
}

/// The notification a handler currently owns.
private final class Ownership: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Delivery?

    /// Takes `delivery` and returns the one it replaces.
    func replace(with delivery: Delivery) -> Delivery? {
        lock.locked { () -> Delivery? in
            defer { current = delivery }
            return current
        }
    }

    /// Gives up the current delivery.
    func take() -> Delivery? {
        lock.locked { () -> Delivery? in
            defer { current = nil }
            return current
        }
    }

    /// Delivers `delivery` and releases it if it is still the current one.
    func finish(_ delivery: Delivery) {
        lock.locked {
            if current === delivery { current = nil }
        }
        delivery.deliverBestAttempt()
    }
}

/// One owned notification: its content handler, called exactly once, and its best attempt. The lock is held only
/// for flag and pointer updates, never for I/O, so the expiry path can always deliver at once.
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private let contentHandler: (UNNotificationContent) -> Void
    private let bestAttempt: UNNotificationContent
    private let mutable: UNMutableNotificationContent?
    /// Reads SallaPush's count of the app badge, when SallaPush counts this notification.
    private let badgeCount: (@Sendable () -> Int)?
    private let logger: SDKLogger
    private var delivered = false
    private var cancelled = false
    private var download: AttachmentDownloadTask?

    init(contentHandler: @escaping (UNNotificationContent) -> Void, bestAttempt: UNNotificationContent,
         mutable: UNMutableNotificationContent?, badgeCount: (@Sendable () -> Int)?, logger: SDKLogger) {
        self.contentHandler = contentHandler
        self.bestAttempt = bestAttempt
        self.mutable = mutable
        self.badgeCount = badgeCount
        self.logger = logger
    }

    var isDelivered: Bool { lock.locked { delivered } }

    /// Whether this handler cancelled the download (expiry or a newer request).
    var wasCancelled: Bool { lock.locked { cancelled } }

    func setDownload(_ task: AttachmentDownloadTask) {
        let cancelNow = lock.locked { () -> Bool in
            if delivered {
                cancelled = true
                return true
            }
            download = task
            return false
        }
        if cancelNow { task.cancel() }
    }

    func cancelDownload() {
        let task = lock.locked { () -> AttachmentDownloadTask? in
            defer { download = nil }
            if download != nil { cancelled = true }
            return download
        }
        task?.cancel()
    }

    /// Adds the image to the content, unless the notification was already delivered. The attachment is created
    /// before the lock is taken; a file that ends up not attached is deleted.
    func attach(_ file: DownloadedAttachment, using prepare: ExtensionEnvironment.PrepareAttachment, logger: SDKLogger) {
        guard !isDelivered else {
            discard(file)
            return
        }
        let apply: ExtensionEnvironment.ApplyAttachment
        do {
            apply = try prepare(file)
        } catch {
            logger.log(.nseAttachmentFailed, "Image not attached (\(LogSanitizer.describe(error))); delivering without it.")
            discard(file)
            return
        }
        let applied = lock.locked { () -> Bool in
            guard !delivered, let mutable else { return false }
            apply(mutable)
            return true
        }
        if !applied { discard(file) }
    }

    /// Deletes a downloaded file that was not attached (an attached one was moved by the system, so this is a no-op).
    private func discard(_ file: DownloadedAttachment) {
        try? FileManager.default.removeItem(at: file.fileURL)
    }

    /// Calls the content handler with the best attempt, once. When SallaPush counts the notification, the best attempt
    /// carries the count read now, at hand-over, so the last notification shown carries the full count; it replaces
    /// the push's own badge. A count of 0 leaves the badge unset: a badge of 0 can hide the banner just delivered.
    func deliverBestAttempt() {
        guard !isDelivered else { return }
        let count = badgeCount?()
        let first = lock.locked { () -> Bool in
            if delivered { return false }
            delivered = true
            if let count { mutable?.badge = count > 0 ? NSNumber(value: count) : nil }
            return true
        }
        guard first else { return }
        if let count, count > 0, mutable != nil {
            logger.log(.nseBadgeSet, "The notification carries the app badge \(count).",
                       metadata: [LogMetadataKey.count: String(count)])
        }
        contentHandler(bestAttempt)
    }
}

private extension NSLock {
    func locked<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
