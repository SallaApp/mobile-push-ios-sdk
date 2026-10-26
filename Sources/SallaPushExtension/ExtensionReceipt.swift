import Foundation
import SallaPushCore

/// When, and how long, the extension sends `received` itself.
enum ReceiptTiming {
    /// The random wait before the first attempt is a whole number of seconds below this bound, 0 to 24, so a
    /// campaign's receipts spread over 25 s.
    static let delayBound = 25
    /// How long the extension stays alive for it, from the notification's arrival: the 30 s Apple gives a Notification
    /// Service Extension.
    static let lifetime: Double = 30
    /// An attempt starts only with this much time left. Its timeout is all the time left: a slow answer is waited for,
    /// never cut and sent again.
    static let minimumAttemptTime: Double = 2
    /// The first attempt and two retries, as time allows.
    static let maximumAttempts = 3

    /// The wait for a uniform `unit` in 0...1: 0 to 24 whole seconds, and 0 for a value that is not a number.
    static func delay(unit: Double) -> Double {
        let clamped = unit.isFinite ? min(max(unit, 0), 1) : 0
        return Double(min(Int(clamped * Double(delayBound)), delayBound - 1))
    }
}

/// What the receipts need from the system, injected so tests run without a Keychain, a network, real time or a blocked
/// thread.
struct ReceiptEnvironment: Sendable {
    /// Blocks the calling thread until `semaphore` is signalled or `seconds` pass; true when it was signalled.
    typealias Block = @Sendable (_ semaphore: DispatchSemaphore, _ seconds: Double) -> Bool

    /// Where the app shares its device credentials with the extension.
    var keychain: KeychainAccess
    /// The bundle id of the app that contains the extension; nil when it is unknown.
    var appBundleIdentifier: @Sendable () -> String?
    /// A transport whose completions run on `queue`: one per receipt.
    var makeTransport: @Sendable (_ queue: DispatchQueue) -> HTTPTransport
    /// Runs each attempt after its wait.
    var scheduler: Scheduler
    /// A uniform value in 0..<1, for the random wait and the backoff jitter.
    var random: @Sendable () -> Double
    /// How the `didReceive` thread waits for its receipt.
    var block: Block
    /// Whether the caller runs on the main thread, which SallaPush never blocks.
    var isMainThread: @Sendable () -> Bool

    /// The system Keychain, one `URLSession` per receipt with the app's User-Agent, `asyncAfter` and a semaphore wait.
    static let live = ReceiptEnvironment(
        keychain: SystemKeychain(),
        appBundleIdentifier: { containingAppBundleIdentifier },
        makeTransport: { queue in
            let facts = SystemDeviceFacts()
            return URLSessionTransport(queue: queue,
                                       userAgent: URLSessionTransport.userAgent(sdkVersion: sallaPushSDKVersion,
                                                                                osVersion: facts.osVersion(),
                                                                                model: facts.deviceModel()))
        },
        scheduler: DispatchScheduler(),
        random: { Double.random(in: 0..<1) },
        block: waitForSignal,
        isMainThread: { Thread.isMainThread })

    /// The live `block`: a semaphore wait of `seconds` at most.
    static let waitForSignal: Block = { semaphore, seconds in
        semaphore.wait(timeout: .now() + Duration.clamped(seconds)) == .success
    }

    /// The containing app's bundle id, read once per process from where the extension is installed.
    static let containingAppBundleIdentifier: String? =
        appBundleIdentifier(ofExtensionAt: Bundle.main.bundleURL)

