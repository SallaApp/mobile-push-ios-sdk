@_exported import SallaPushCore
import Foundation
import UserNotifications
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// SallaPush, Salla's push notification SDK.
///
/// Every method can be called from any thread, before or after `initialize`; none throws, blocks on I/O or
/// crashes on bad input, except an object of another class than declared, passed by Objective-C or bridge code.
/// Call `initialize` in `application(_:didFinishLaunchingWithOptions:)`. Call `login(externalId:identityToken:)` after
/// the customer signs in and at each launch while they're signed in, and `logout()` after they sign out and at each
/// launch while nobody is.
@objc(SallaPush)
public final class SallaPush: NSObject {
    private override init() {
        super.init()
    }

    #if canImport(UIKit) && os(iOS)
    /// Starts SallaPush for `appId` (for example `00000000-0000-4000-8000-000000000001`) with the default
    /// configuration. Returns at once; all work runs on a background queue. A second call with the same app id does
    /// nothing; one with another app id switches to it. A first call with an invalid app id disables SallaPush for this
    /// process: later calls, `initialize` included, are ignored (WARN `api.invalid_argument`, logged once); an invalid
    /// app id after a valid one is ignored. `launchOptions` is accepted and not used.
    @available(iOSApplicationExtension, unavailable)
    @objc(initialize:withLaunchOptions:)
    public static func initialize(_ appId: String,
                                  withLaunchOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
        Runtime.shared.initialize(appId: appId, configuration: SallaPushConfiguration())
    }

    /// Starts SallaPush for `appId` with `configuration` (copied). A second call with the same app id does nothing; one
    /// with another app id switches to it, and the previous app finishes its pending logout before it stops. A first
    /// call with an invalid app id disables SallaPush for this process: later calls, `initialize` included, are ignored
    /// (WARN `api.invalid_argument`, logged once); an invalid app id after a valid one is ignored. `launchOptions` is
    /// accepted and not used.
    @available(iOSApplicationExtension, unavailable)
    @objc(initialize:withLaunchOptions:configuration:)
    public static func initialize(_ appId: String,
                                  withLaunchOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
                                  configuration: SallaPushConfiguration) {
        Runtime.shared.initialize(appId: appId, configuration: configuration)
    }
    #endif

    /// True once a valid `initialize` started SallaPush; false before, and for the whole process after an invalid first
    /// app id.
    @objc public static var isInitialized: Bool { Runtime.shared.isInitialized }

    /// The SDK version, for example `1.1.0`.
    @objc public static var sdkVersion: String { sallaPushSDKVersion }

    /// The app id SallaPush runs with; nil before a valid `initialize`, and after an invalid first one.
    @objc public static var appId: String? { Runtime.shared.appId }

    /// Requires `setConsentGiven(true)` before SallaPush sends anything or stores anything but the consent answer.
    /// `false` lowers only what an earlier `true` raised; it never lowers `requiresUserConsent`.
    @objc public static func setConsentRequired(_ required: Bool) {
        Runtime.shared.setConsentRequired(required)
    }

    /// Records the user's consent (persisted). Withdrawing it (when consent is required) saves SallaPush's state once,
    /// minimised, then sends one data-minimising opt-out and logout, and SallaPush goes idle: until consent is given
    /// again, nothing else is written but the consent answer.
    @objc public static func setConsentGiven(_ given: Bool) {
        Runtime.shared.setConsentGiven(given)
    }

    /// Links this device to the customer `externalId` (the Salla user id, 1-128 characters), proven by `identityToken`
    /// (the customer token your app received from Salla at sign-in, a JWT whose subject is `externalId`).
    /// Call it at sign-in and at every launch while signed in. The token is kept in memory only, never stored or
    /// logged; a token Salla refuses is reported to the login failure observers (`.tokenRejected`). An empty or longer
    /// id, or an empty token, is ignored (WARN `api.invalid_argument`).
    @objc public static func login(externalId: String, identityToken: String) {
        Runtime.shared.login(externalId: externalId, identityToken: identityToken)
    }

