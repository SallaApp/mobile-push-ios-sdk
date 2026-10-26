import Foundation
import SallaPushCore

/// The fields of the update fingerprint: SHA-256 of their canonical JSON.
private struct FingerprintFields: Encodable {
    let pushToken: String
    let apnsEnv: String
    let optedIn: Bool
    let appVersion: String?
    let sdkVersion: String?
    let osVersion: String?
    let deviceModel: String?
    let language: String?
    let timezone: String?

    private enum CodingKeys: String, CodingKey {
        case language, timezone
        case pushToken = "push_token"
        case apnsEnv = "apns_env"
        case optedIn = "opted_in"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
    }
}

/// The device fields a register or update request sent, so `update.sent` can name what changed since.
struct DeviceFields: Equatable, Sendable {
    let token: String
    let environment: APNsEnvironment
    let optedIn: Bool
    let metadata: DeviceMetadata

    /// The contract names of the fields that differ from `previous`.
    func changes(since previous: DeviceFields) -> [String] {
        var names: [String] = []
        if token != previous.token { names.append("push_token") }
        if environment != previous.environment { names.append("apns_env") }
        if optedIn != previous.optedIn { names.append("opted_in") }
        if metadata.appVersion != previous.metadata.appVersion { names.append("app_version") }
        if metadata.sdkVersion != previous.metadata.sdkVersion { names.append("sdk_version") }
        if metadata.osVersion != previous.metadata.osVersion { names.append("os_version") }
        if metadata.deviceModel != previous.metadata.deviceModel { names.append("device_model") }
        if metadata.language != previous.metadata.language { names.append("language") }
        if metadata.timezone != previous.metadata.timezone { names.append("timezone") }
        return names
    }
}

extension Engine {
    // MARK: - Device facts

    /// The APNs environment, read once and lazily on the engine queue.
    var currentEnvironment: APNsEnvironment {
        if let apnsEnvironment { return apnsEnvironment }
        let resolved = env.apnsReader.environment(override: config.apnsOverride)
        apnsEnvironment = resolved
        return resolved
    }

    /// Device metadata, trimmed and truncated to the server limits in UTF-16 units.
    var currentMetadata: DeviceMetadata {
        let appVersion = config.appVersionOverride ?? env.bundle.shortVersion
        return DeviceMetadata(
            appVersion: FieldLimit.normalize(appVersion, max: FieldLimit.appVersion),
            sdkVersion: FieldLimit.normalize(sallaPushSDKVersion, max: FieldLimit.sdkVersion),
            osVersion: FieldLimit.normalize(env.deviceFacts.osVersion(), max: FieldLimit.osVersion),
            deviceModel: FieldLimit.normalize(env.deviceFacts.deviceModel(), max: FieldLimit.deviceModel),
            language: FieldLimit.normalize(state.push.language ?? env.deviceFacts.preferredLanguage(),
                                           max: FieldLimit.language),
            timezone: FieldLimit.normalize(env.deviceFacts.timeZone(), max: FieldLimit.timezone))
    }

    /// `permission && !optedOut && token`.
    var currentOptedIn: Bool {
        (permission?.isGranted ?? false) && !state.push.userOptedOut && state.push.token != nil
    }

    /// The fingerprint of every device field the server stores.
    func fingerprint(token: String, environment: APNsEnvironment, optedIn: Bool, metadata: DeviceMetadata) -> String? {
        Fingerprint.canonical(FingerprintFields(
            pushToken: token, apnsEnv: environment.rawValue, optedIn: optedIn,
            appVersion: metadata.appVersion, sdkVersion: metadata.sdkVersion, osVersion: metadata.osVersion,
            deviceModel: metadata.deviceModel, language: metadata.language, timezone: metadata.timezone))
    }

    var currentFingerprint: String? {
        guard let token = state.push.token else { return nil }
        return fingerprint(token: token, environment: currentEnvironment, optedIn: currentOptedIn, metadata: currentMetadata)
    }

    // MARK: - Token

    func handlePushToken(_ token: PushToken, now: Double) {
        readPermission()
        registrationFailure = nil
        if state.push.token == token.hex {
            logger.log(.tokenUnchanged, "Same push token; permission re-checked.")
            return
        }
        logger.log(.tokenReceived, "Push token received (\(token)).")
        state.push.token = token.hex
        stateDirty = true
        cancelTimer(.tokenMissing)
        if credentials == nil {
            ensureStateOp(.register, nextAt: now + Self.debounce)
        } else {
            maybeEnqueueUpdate(now: now)
        }
    }

