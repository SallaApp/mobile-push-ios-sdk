import Foundation
import SallaPushCore

/// Bundle facts read from the app (or extension) Info.plist. Injected so tests count and control reads.
protocol BundleInfoSource: AnyObject, Sendable {
    var bundleIdentifier: String? { get }
    var shortVersion: String? { get }
    func string(forInfoKey key: String) -> String?
    /// Whether the Info.plist turns the switch `key` on (`InfoPlistSwitch.isOn(_:)`).
    func isOn(infoKey key: String) -> Bool
}

/// The main bundle.
final class MainBundleInfo: BundleInfoSource, @unchecked Sendable {
    var bundleIdentifier: String? { Bundle.main.bundleIdentifier }
    var shortVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    func string(forInfoKey key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    func isOn(infoKey key: String) -> Bool {
        InfoPlistSwitch.isOn(Bundle.main.object(forInfoDictionaryKey: key))
    }
}

/// An Info.plist switch, such as `SallaPushLogFullIdentifiers`: on for the Boolean `YES`, and for the strings `YES`,
/// `true` and `1` in any case, which a build setting writes; off for anything else, a missing key included.
enum InfoPlistSwitch {
    static func isOn(_ value: Any?) -> Bool {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        guard let text = value as? String else { return false }
        return ["yes", "true", "1"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Everything an engine touches outside its own memory. Live values come from `EngineEnvironment.live()`.
struct EngineEnvironment: Sendable {
    var clock: Clock
    var scheduler: Scheduler
    var keychain: KeychainStore
    var files: FileStore
    var makeTransport: @Sendable (_ queue: DispatchQueue, _ userAgent: String) -> HTTPTransport
    var notificationCenter: NotificationCenterClient
    var application: ApplicationClient
    var lifecycle: LifecycleSource
    var makeReachability: @Sendable () -> ReachabilityMonitor
    var deviceFacts: DeviceFactsSource
    var bundle: BundleInfoSource
    var apnsReader: APNsEnvironmentReader
    var appGroupContainer: @Sendable (_ identifier: String) -> URL?
    var logger: SDKLogger
    var random: @Sendable () -> Double
}

/// The resolved configuration of one engine.
struct EngineConfig: Sendable, Equatable {
    var appId: String
    var base: APIBase
    var appGroupIdentifier: String?
    var apnsOverride: SallaPushAPNsEnvironment
    var appVersionOverride: String?
    var autoClearBadge: Bool
    var autoUpdateBadge: Bool
    var clearTagsOnLogout: Bool
    var registerOnInit: Bool
    var openLaunchURLs: Bool
    /// The Info.plist switch `SallaPushLogFullIdentifiers`: the status lines show the full push token and the
    /// customer's id while it is on in the sandbox APNs environment (`showsFullIdentifiers`); otherwise the token's
    /// last 6 characters and no id.
    var logFullIdentifiers: Bool

    /// `<appId>/<hostTag>`: the folder of this engine's files.
    var folder: String { "\(appId)/\(base.hostTag)" }
}

/// What an engine reports to the runtime.
protocol EngineHost: AnyObject, Sendable {
    /// The getter snapshot changed (main engine only). `baseline` marks the state the engine loaded from disk, published
    /// once before it handles any call.
    func engine(_ engine: Engine, didPublish snapshot: EngineSnapshot, baseline: Bool)
    /// The engine loaded its files and runs with consent, so it takes calls from now on: the calls the runtime kept for
    /// it, in call order, which it handles at once. Empty while the runtime keeps calls for another reason (consent is
    /// withheld, or this is not the current engine).
    func engineAcceptsCalls(_ engine: Engine) -> [SequencedCall]
    /// A call the engine could not handle (it was not taking calls): the runtime keeps it for the engine that will.
    func engine(_ engine: Engine, returned call: PublicCall, sequence: Int)
    /// A login failure to report to observers (main engine only).
    func engine(_ engine: Engine, loginFailed failure: SallaPushLoginFailure)
    /// The engine completed its stop protocol.
    func engineDidStop(_ engine: Engine)
    /// The app came to the foreground (also while consent is pending or withdrawn).
    func engineEnteredForeground(_ engine: Engine)
    /// The sequence of a permission read that starts now; a read started later wins.
    func permissionReadStarted() -> Int
    /// Runs `change`, a change of the device credentials shared with the extension, when `engine` is the runtime's
    /// current engine (running or paused), and returns what it returned; nil, without running it, otherwise. The check
    /// and the change are one step, serialized with every other change of that item: an engine the runtime switched
    /// away from learns that it drains only at a later turn of its queue, and must not undo what the new one shared.
    func changeExtensionCredentials<Result>(by engine: Engine, _ change: () -> Result) -> Result?
    /// Runs `change` on the app's badge keeper when `engine` is the runtime's current engine (running or paused); does
    /// nothing otherwise. The check and the change are one step, as for the extension's credentials.
    func changeBadge(by engine: Engine, _ change: (BadgeKeeper) -> Void)
}

/// A weak reference to an engine that can cross queues: a system callback may hold it long after the engine stopped.
final class WeakEngine: @unchecked Sendable {
    weak var value: Engine?

    init(_ value: Engine) {
        self.value = value
    }
}

/// One engine per (app id, API host). It owns one serial queue; every mutable property is touched only there.
/// Public calls enqueue and return; getters read the snapshot the engine publishes.
final class Engine: @unchecked Sendable {
    enum Mode: Equatable {
        /// The engine of the current app id.
        case main
        /// Finishes another app id's pending logout from an earlier session; never registers.
        case drainOnly
    }

    enum Phase: Equatable {
        case created, loading, waitingForProtectedData, running, stopped
    }

    /// Consent gating of a running engine.
    enum ConsentMode: Equatable {
        case normal
        /// Consent is required and not given: no network, and nothing is written but `consent.json`, except the one
        /// minimised state a withdrawal saves before its requests.
        case paused
        /// Consent was withdrawn: the final data-minimising requests run, then the engine goes idle.
        case withdrawing
    }

    enum TimerPurpose: Hashable {
        case pump, tokenMissing, delegateCheck, drainDeadline, inboxRecheck
    }

    /// The request in flight; at most one per engine.
    struct InFlight {
        enum Kind {
            case register(fields: DeviceFields, fingerprint: String?)
            /// `sendsToken`: the body carries `push_token` (it differs from the registered one).
            case update(fields: DeviceFields, sendsToken: Bool, fingerprint: String?, heartbeat: Bool)
            /// A request of an identity op: its tag clearing, its link or its unlink.
            case identity(opId: Int)
            /// `mirrorResets`: `tagMirrorResets` when the request was sent; an answer that predates a reset of the
            /// mirror (a logout or a login of another customer that clears the tags) never repopulates it.
            case tags(add: [String: PendingTagAdd], remove: [String: Int], mirrorResets: Int)
            case events(keys: [String])
            case withdrawal(WithdrawalStep)
        }

        let id: Int
        let kind: Kind
        let startedAt: Double
        var handle: HTTPTaskHandle?
    }

    /// The final requests of a consent withdrawal (in memory only): the opt-out, the removal of the device's tags and
    /// the unlink.
    enum WithdrawalStep: Equatable {
        case optOut, clearTags, unlink
    }

    static let dayInSeconds: Double = 86_400
    /// The re-registration valve: a device-level re-registration within this time of the previous one
    /// waits until this long after it.
    static let reregisterInterval: Double = 3_600
    static let debounce: Double = 1
    static let tagsDebounce: Double = 10
    static let eventsDebounce: Double = 5
    static let eventsBatch = 50
    /// Retry-bookkeeping id of the in-memory withdrawal requests.
    static let withdrawalRetryId = -2

    let config: EngineConfig
    let mode: Mode
    let queue: DispatchQueue
    let env: EngineEnvironment
    weak var host: EngineHost?

    var logger: SDKLogger { env.logger }

    // MARK: State (engine queue only)

    var phase: Phase = .created
    var generation = 0
    var isDraining = false
    /// The app initialized this engine's app id and host again while it drained: it stops as soon as nothing is in
    /// flight, and the new main engine takes over its files (one engine per folder).
    var isHandingOver = false
    var consentMode: ConsentMode = .normal
    /// The consent mode a pause, withdrawal or resumption asked for before the files were loaded: nothing exists yet to
    /// pause or minimise, so it is applied when the load ends, before any start-up work.
    var consentAfterLoad: ConsentMode = .normal
    /// A withdrawal was asked for before the files were loaded; it runs on them when the load ends, also when consent
    /// came back meanwhile.
    var withdrawsAfterLoad = false
    /// The start-up work of the load (registering for remote notifications, timers, the inbox, the foreground work) waits
    /// for consent: it runs when consent is given.
    var startupPending = false
    var storageAvailable = true
    var keychainAvailable = true

    var identity: IdentityState
    var state: DeviceState
    var events = EventsState()
    var seenEvents: Set<String> = []
    var identityDirty = false
    var stateDirty = false
    var eventsDirty = false
    var lastPublished: EngineSnapshot?
    /// The status the last status line showed (`StatusLog.swift`); nil until `status.launch`.
    var lastLoggedStatus: EngineStatus?

    var credentials: Credentials?
    /// Credentials a registration answered while consent was withdrawn: they live in memory only (while consent is
    /// withheld nothing is written but `consent.json`, except the one minimised state a withdrawal saves before its
    /// requests) and reach the Keychain once consent is given again.
    var credentialsUnsaved = false

    /// The identity token of the app's last `login`, with the customer it is for. Memory only: never written or logged.
    /// It links that customer, and links them again after a re-registration in this process.
    var identityToken: IdentityToken?
    /// The last refusal of the app's current login, kept until a link succeeds, a `logout()`, or a `login` of another
    /// customer or with another token. Memory only, as `identityToken`.
    var refusedLogin: RefusedLogin?
    var epoch = 1
    /// A login that may have reached the server left the op log without a usable answer: a request of its link failed in
    /// transit, timed out, was cancelled or got an unreadable 2xx (a later answered error does not undo that), and a
    /// later call replaced it, its token was refused, or none was in memory. The next logout then unlinks and is
    /// confirmed 60 s later, as when that login is still queued. Memory only, as on Android.
    var unknownOutcomeLogin = false
    /// The sequence of the last public call handled (published to the runtime's pending-intent overlay).
    var callSequence = 0
    var nextOpId = 1
    /// Incremented whenever the tag mirror is reset by an identity change.
    var tagMirrorResets = 0

    /// The fields of the last register or update the server accepted in this process (`update.sent` names changes).
    var lastSentFields: DeviceFields?
    var permission: PermissionStatus?
    /// The sequence of the read that produced `permission`.
    var permissionSequence = 0
    var permissionReadInFlight = false
    var permissionReadAgain = false
    /// An `optIn()` permission prompt (or the status read before it) is in progress.
    var permissionPromptInFlight = false
    var apnsEnvironment: APNsEnvironment?

    var transport: HTTPTransport?
    var client: APIClient?
    var inFlight: InFlight?
    var requestCounter = 0
    var processAttempts: [Int: Int] = [:]
    var exhausted: Set<Int> = []
    var reachability: ReachabilityMonitor?
    /// When the last device-level re-registration runs: now, or the end of its hold. Restored at start
    /// from a hold persisted on the register op.
    var lastReregisterAt: Double?

    var lifecycleSubscription: LifecycleSubscription?
    var appState: AppState = .active
    /// The application state read when the engine started, before any lifecycle event.
    var launchState: AppState = .active
    /// The app came to the foreground (or became active) while the engine was still loading.
    var foregroundWhileLoading = false
    /// A lifecycle event set `appState` before the engine's application-state read answered.
    var lifecycleWhileLoading = false
    var isBackgroundLaunch = false
    /// How the engine launched: `isBackgroundLaunch` as the load set it, never cleared (the label of `status.launch`).
    var launchedInBackground = false
    var handledFirstActive = false
    /// The missing-delegate check ran (once per engine, 2 s after the first activation).
    var checkedDelegate = false
    var backgroundTaskToken: BackgroundTaskToken?
    var timers: [TimerPurpose: DispatchWorkItem] = [:]
    /// When the armed pump wake-up fires; it is re-armed only for an earlier time.
    var armedWakeAt: Double?
    var startedAt: Double = 0
    var hasReportedTokenMissing = false
    /// Why the OS last failed to register for remote notifications (`didFailToRegisterForRemoteNotifications`), until a
    /// token arrives: `token.missing` then names it instead of advising to forward a token the OS never gave.
    var registrationFailure: String?
    var hasReportedNoAppGroup = false

    var eventsRetry = RetryState()
    let eventsRetryId = -1
    var forceEventFlush = false
    var firstPendingEventAt: Double?
    /// `events.queue_full` was logged for the episode under way: the queue stayed full since (memory only).
    var queueFullReported = false
    var tagsSplitMode = false
    /// When the last tags request was sent (memory only); in the foreground the next one waits 10 s after it.
    var lastTagsRequestAt: Double?
    /// The tags the app set in this launch while the identity is unknown (first launch, reinstall), at most 100: the
    /// launch `logout()` keeps those the getters still show. Memory only; read only while it is unknown.
    var launchTags: [String: String] = [:]

    var withdrawalSteps: [WithdrawalStep] = []
    /// Whether the steps of the consent withdrawal under way were decided. They are decided once nothing is on the wire,
    /// so a registration or a login that was in flight at the withdrawal counts once it is answered (as on Android).
    var withdrawalDecided = false
    /// Consent was withdrawn in this process and not given again since: when it is, the state in memory becomes what
    /// the withdrawal wrote, as if its requests took effect.
    var withdrawnInThisProcess = false
    var withdrawalRetry = RetryState()
    /// The keys the withdrawal's tag removal sends: every key SallaPush held at the withdrawal, then the keys the server
    /// still held. Empty: no key is known, and the answer names the keys the server holds.
    var withdrawalTagKeys: [String] = []
    /// The withdrawal's tag removal sends the keys the server still held: its last request.
    var withdrawalTagsRechecked = false
    /// What the consent withdrawal achieved, for `consent.revoked`.
    var withdrawalOutcome = WithdrawalOutcome()

    /// - Parameter withdrawsConsent: the engine starts to carry out a consent withdrawal for an app whose
    ///   consent was withdrawn while no engine ran: it loads its files, sends the data-minimising requests and goes idle.
    init(config: EngineConfig, mode: Mode, environment: EngineEnvironment, host: EngineHost?, withdrawsConsent: Bool = false) {
        self.config = config
        self.mode = mode
        env = environment
        self.host = host
        queue = DispatchQueue(label: mode == .main ? "com.salla.push.engine" : "com.salla.push.engine.drain",
                              qos: .utility)
        identity = IdentityState(appId: config.appId, apiBaseURL: config.base.string)
        state = DeviceState(appId: config.appId)
        if withdrawsConsent {
            withdrawsAfterLoad = true
            consentAfterLoad = .withdrawing
        }
    }

    // MARK: - Entry points (any thread)

    /// Hands a public call, made at `sequence`, to the engine queue.
    func submit(_ call: PublicCall, sequence: Int) {
        queue.async { [self] in
            perform { $0.handle(call, sequence: sequence) }
        }
    }

    /// Runs `body` on the engine queue, then persists, publishes and pumps, and logs the status when the turn changed it
    /// (the pump's changes included).
    func perform(_ body: @escaping @Sendable (Engine) -> Void) {
        if phase == .stopped { return }
        body(self)
        if phase == .stopped { return }
        commit()
        pump()
        logStatusIfChanged()
    }

    /// Runs `body` on the engine queue at the next turn.
    func async(_ body: @escaping @Sendable (Engine) -> Void) {
        queue.async { [self] in perform(body) }
    }

    // MARK: - Calls

    func handle(_ call: PublicCall, sequence: Int) {
        guard phase == .running, consentMode == .normal, mode == .main, !isDraining else {
            // The runtime hands a call only to an engine that takes calls, and stops before it pauses, withdraws or
            // drains it, so this is not expected; a call that gets here anyway is kept for the engine that takes it.
            if phase != .stopped, mode == .main {
                host?.engine(self, returned: call, sequence: sequence)
            }
            return
        }
        callSequence = max(callSequence, sequence)
        let now = env.clock.now()
        switch call {
        case let .pushToken(token): handlePushToken(token, now: now)
        case let .registrationFailed(reason): handleRegistrationFailure(reason)
        case let .login(externalId, token): handleLogin(externalId: externalId, token: token, now: now)
        case .logout: handleLogout(now: now)
        case let .addTags(tags): handleAddTags(tags, now: now)
        case let .removeTags(keys): handleRemoveTags(keys, now: now)
        case let .setLanguage(language): handleSetLanguage(language, now: now)
        case .optIn: handleOptIn(now: now)
        case .optOut: handleOptOut(now: now)
        case let .events(records): recordEvents(records, now: now)
        case .refreshPermission: readPermission()
        }
    }

    // MARK: - Persistence and publishing

    var identityPath: String { config.folder + "/identity.json" }
    var statePath: String { config.folder + "/state.json" }
    var eventsPath: String { config.folder + "/events.json" }
    var credentialsAccount: String { KeychainStore.credentialsAccount(appId: config.appId, hostTag: config.base.hostTag) }

    /// Writes dirty files and publishes the snapshot.
    func commit() {
        guard phase == .running else { return }
        persist()
        publish()
    }

    /// Writes dirty files atomically. Nothing is written while consent is not given or storage is unavailable, except
    /// the one minimised state a withdrawal saves before its requests (`persistCopies`). A failed write is
    /// logged once per file and launch; the file stays dirty, so the next change writes it again. `state.json` goes
    /// first: the tag changes an identity call dropped or marked reach disk no later than the op that clears or switches
    /// the customer, so a crash between the two writes never sends them to the wrong customer.
    func persist() {
        guard storageAvailable, consentMode == .normal else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if stateDirty, let data = try? encoder.encode(state) {
            stateDirty = !write(data, to: statePath, name: "state.json")
        }
        if identityDirty, let data = try? encoder.encode(identity) {
            identityDirty = !write(data, to: identityPath, name: "identity.json")
        }
        if eventsDirty, let data = try? encoder.encode(events) {
            eventsDirty = !write(data, to: eventsPath, name: "events.json")
        }
    }

    /// Writes the given copies of the state, the identity and the events whatever the consent mode, in the order of
    /// `persist()`. The in-memory values stay dirty, so consent given again writes them over these copies.
    func persistCopies(state stateCopy: DeviceState, identity identityCopy: IdentityState) {
        guard storageAvailable else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(stateCopy) { _ = write(data, to: statePath, name: "state.json") }
        if let data = try? encoder.encode(identityCopy) { _ = write(data, to: identityPath, name: "identity.json") }
        if let data = try? encoder.encode(events) { _ = write(data, to: eventsPath, name: "events.json") }
        stateDirty = true
        identityDirty = true
        eventsDirty = true
    }

    private func write(_ data: Data, to path: String, name: String) -> Bool {
        if env.files.write(path, data: data) { return true }
        logger.logOnce(.storageFailed, key: "write.\(path)",
                       "Could not write SallaPush state (\(name)); the change is kept in memory and written again on the "
                           + "next change.")
        return false
    }

    /// The getter view of this engine, with what decides how it handles the next login or logout, so the getters
    /// anticipate a call the way it will be handled.
    var snapshot: EngineSnapshot {
        EngineSnapshot(deviceId: credentials?.deviceId,
                       token: state.push.token,
                       permission: permission,
                       permissionSequence: permissionSequence,
                       userOptedOut: state.push.userOptedOut,
                       externalId: identity.desired == .customer ? identity.desiredExternalId : nil,
                       isLoggedIn: identity.desired == .customer,
                       tokenExternalId: identity.desired == .customer && identity.desiredExternalId == nil
                           ? identityToken?.externalId : nil,
                       tags: state.tags.effective,
                       launchTags: identity.desired == .unknown ? keptLaunchTags : nil,
                       callSequence: callSequence,
                       logoutIsFree: guestLogoutIsFree,
                       logoutSends: logoutUnlinks || logoutClearsTags)
    }

    /// Publishes the snapshot when it changed. The first publish of a main engine is the `baseline`: the state it
    /// loaded, before any call or answer changed it.
    func publish(baseline: Bool = false) {
        guard mode == .main, !isDraining else { return }
        let current = snapshot
        guard current != lastPublished || baseline else { return }
        lastPublished = current
        host?.engine(self, didPublish: current, baseline: baseline)
    }

    func reportLoginFailure(_ failure: SallaPushLoginFailure) {
        guard mode == .main, !isDraining else { return }
        host?.engine(self, loginFailed: failure)
    }

    /// The metadata of a failure entry: route, HTTP status, error code, request id and reason, plus the app id (as on
    /// Android), so telemetry that collects several apps can tell them apart.
    func failureMetadata(_ error: APIError) -> [String: String] {
        var metadata = error.metadata
        metadata[LogMetadataKey.appId] = config.appId
        return metadata
    }

    // MARK: - Timers

    /// Schedules `action` for `purpose`, replacing any earlier item of that purpose. Stale items are no-ops.
    func schedule(_ purpose: TimerPurpose, after seconds: Double, _ action: @escaping @Sendable (Engine) -> Void) {
        timers[purpose]?.cancel()
        let expectedGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.phase != .stopped, self.generation == expectedGeneration else { return }
            self.timers[purpose] = nil
            if purpose == .pump { self.armedWakeAt = nil }
            self.perform(action)
        }
        timers[purpose] = item
        env.scheduler.schedule(after: Duration.clamped(seconds), on: queue, item)
    }

    func cancelTimer(_ purpose: TimerPurpose) {
        timers[purpose]?.cancel()
        timers[purpose] = nil
        if purpose == .pump { armedWakeAt = nil }
    }

    // MARK: - Requests

    /// Marks a request as in flight and returns its id.
    func beginRequest(_ kind: InFlight.Kind, now: Double) -> Int {
        requestCounter += 1
        inFlight = InFlight(id: requestCounter, kind: kind, startedAt: now, handle: nil)
        return requestCounter
    }

    /// Attaches the task of a started request. A nil handle means the transport refused to start it
    /// (it was invalidated); the request is then treated as a transient failure.
    func attach(_ handle: HTTPTaskHandle?, to requestId: Int, now: Double) {
        guard let current = inFlight, current.id == requestId else { return }
        if let handle {
            inFlight?.handle = handle
            return
        }
        inFlight = nil
        guard phase != .stopped else { return }
        let failure = APIError(kind: .cancelled, route: route(of: current.kind), detail: "request not started")
        applyTransientFailure(failure, to: current.kind, now: now)
    }

    /// The route a request kind uses, for logging.
    func route(of kind: InFlight.Kind) -> Route {
        let deviceId = credentials?.deviceId ?? ""
        switch kind {
        case .register: return .register(appId: config.appId)
        case .update: return .update(deviceId: deviceId)
        case let .identity(opId):
            let op = identityOp(id: opId)
            if op?.clearsTagsNext ?? false { return .tags(deviceId: deviceId) }
            return op?.kind == .login ? .link(deviceId: deviceId) : .unlink(deviceId: deviceId)
        case .tags: return .tags(deviceId: deviceId)
        case .events: return .events(deviceId: deviceId)
        case let .withdrawal(step):
            switch step {
            case .optOut: return .update(deviceId: deviceId)
            case .clearTags: return .tags(deviceId: deviceId)
            case .unlink: return .unlink(deviceId: deviceId)
            }
        }
    }

    /// The API client, created lazily with this engine's transport.
    func apiClient() -> APIClient? {
        if let client { return client }
        guard phase != .stopped else { return nil }
        let userAgent = URLSessionTransport.userAgent(sdkVersion: sallaPushSDKVersion,
                                                      osVersion: env.deviceFacts.osVersion(),
                                                      model: env.deviceFacts.deviceModel())
        let transport = env.makeTransport(queue, userAgent)
        self.transport = transport
        let created = APIClient(base: config.base, transport: transport, clock: env.clock)
        client = created
        return created
    }

    /// Wraps a completion so it runs on the engine queue, only for the live request of this generation.
    func completion<Value: Sendable>(for requestId: Int,
                                     _ handler: @escaping @Sendable (Engine, APIResult<Value>, InFlight) -> Void)
        -> @Sendable (APIResult<Value>) -> Void {
        let expectedGeneration = generation
        return { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.phase != .stopped, self.generation == expectedGeneration,
                      let current = self.inFlight, current.id == requestId else { return }
                self.inFlight = nil
                self.perform { engine in handler(engine, result, current) }
            }
        }
    }
}