    /// The bundle id in the Info.plist of the app that contains the extension at `url`; nil when `url` is not an
    /// `.appex`, or that app names none.
    static func appBundleIdentifier(ofExtensionAt url: URL) -> String? {
        containingAppURL(ofExtensionAt: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The app that contains the extension at `url` (`…/<App>.app/PlugIns/<Extension>.appex`): two folders up. nil when
    /// `url` is not an `.appex`.
    static func containingAppURL(ofExtensionAt url: URL) -> URL? {
        guard url.pathExtension == "appex" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// One notification's `received`, sent by the extension itself.
///
/// It owns its lifetime: its scheduled attempt and its request hold it, strongly and on purpose, and the handler
/// doesn't, so an app that releases the handler doesn't stop it; `end` breaks those cycles. Its record is `.sending`
/// (claimed) until attempt 1 takes the send lock (`.inflight`), then `.sent` after a 2xx, and back to `.json` for the
/// app otherwise. The app may take a `.sending` record over at any time, and the lock then fails. The attempts and the
/// answers run on the receipt's own queue, never on the caller's thread, so a `didReceive` thread that waits for the
/// receipt can't block it.
final class ExtensionReceipt: @unchecked Sendable {
    /// How a receipt ended. A release carries the code the answer table chose (`nse.received_deferred`,
    /// `net.rate_limited`, `net.routes_closed`, `net.client_error` or `net.redirect_refused`), its message and its
    /// metadata. `takenOver`: the app took the claim over before the lock, so nothing was sent and nothing is renamed.
    private enum Outcome {
        case sent(status: Int, requestId: String?)
        case released(code: LogCode, text: String, metadata: [String: String])
        case takenOver
    }

    /// What runs, cleared once by `end`.
    private struct State {
        var ended = false
        var pending: DispatchWorkItem?
        var request: HTTPTaskHandle?
        var transport: HTTPTransport?
        /// The attempt of the latest request, and the app id of the credentials it was sent with.
        var attempt = 0
        var appId: String?
    }

    private let messageId: String
    private let arrival: Double
    private let deadline: Double
    /// The random wait before the first attempt, fixed at creation, so any thread reads it without a race.
    private let delay: Double
    private let claim: InboxClaim
    private let inbox: Inbox
    private let store: ExtensionCredentialsStore
    /// The extension's App Group: the shared item's access group.
    private let group: String
    private let receipts: ReceiptEnvironment
    private let clock: Clock
    private let logger: SDKLogger
    private let queue = DispatchQueue(label: "com.salla.push.extension.receipt", qos: .utility)
    /// Signalled once, last, when the receipt ended.
    private let ended = DispatchSemaphore(value: 0)
    private let state = Locked(State())

    /// A receipt of `claim`, the record of `messageId` written at `arrival`; `start()` starts it.
    init(messageId: String, arrival: Double, claim: InboxClaim, inbox: Inbox, store: ExtensionCredentialsStore,
         group: String, receipts: ReceiptEnvironment, clock: Clock, logger: SDKLogger) {
        self.messageId = messageId
        self.arrival = arrival
        self.claim = claim
        self.inbox = inbox
        self.store = store
        self.group = group
        self.receipts = receipts
        self.clock = clock
        self.logger = logger
        deadline = arrival + ReceiptTiming.lifetime
        delay = ReceiptTiming.delay(unit: receipts.random())
    }

    /// Whether the receipt ended: sent, released or taken over.
    var hasEnded: Bool {
        state.withLock { $0.ended }
    }

    /// Schedules attempt 1 after the random wait.
    func start() {
        schedule(attempt: 1, after: delay)
    }

    /// Blocks the calling thread, the extension's `didReceive` (never the main thread), until the receipt ended, and
    /// at most until its deadline, which releases the record.
    func waitUntilEnded() {
        let seconds = min(deadline - clock.now(), ReceiptTiming.lifetime)
        if receipts.block(ended, seconds) { return }
        cancel(reason: "time_limit", text: "the extension's 30 s ran out")
    }

    /// Ends the receipt from any thread and gives the record back to the app: expiry (`expired`), the deadline
    /// (`time_limit`), or an attempt that can't be made.
    func cancel(reason: String, text: String) {
        release(reason: reason, why: text, metadata: [:])
    }

    /// The message of `nse.received_deferred`: why the extension leaves `received` to the app.
    static func deferred(_ why: String) -> String {
        "'received' is left for the app (\(why)); the app sends it the next time it comes to the foreground."
    }

    /// The end of the messages of the answers logged with a code of their own.
    private static let leftForTheApp = "'received' is left for the app, which sends it the next time it comes to the "
        + "foreground."

    // MARK: - Attempts

    /// Runs `attempt(number)` on the receipt's queue after `seconds`, unless the receipt ended.
    private func schedule(attempt number: Int, after seconds: Double) {
        let item = DispatchWorkItem { [self] in attempt(number) }
        let scheduled = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.pending = item
            return true
        }
        if scheduled { receipts.scheduler.schedule(after: seconds, on: queue, item) }
    }

    /// One attempt, on the receipt's queue.
    private func attempt(_ number: Int) {
        guard !hasEnded else { return }
        let now = clock.now()
        guard deadline - now >= ReceiptTiming.minimumAttemptTime else {
            return cancel(reason: "time_limit", text: "the extension's 30 s ran out")
        }
        // Read again before every attempt: consent withdrawn, or the credentials rotated, since the claim.
        guard case let .found(credentials) = store.read(group: group) else {
            return cancel(reason: "no_credentials", text: "the app no longer shares its device credentials")
        }
        // The send lock: from here on the record is `.inflight`, which the app leaves alone for 60 s. A failed rename
        // means the app took the claim over (a tap, a foreground flush), and it sends `received` itself.
        if number == 1, !inbox.lock(claim) {
            return end(.takenOver)
        }
        // Ended meanwhile (expiry, the deadline): `end` gave the record back.
        guard !hasEnded else { return }
        send(attempt: number, credentials: credentials, timeout: deadline - now)
    }

    /// Starts the request of attempt `number`, whose timeout is all the time left.
    private func send(attempt number: Int, credentials: ExtensionCredentials, timeout: Double) {
        // Attempts run one at a time on `queue`, so only they create the transport, outside the lock.
        let transport = state.withLock { $0.transport } ?? receipts.makeTransport(queue)
        let client = APIClient(base: credentials.base, transport: transport, clock: clock)
        let event = EventItem(type: "received", notificationId: messageId, at: ISO8601.string(from: arrival))
        let handle = client.events(deviceId: credentials.deviceId, secret: credentials.secret,
                                   body: EventsBody(events: [event]), timeout: timeout) { [self] result in
            answered(result, attempt: number, credentials: credentials)
        }
        let kept = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.transport = transport
            state.request = handle
            state.attempt = number
            state.appId = credentials.appId
            return true
        }
        guard kept else {
            // The receipt ended meanwhile (expiry, the deadline), and `end` gave the record back: this request stops.
            handle?.cancel()
            transport.invalidate()
            return
        }
        if handle == nil { cancel(reason: "failed", text: "the request could not start") }
    }

    /// The answer table, on the receipt's queue. The rows are tried in order, and the last one
    /// takes every other answer.
    private func answered(_ result: APIResult<EventsResponse>, attempt number: Int, credentials: ExtensionCredentials) {
        let error: APIError
        switch result {
        case let .success(success):
            return end(.sent(status: success.status, requestId: success.requestId))
        case let .failure(failure):
            error = failure
        }
        var metadata = error.metadata
        metadata[LogMetadataKey.appId] = credentials.appId
        metadata[LogMetadataKey.attempt] = String(number)
        let operation = "\(error.route.method) \(error.route.template)"
        let status = error.status ?? 0
        switch (error.kind, error.status, error.code) {
        case (.invalidResponse, _, _) where (200..<300).contains(status):
            // push-service took it: sending it again would count it twice. The engine retries such answers.
            end(.sent(status: status, requestId: error.requestId))
        case _ where error.isRateLimited:
            end(.released(code: .netRateLimited, text: "Rate limited (429); " + Self.leftForTheApp, metadata: metadata))
        case (.network, _, _),
             (.http, _, _) where status >= 500,
             (.nonJSON, _, _) where status >= 500:
            retry(after: error, attempt: number, metadata: metadata)
        case (.timeout, _, _), (.cancelled, _, _):
            // A timeout fires only at the deadline, and push-service may have stored the request: never sent again.
            release(reason: "failed", why: "\(operation) failed: \(error.summary)", metadata: metadata)
        case (.http, 401?, "invalid_device_secret"?), (.http, 404?, "unknown_device"?):
            // The app registers the device again, then sends the record.
            release(reason: "stale_credentials",
                    why: "the SallaPush server no longer knows this device: \(error.summary)", metadata: metadata)
        case (.http, 404?, "not_found"?):
            end(.released(code: .netRoutesClosed,
                          text: "SallaPush is unavailable (404 not_found); " + Self.leftForTheApp,
                          metadata: metadata))
        case _ where error.isClientError:
            // The app's engine applies its own answer table to the event.
            end(.released(code: .netClientError, text: "\(operation) was rejected (\(error.summary)); " + Self.leftForTheApp,
                          metadata: metadata))
        case (.http, _, _) where (400..<500).contains(status), (.nonJSON, _, _) where (400..<500).contains(status):
            // No answer of push-service's: an edge's or a proxy's.
            release(reason: "failed", why: "\(operation) failed: \(error.summary)", metadata: metadata)
        case (.redirect, _, _):
            end(.released(code: .netRedirectRefused,
                          text: "The server answered with a redirect (\(status)), which SallaPush never follows; "
                              + Self.leftForTheApp,
                          metadata: metadata))
        default:
            release(reason: "failed", why: "\(operation) failed: \(error.summary)", metadata: metadata)
        }
    }

    /// Retries a server error or a failed connection after its backoff (or `Retry-After`), when an attempt is left and
    /// it would start with `minimumAttemptTime` left; otherwise releases the record.
    private func retry(after error: APIError, attempt number: Int, metadata: [String: String]) {
        let operation = "\(error.route.method) \(error.route.template)"
        let wait = Duration.clamped(error.retryAfter ?? Backoff.delay(attempt: number, random: receipts.random()))
        guard number < ReceiptTiming.maximumAttempts,
              deadline - (clock.now() + wait) >= ReceiptTiming.minimumAttemptTime
        else {
            return release(reason: "failed", why: "\(operation) failed: \(error.summary)", metadata: metadata)
        }
        var retried = metadata
        retried[LogMetadataKey.delay] = String(Int(wait.rounded()))
        logger.log(.netRetry, "\(operation) failed (\(error.summary)); retry \(number) in \(Int(wait.rounded())) s.",
                   metadata: retried)
        schedule(attempt: number + 1, after: wait)
    }

    // MARK: - End

    /// Ends the receipt with `nse.received_deferred`, giving the record back to the app.
    private func release(reason: String, why: String, metadata: [String: String]) {
        var tagged = metadata
        tagged[LogMetadataKey.reason] = reason
        end(.released(code: .nseReceivedDeferred, text: Self.deferred(why), metadata: tagged))
    }

    /// Ends the receipt once: stops what runs, settles the record, logs, then wakes `didReceive`, last, so that it
    /// returns only once the record is final.
    private func end(_ outcome: Outcome) {
        let taken = state.withLock { state -> State? in
            guard !state.ended else { return nil }
            defer { state = State(ended: true) }
            return state
        }
        guard let taken else { return }
        taken.pending?.cancel()
        taken.request?.cancel()
        let settled: Bool
        switch outcome {
        case .sent: settled = inbox.markSent(claim)
        case .released: settled = inbox.release(claim)
        case .takenOver: settled = false
        }
        // The rename failed: the app took the record over (a `.sending` one at once, an `.inflight` one after 60 s).
        if !settled {
            logger.log(.nseReceivedDeferred, "The app took over this 'received' record; the extension doesn't send it.",
                       metadata: [LogMetadataKey.reason: "taken_over"])
        }
        log(outcome, of: taken)
        taken.transport?.invalidate()
        ended.signal()
    }

    /// Logs how the receipt ended, from what ran when it ended; a takeover was logged already.
    private func log(_ outcome: Outcome, of taken: State) {
        switch outcome {
        case let .sent(status, requestId):
            var metadata = [LogMetadataKey.httpStatus: String(status), LogMetadataKey.attempt: String(taken.attempt),
                            LogMetadataKey.delay: String(Int(delay))]
            metadata[LogMetadataKey.appId] = taken.appId
            metadata[LogMetadataKey.requestId] = requestId
            logger.log(.nseReceivedSent,
                       "'received' sent from the extension (HTTP \(status), attempt \(taken.attempt), after a "
                           + "\(Int(delay)) s wait).",
                       metadata: metadata)
        case let .released(code, text, metadata):
            logger.log(code, text, metadata: metadata)
        case .takenOver:
            break
        }
    }
}