    func handleRegistrationFailure(_ reason: String) {
        registrationFailure = reason
        logger.log(.tokenRegistrationFailed, "The OS could not register for remote notifications: \(reason).")
    }

    // MARK: - Keychain

    func keychainLocked() {
        logger.logOnce(.storageKeychainLocked, key: "keychain.locked.\(config.folder)",
                       "Keychain unavailable until first unlock (errSecInteractionNotAllowed); waiting.")
    }

    func keychainUnavailable(status: OSStatus) {
        keychainAvailable = false
        logger.log(.storageFailed,
                   "Could not read SallaPush state (Keychain status \(status)); this launch runs without network registration.")
    }

    // MARK: - Register

    /// Whether the registration may run now.
    func canRegister(now: Double) -> Bool {
        guard keychainAvailable, state.push.token != nil, permission != nil else { return false }
        if state.registration.status == .dormant, (state.registration.dormantUntil ?? 0) > now { return false }
        if isBackgroundLaunch && identity.ops.isEmpty { return false }
        return true
    }

    /// Sends the registration with the device fields push-service stores. Each registration gets a new device, and
    /// push-service disables the device that held the token before.
    func sendRegister(now: Double) {
        guard let token = state.push.token else { return }
        guard let client = apiClient() else { return }
        if state.registration.status == .dormant {
            state.registration.status = .none
            state.registration.dormantUntil = nil
            state.registration.dormantReason = nil
        }
        let environment = currentEnvironment
        let metadata = currentMetadata
        let optedIn = currentOptedIn
        let body = RegisterBody(pushToken: token, apnsEnv: environment.rawValue, optedIn: optedIn, metadata: metadata)
        let sentFingerprint = fingerprint(token: token, environment: environment, optedIn: optedIn, metadata: metadata)
        updateStateOp(.register) { $0.retry.lastAttemptAt = now }
        let fields = DeviceFields(token: token, environment: environment, optedIn: optedIn, metadata: metadata)
        let requestId = beginRequest(.register(fields: fields, fingerprint: sentFingerprint), now: now)
        let handle = client.register(appId: config.appId, body: body,
                                     completion: completion(for: requestId) { engine, result, request in
                                         engine.registerAnswered(result, request: request)
                                     })
        attach(handle, to: requestId, now: now)
    }

    func registerAnswered(_ result: APIResult<RegisterResponse>, request: InFlight) {
        let now = env.clock.now()
        guard case let .register(fields, sentFingerprint) = request.kind else { return }
        switch result {
        case let .success(success):
            let answer = success.value
            storeCredentials(deviceId: answer.deviceId, secret: answer.deviceSecret)
            state.lastDeviceId = answer.deviceId
            state.registration.status = .registered
            state.registration.registeredToken = fields.token
            state.registration.registeredEnv = fields.environment
            state.registration.sentFingerprint = sentFingerprint
            lastSentFields = fields
            state.registration.lastFullUpdateAt = now
            state.registration.dormantUntil = nil
            state.registration.dormantReason = nil
            stateDirty = true
            removeStateOp(.register)
            removeStateOp(.update)
            let milliseconds = max(Int(((now - request.startedAt) * 1_000).rounded()), 0)
            logger.log(.registerOk, "Device registered: \(answer.deviceId) in \(milliseconds) ms.",
                       metadata: [LogMetadataKey.deviceId: answer.deviceId, LogMetadataKey.appId: config.appId])
            afterRegistration(now: now)
            if state.push.token != fields.token {
                maybeEnqueueUpdate(now: now)
            }
            stopReachabilityIfIdle()
        case let .failure(error):
            registerFailed(error, request: request, now: now)
        }
    }

    private func storeCredentials(deviceId: String, secret: SecretString) {
        let answered = Credentials(deviceId: deviceId, secret: secret)
        credentials = answered
        // While consent is withheld nothing is written but consent.json, except the one minimised state a withdrawal
        // saves before its requests: a registration that was on the wire at a withdrawal keeps its
        // credentials in memory, for the withdrawal's own requests, until consent is given again.
        guard consentMode == .normal else {
            credentialsUnsaved = true
            return
        }
        credentialsUnsaved = false
        saveCredentials(answered)
        syncExtensionCredentials()
    }

    /// Writes the credentials item of this (app id, API host): device id and secret together, never split.
    func saveCredentials(_ credentials: Credentials) {
        let stored = StoredCredentials(appId: config.appId, apiHost: config.base.origin,
                                       deviceId: credentials.deviceId, deviceSecret: credentials.secret.revealed)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        switch env.keychain.write(account: credentialsAccount, data: data) {
        case .success:
            break
        case .locked:
            keychainLocked()
        case let .failed(status):
            logger.log(.storageFailed,
                       "Could not store SallaPush credentials (Keychain status \(status)); the next launch registers again.")
        }
    }