    /// Unlinks the customer (the device stays registered as a guest). Works without a token and offline. Call it at
    /// sign-out and at every launch while signed out.
    @objc public static func logout() {
        Runtime.shared.logout()
    }

    /// The user: tags, language, login state and the push subscription.
    @objc public static var User: SallaPushUser { SallaPushUser.shared }

    /// Notifications: permission, token forwarding, delegate forwarding and listeners.
    @objc public static var Notifications: SallaPushNotifications { SallaPushNotifications.shared }

    /// Logging: levels and the log handler.
    @objc public static var Debug: SallaPushDebug { SallaPushDebug.shared }
}

// MARK: - Runtime

/// The process-wide SDK state behind the static facade: the pre-init buffer, consent gating, the current engine,
/// draining engines, the getter snapshot and the observers. Public calls validate cheap arguments on the caller
/// thread and enqueue; everything else runs on the control queue or an engine queue.
final class Runtime: EngineHost, @unchecked Sendable {
    private static let current = Locked<Runtime?>(nil)

    /// The runtime of the process, created on first use with the live environment.
    static var shared: Runtime {
        current.withLock { runtime in
            if let runtime { return runtime }
            let created = Runtime(environment: .live())
            runtime = created
            return created
        }
    }

    /// Replaces the runtime of the process (dependency injection for tests). The replaced runtime is released after
    /// the lock, so nothing it owns can deinit inside it.
    static func install(_ runtime: Runtime) {
        let replaced = current.exchange(runtime)
        withExtendedLifetime(replaced) {}
    }

    enum Phase {
        case idle
        case starting
        case waitingForConsent(EngineConfig)
        case running(Engine)
        case paused(Engine)
        case invalid
    }

    /// The options of the configuration in effect: the first valid `initialize`, then each one that is not a
    /// duplicate (another app id or API host).
    struct AppliedOptions {
        var openLaunchURLs: Bool
        var registerOnInit: Bool
        var autoClearBadge: Bool
        var autoUpdateBadge: Bool
    }

    struct State {
        var phase: Phase = .idle
        var buffer = PreInitBuffer()
        var appId: String?
        var isInitialized = false
        var options: AppliedOptions?
        var consentRequiredByCall = false
        var consentRequiredByConfiguration = false
        var drainEngines: [Engine] = []
        /// The draining engines told to stop because consent was withheld, until they stopped.
        var stoppingForConsent: Set<ObjectIdentifier> = []
        /// Main engines waiting for the draining engine of their folder to stop, by folder.
        var successors: [String: Engine] = [:]
        /// The sequence of the last public call, assigned under this lock in routing order.
        var callSequence = 0
        /// Whether the running engine takes calls: it loaded its files and runs with consent. Until then calls wait in
        /// `buffer`, and the engine takes them, in call order, when it can (`engineAcceptsCalls`).
        var engineAccepts = false
        /// The sequence of the last call handed to an engine.
        var routedThrough = 0
    }

    let environment: RuntimeEnvironment
    var logger: SDKLogger { environment.logger }
    let controlQueue = DispatchQueue(label: "com.salla.push.control", qos: .utility)
    let observers = ObserverHub()
    let router: NotificationRouter
    /// SallaPush's part of the app icon badge.
    let badge: BadgeKeeper
    /// Every change of the badge keeper's settings takes it, with the check of the engine that makes it
    /// (`Badge.swift`). Taken before `state`, never with `extensionCredentialsLock`.
    let badgeLock = NSLock()

    /// Locks are taken in this order only: `extensionCredentialsLock`, then `state`, then `view`.
    let state = Locked(State())
    let view = Locked(GetterView())
    private let permissionReads = Locked(0)
    /// Every change of the device credentials shared with the extension takes it, with the check of the engine that
    /// makes it (`ExtensionShare.swift`). Held across that Keychain call on purpose, never while calling the app.
    let extensionCredentialsLock = NSLock()
    /// Runs when a change finds `extensionCredentialsLock` taken, just before it waits for it: a test learns there
    /// that the change waits, instead of guessing how long that takes. Never set in an app.
    let onExtensionCredentialsLockWait = Locked<(@Sendable () -> Void)?>(nil)

    // Control queue only.
    private var engineEnvironmentStorage: EngineEnvironment?
    /// The consent answer in effect: the app's in this process, else the one `consent.json` holds; nil when none is known.
    var consentGiven: Bool?
    /// Whether `consent.json` was read (it may have been unreadable so far).
    var consentLoaded = false
    /// The app's last `setConsentGiven` answer in this process.
    var appConsentAnswer: Bool?
    /// Whether the app answered `setConsentGiven(true)` in this process.
    var appGaveConsent = false
    /// A consent answer whose write failed, or waits for the file to be read; written at the next consent call,
    /// `initialize` or foreground.
    var pendingConsentWrite: Bool?
    /// Consent that was given was withdrawn, and the withdrawal has not started yet.
    var withdrawalPending = false
    /// Watches for `consent.json` to become readable.
    var consentFileWatch: LifecycleSubscription?

    init(environment: RuntimeEnvironment) {
        self.environment = environment
        router = NotificationRouter(logger: environment.logger, clock: environment.clock,
                                    notificationCenter: environment.notificationCenter,
                                    application: environment.application)
        badge = BadgeKeeper(notificationCenter: environment.notificationCenter, application: environment.application,
                            clock: environment.clock, logger: environment.logger)
        router.runtime = self
    }

    // MARK: - Getters

    var isInitialized: Bool { state.withLock { $0.isInitialized } }
    var appId: String? { state.withLock { $0.appId } }
    /// What the getters show: the engine's state with every call it has not handled yet applied.
    var snapshot: EngineSnapshot { view.withLock { $0.resolved() } }
    var openLaunchURLs: Bool { state.withLock { $0.options?.openLaunchURLs ?? false } }
    /// What `willPresent` answers for a SallaPush notification it shows: without `.badge` while `autoClearBadge` is on,
    /// so the app icon doesn't change while the app is open; all four options before `initialize`.
    var foregroundOptions: UNNotificationPresentationOptions {
        let clears = state.withLock { $0.options?.autoClearBadge ?? false }
        return clears ? NotificationRouter.defaultOptions.subtracting(.badge) : NotificationRouter.defaultOptions
    }

    /// The engine of the current app id, if it is running.
    var currentEngine: Engine? {
        state.withLock { state in
            switch state.phase {
            case let .running(engine), let .paused(engine): return engine
            default: return nil
            }
        }
    }

    /// Engines finishing another app id's pending logout.
    var drainingEngines: [Engine] { state.withLock { $0.drainEngines } }

    // MARK: - Calls

    /// Hands a call to the engine when it takes calls, else keeps it in the bounded buffer until one does (before
    /// `initialize`, while the engine loads, while consent is withheld). The getters reflect it at once.
    func submit(_ call: PublicCall) {
        let intent = PendingIntent(call)
        let delivered: Bool = state.withLock { state in
            if case .invalid = state.phase { return false }
            state.callSequence = state.callSequence.saturatingIncrement
            let sequence = state.callSequence
            if case let .running(engine) = state.phase, state.engineAccepts {
                // Recorded before the engine can handle the call, so the publish that covers it settles it.
                if let intent { view.withLock { $0.append(sequence: sequence, intent: intent) } }
                state.routedThrough = sequence
                engine.submit(call, sequence: sequence)
            } else {
                let removed = state.buffer.append(call, sequence: sequence)
                view.withLock { view in
                    if let intent { view.append(sequence: sequence, intent: intent) }
                    view.remove(sequences: removed)
                }
            }
            return true
        }
        if !delivered {
            logDisabled("A SallaPush call")
        }
    }