    /// The registration failures push-service answers, matched on status and error code: `404 not_found` (no SDK routes
    /// at the base URL) and `404 unknown_app` wait 24 h, each with its own message. A
    /// 4xx without a code (a proxy's or an edge's JSON error) is no answer of the push service and is retried with
    /// backoff, never taken as a final one.
    private func registerFailed(_ error: APIError, request: InFlight, now: Double) {
        switch (error.kind, error.status, error.code) {
        case (.http, 404, "not_found"):
            dormantRegistration(.notFound, error: error, now: now,
                                code: .registerDormant,
                                message: "SallaPush is unavailable (HTTP 404 not_found\(requestText(error))). "
                                    + "App \(config.appId) registers when it is back. Next try in 24 h.")
        case (.http, 404, "unknown_app"):
            dormantRegistration(.unknownApp, error: error, now: now,
                                code: .registerDormant,
                                message: "SallaPush is not available for app \(config.appId) "
                                    + "(HTTP 404 unknown_app\(requestText(error))). Check the app id. Next try in 24 h.")
        default:
            // Any other client error (400 invalid_request, another code) is dormant 24 h, as on Android.
            if error.isClientError {
                dormantRegistration(.invalidRequest, error: error, now: now, code: .netClientError,
                                    message: rejectedText(error))
                return
            }
            applyTransientFailure(error, to: request.kind, now: now)
        }
    }

    private func requestText(_ error: APIError) -> String {
        error.requestId.map { ", request \($0)" } ?? ""
    }

    private func rejectedText(_ error: APIError) -> String {
        "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); retrying in 24 h."
    }

    private func dormantRegistration(_ reason: DormantReason, error: APIError, now: Double, code: LogCode, message: String) {
        state.registration.status = .dormant
        state.registration.dormantReason = reason
        state.registration.dormantUntil = now + Self.dayInSeconds
        stateDirty = true
        // The registration status holds the 24 h wait; the register op's own dormancy is only its own retry wait, as on
        // Android, so a restart never mistakes one for the other.
        updateStateOp(.register) { op in
            op.retry.recordAttempt()
            op.retry.lastFailure = .client
        }
        logger.logOnce(code, key: "dormant.\(config.folder).\(reason.rawValue)", message, metadata: failureMetadata(error))
    }

    /// Ends a dormancy that ran out: the device is registered again (or unregistered), and an update that waited
    /// for it goes now.
    func clearExpiredDormancy(now: Double) {
        guard state.registration.status == .dormant, (state.registration.dormantUntil ?? 0) <= now else { return }
        state.registration.status = credentials == nil ? .none : .registered
        state.registration.dormantUntil = nil
        state.registration.dormantReason = nil
        stateDirty = true
        maybeEnqueueUpdate(now: now)
    }

    // MARK: - Update

    /// Whether the 24 h heartbeat is due. A last update in the future (clock moved back) counts as due.
    func heartbeatDue(now: Double) -> Bool {
        guard let last = state.registration.lastFullUpdateAt else { return true }
        if last > now { return true }
        return now - last >= Self.dayInSeconds
    }

    /// Enqueues one coalesced update when a device field changed or the heartbeat is due. Never while consent is
    /// withheld: an answer that lands during a withdrawal queues nothing (consent given again checks once more).
    func maybeEnqueueUpdate(now: Double) {
        guard mode == .main, !isDraining, phase == .running, consentMode == .normal, credentials != nil,
              permission != nil else { return }
        guard state.registration.status == .registered, !isBackgroundLaunch,
              let current = currentFingerprint else { return }
        if current != state.registration.sentFingerprint || heartbeatDue(now: now) {
            ensureStateOp(.update, nextAt: now + Self.debounce)
        }
    }

    func sendUpdate(now: Double) {
        guard let credentials, let token = state.push.token, let client = apiClient() else {
            removeStateOp(.update)
            return
        }
        let environment = currentEnvironment
        let metadata = currentMetadata
        let optedIn = currentOptedIn
        let sentFingerprint = fingerprint(token: token, environment: environment, optedIn: optedIn, metadata: metadata)
        let heartbeat = sentFingerprint == state.registration.sentFingerprint
        let sendsToken = token != state.registration.registeredToken
        let body = UpdateBody(pushToken: sendsToken ? token : nil, apnsEnv: environment.rawValue, optedIn: optedIn,
                              metadata: metadata)
        updateStateOp(.update) { $0.retry.lastAttemptAt = now }
        let fields = DeviceFields(token: token, environment: environment, optedIn: optedIn, metadata: metadata)
        let requestId = beginRequest(.update(fields: fields, sendsToken: sendsToken, fingerprint: sentFingerprint,
                                             heartbeat: heartbeat), now: now)
        let handle = client.update(deviceId: credentials.deviceId, secret: credentials.secret, body: body,
                                   completion: completion(for: requestId) { engine, result, request in
                                       engine.updateAnswered(result, request: request)
                                   })
        attach(handle, to: requestId, now: now)
    }