    /// Says once that SallaPush does nothing in this process: its first `initialize` had an invalid app id (as
    /// on Android).
    private func logDisabled(_ what: String) {
        logger.logOnce(.apiInvalidArgument, key: "disabled",
                       "\(what) was ignored: SallaPush is disabled for this process because initialize received an "
                           + "invalid app id.")
    }

    func login(externalId: String, identityToken: String) {
        let customer = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IdentityRules.isExternalId(customer) else {
            logger.log(.apiInvalidArgument, "login ignored: the external id must be 1-128 characters.")
            return
        }
        let token = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IdentityRules.isIdentityToken(token) else {
            logger.log(.apiInvalidArgument, "login ignored: the identity token must be 1-4096 characters.")
            return
        }
        submit(.login(externalId: customer, token: SecretString(token)))
    }

    func logout() {
        submit(.logout)
    }

    /// Whether `value`, a nonnull object parameter of `call`, is nil: Objective-C, React Native and Flutter callers can
    /// pass one, and using it would crash. The call is then logged (WARN `api.invalid_argument`) and ignored.
    func isNilArgument<Value>(_ value: Value, of call: String, _ parameter: String) -> Bool {
        guard isNullReference(value) else { return false }
        logger.log(.apiInvalidArgument, "\(call) ignored: the \(parameter) is nil.")
        return true
    }

    func addTags(_ tags: [String: String]) {
        if tags.keys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            logger.log(.apiInvalidArgument, "addTag ignored: the key is empty.")
        }
        let usable = tags.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }
        submit(.addTags(usable))
    }

    func removeTags(_ keys: [String]) {
        let usable = keys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if usable.count != keys.count {
            logger.log(.apiInvalidArgument, "removeTag ignored: the key is empty.")
        }
        guard !usable.isEmpty else { return }
        submit(.removeTags(usable))
    }

    // MARK: - Logging controls

    /// `SallaPush.Debug.logLevel`; a value outside the declared levels is ignored.
    func setRuntimeLogLevel(_ level: SallaPushLogLevel) {
        guard let valid = level.validated else {
            logger.log(.apiInvalidArgument, "logLevel \(level.rawValue) is not a SallaPushLogLevel value; ignored.")
            return
        }
        logger.setRuntimeLevel(valid)
    }

    /// `SallaPush.Debug.setLogHandler`; a level outside the declared levels becomes `.warn`.
    func setLogHandler(level: SallaPushLogLevel, _ handler: SDKLogger.Handler?) {
        logger.setHandler(level: level.validated ?? .warn, handler)
        if level.validated == nil {
            logger.log(.apiInvalidArgument, "setLogHandler level \(level.rawValue) is not a SallaPushLogLevel value; .warn is used.")
        }
    }

    // MARK: - Initialize

    /// What an `initialize` call does.
    private enum InitializeOutcome {
        /// A valid app id: SallaPush starts, or switches to it.
        case starts
        /// The first call, with an invalid app id: SallaPush stays disabled for the process.
        case disables
        /// An invalid app id after a valid one: ignored, the running app id goes on (`running`).
        case ignored(running: String)
        /// SallaPush is disabled for the process: every later call is a logged no-op.
        case disabled
    }

    func initialize(appId: String, configuration: SallaPushConfiguration) {
        let (copied, warnings) = Self.sanitizedCopy(of: configuration)
        let valid = Validation.isAppId(appId)
        let (outcome, dropped): (InitializeOutcome, PreInitBuffer?) = state.withLock { state in
            if case .invalid = state.phase { return (.disabled, nil) }
            guard valid else {
                if let running = state.appId { return (.ignored(running: running), nil) }
                // An invalid app id leaves SallaPush idle, and every later call is a logged no-op, a
                // valid initialize included (as on Android). The calls kept until now are never applied.
                state.phase = .invalid
                let kept = state.buffer
                state.buffer = PreInitBuffer()
                return (.disables, kept)
            }
            state.isInitialized = true
            state.appId = appId
            if state.options == nil {
                // The first valid call applies its options at once, so a tap forwarded right after it already sees
                // them; a later call applies them on the control queue unless it is a duplicate.
                state.options = AppliedOptions(openLaunchURLs: copied.openLaunchURLs,
                                               registerOnInit: copied.registerForRemoteNotificationsOnInit,
                                               autoClearBadge: copied.autoClearBadge, autoUpdateBadge: copied.autoUpdateBadge)
                if copied.requiresUserConsent { state.consentRequiredByConfiguration = true }
                view.withLock { $0.setClearTagsOnLogout(copied.clearTagsOnLogout) }
            }
            if case .idle = state.phase { state.phase = .starting }
            return (.starts, nil)
        }
        if var dropped {
            // The getters stop showing calls that will never be applied; released after the lock.
            let calls = dropped.drain().calls
            view.withLock { $0.remove(sequences: calls.map(\.sequence)) }
        }
        let boxed = UncheckedSendable(copied)
        controlQueue.async { [self] in
            let shown = LogSanitizer.clean(String(appId.prefix(80)))
            switch outcome {
            case .starts:
                // Only a configuration that is used is checked aloud: an ignored initialize is a no-op.
                for warning in warnings { logger.log(.apiInvalidArgument, warning) }
                processInitialize(appId: appId, configuration: boxed.value)
            case .disables:
                logger.log(.initInvalidAppId,
                           "App id \"\(shown)\" is invalid (expected 1-64 chars A-Z, a-z, 0-9, _, -); SallaPush stays disabled.")
            case let .ignored(running):
                logger.log(.initInvalidAppId,
                           "App id \"\(shown)\" is invalid (expected 1-64 chars A-Z, a-z, 0-9, _, -); this initialize was "
                               + "ignored; SallaPush keeps running for app \(running).")
            case .disabled:
                logDisabled("initialize")
            }
        }
    }

    /// A copy of `configuration` whose enum properties hold declared cases: Objective-C and bridge callers can store
    /// any integer in them, and an exhaustive switch over an undeclared value traps; they can also pass nil, which
    /// becomes the default configuration. Returns a warning per fix.
    private static func sanitizedCopy(of configuration: SallaPushConfiguration) -> (SallaPushConfiguration, [String]) {
        guard !isNullReference(configuration) else {
            return (SallaPushConfiguration(), ["initialize: the configuration is nil; the default configuration is used."])
        }
        let copied = (configuration.copy() as? SallaPushConfiguration) ?? SallaPushConfiguration()
        var warnings: [String] = []
        let environment = copied.apnsEnvironment
        if SallaPushAPNsEnvironment(rawValue: environment.rawValue) == nil {
            warnings.append("apnsEnvironment \(environment.rawValue) is not a SallaPushAPNsEnvironment value; .automatic is used.")
            copied.apnsEnvironment = .automatic
        }
        if copied.logLevelIsExplicit, copied.logLevel.validated == nil {
            warnings.append("logLevel \(copied.logLevel.rawValue) is not a SallaPushLogLevel value; ignored.")
            copied.resetLogLevel()
        }
        return (copied, warnings)
    }

    /// The engine environment, created once on the control queue.
    func engineEnvironment() -> EngineEnvironment {
        if let engineEnvironmentStorage { return engineEnvironmentStorage }
        let created = environment.makeEngineEnvironment()
        engineEnvironmentStorage = created
        return created
    }

    /// The API base: the built-in production URL, or a valid `apiBaseURL`, which only the SDK's own tests set.
    private func resolveBase(_ configuration: SallaPushConfiguration) -> APIBase {
        configuration.apiBaseURL.flatMap { APIBase.validated($0) } ?? .production
    }

    /// The configuration of the running, paused or waiting engine.
    private var currentConfig: EngineConfig? {
        state.withLock { state in
            switch state.phase {
            case let .running(engine), let .paused(engine): return engine.config
            case let .waitingForConsent(config): return config
            case .idle, .starting, .invalid: return nil
            }
        }
    }

    private func processInitialize(appId: String, configuration: SallaPushConfiguration) {
        retryConsentWriteIfNeeded()
        let base = resolveBase(configuration)
        // A second call with the same app id and API host changes nothing.
        if let current = currentConfig, current.appId == appId, current.base == base {
            logger.log(.initStarted, "SallaPush is already initialized with app \(appId); this call changes nothing.",
                       metadata: [LogMetadataKey.appId: appId])
            return
        }
        state.withLock { state in
            state.options = AppliedOptions(openLaunchURLs: configuration.openLaunchURLs,
                                           registerOnInit: configuration.registerForRemoteNotificationsOnInit,
                                           autoClearBadge: configuration.autoClearBadge,
                                           autoUpdateBadge: configuration.autoUpdateBadge)
            if configuration.requiresUserConsent { state.consentRequiredByConfiguration = true }
            view.withLock { $0.setClearTagsOnLogout(configuration.clearTagsOnLogout) }
        }
        logger.setConfigurationLevel(configuration.logLevelIsExplicit ? configuration.logLevel : nil)
        logger.primePlistLevel()
        let group = (configuration.appGroupIdentifier ?? environment.bundle.string(forInfoKey: "SallaPushAppGroup"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let config = EngineConfig(appId: appId, base: base,
                                  appGroupIdentifier: (group?.isEmpty ?? true) ? nil : group,
                                  apnsOverride: configuration.apnsEnvironment,
                                  appVersionOverride: configuration.appVersion,
                                  autoClearBadge: configuration.autoClearBadge,
                                  autoUpdateBadge: configuration.autoUpdateBadge,
                                  clearTagsOnLogout: configuration.clearTagsOnLogout,
                                  registerOnInit: configuration.registerForRemoteNotificationsOnInit,
                                  openLaunchURLs: configuration.openLaunchURLs,
                                  logFullIdentifiers: environment.bundle.isOn(infoKey: "SallaPushLogFullIdentifiers"))

        let phase = state.withLock { $0.phase }
        if case let .running(engine) = phase {
            switchAway(from: engine, to: config)
        } else if case let .paused(engine) = phase {
            switchAway(from: engine, to: config)
        }

        logger.log(.initStarted,
                   "SallaPush \(sallaPushSDKVersion) initializing (app \(appId), "
                       + "apns_env \(Self.name(of: configuration.apnsEnvironment)), log \(logger.consoleLevel.name))",
                   metadata: [LogMetadataKey.appId: appId])

        seedPermission()
        loadConsentIfNeeded()
        if consentRequired && consentGiven != true {
            if withdrawalPending {
                // Consent that was given was withdrawn while no engine ran: an engine starts only to carry out the
                // withdrawal on this app's files, then stays idle until consent is given.
                withdrawalPending = false
                startEngine(config, withdrawingConsent: true)
                return
            }
            state.withLock { $0.phase = .waitingForConsent(config) }
            forgetExtensionCredentials()
            if consentLoaded { forgetBadge(of: config) }
            logConsentWaiting()
            return
        }
        startEngine(config)
    }

    private static func name(of environment: SallaPushAPNsEnvironment) -> String {
        switch SallaPushAPNsEnvironment(rawValue: environment.rawValue) ?? .automatic {
        case .automatic: return "auto"
        case .sandbox: return "sandbox"
        case .production: return "production"
        }
    }

    // MARK: - EngineHost

    /// Stamps a permission read as it starts: of two reads, the getters keep the one that started last.
    func permissionReadStarted() -> Int {
        permissionReads.withLock { reads in
            reads = reads.saturatingIncrement
            return reads
        }
    }
}