    func updateAnswered(_ result: APIResult<UpdateResponse>, request: InFlight) {
        let now = env.clock.now()
        guard case let .update(fields, sendsToken, sentFingerprint, heartbeat) = request.kind else { return }
        switch result {
        case .success:
            if sendsToken { state.registration.registeredToken = fields.token }
            state.registration.registeredEnv = fields.environment
            state.registration.sentFingerprint = sentFingerprint
            state.registration.lastFullUpdateAt = now
            stateDirty = true
            removeStateOp(.update)
            if heartbeat {
                logger.log(.heartbeatSent, "Daily device refresh sent.")
            } else {
                logger.log(.updateSent, "Device updated (\(updateDescription(fields))).")
            }
            lastSentFields = fields
            maybeEnqueueUpdate(now: now)
            stopReachabilityIfIdle()
        case let .failure(error):
            if handleDeviceRouteFailure(error, now: now) { return }
            if error.isClientError {
                updateStateOp(.update) { op in
                    op.retry.recordAttempt()
                    op.retry.lastFailure = .client
                    op.retry.dormantUntil = now + Self.dayInSeconds
                }
                logger.log(.netClientError,
                           "\(error.route.method) \(error.route.template) was rejected (\(error.summary)); retrying in 24 h.",
                           metadata: failureMetadata(error))
                return
            }
            applyTransientFailure(error, to: request.kind, now: now)
        }
    }

    /// What an update changed, for `update.sent`: the fields that differ from the last ones the server accepted in this
    /// process. Before the first of those, only the persisted fingerprint is known, so it says so.
    private func updateDescription(_ fields: DeviceFields) -> String {
        guard let previous = lastSentFields else { return "first update since launch: a device field changed since the last one" }
        let changes = fields.changes(since: previous)
        return changes.isEmpty ? "every field sent again" : changes.joined(separator: ", ")
    }

    // MARK: - Language, opt-in

    func handleSetLanguage(_ language: String?, now: Double) {
        let normalized = FieldLimit.normalize(language, max: FieldLimit.language)
        guard normalized != state.push.language else { return }
        state.push.language = normalized
        stateDirty = true
        maybeEnqueueUpdate(now: now)
    }

    /// Clears the opt-out, and prompts when the permission was never asked. The status is read
    /// from the system for this call, so an `optIn()` made before or right after `initialize`, before the first
    /// permission read, still prompts.
    func handleOptIn(now: Double) {
        if state.push.userOptedOut {
            state.push.userOptedOut = false
            stateDirty = true
            logger.log(.subscriptionOptedIn, "optIn(): this device receives SallaPush notifications again.")
            maybeEnqueueUpdate(now: now)
        }
        guard !permissionPromptInFlight else { return }
        permissionPromptInFlight = true
        let expectedGeneration = generation
        let engine = WeakEngine(self)
        env.notificationCenter.authorizationStatus { status in
            // System callbacks arrive on the notification center's queue: engine state is read on the engine queue.
            engine.value?.queue.async {
                guard let current = engine.value, current.phase == .running, current.generation == expectedGeneration
                else { return }
                guard status == .notDetermined else {
                    current.permissionPromptInFlight = false
                    return
                }
                current.promptForPermission()
            }
        }
    }

    private func promptForPermission() {
        let expectedGeneration = generation
        let engine = WeakEngine(self)
        env.notificationCenter.requestAuthorization(provisional: false) { _ in
            engine.value?.queue.async {
                guard let current = engine.value, current.phase != .stopped, current.generation == expectedGeneration
                else { return }
                current.perform { engine in
                    engine.permissionPromptInFlight = false
                    engine.readPermission()
                }
            }
        }
    }

    func handleOptOut(now: Double) {
        guard !state.push.userOptedOut else { return }
        state.push.userOptedOut = true
        stateDirty = true
        logger.log(.subscriptionOptedOut, "optOut(): this device stops receiving SallaPush notifications.")
        maybeEnqueueUpdate(now: now)
    }
}
