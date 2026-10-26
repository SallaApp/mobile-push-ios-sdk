import Foundation
import SallaPushCore

/// What the status lines say (`status.launch`, `status.changed`): how this device stands with SallaPush, each field as
/// the lines show it, built from the engine's memory only. It holds no secret: the device secret and the identity token
/// are never read. The push token shows its last 6 characters and the customer no id, unless the app's Info.plist turns
/// on the debug switch `SallaPushLogFullIdentifiers` in the sandbox APNs environment (`showsFullIdentifiers`). Attempt
/// counts, retry times, tags and events are left out, so a retry, a tags call or an events flush changes nothing.
struct EngineStatus: Equatable, Sendable {
    /// The push-service device id, or `none`.
    var device: String
    /// `registered`, `dormant (<reason>) until <time>`, `registering`, `re-registering`, `retrying after a <kind>
    /// failure`, or `not registered`, with what keeps the device from registering when something does.
    var registration: String
    /// The push token as `…` and its last 6 characters, or in full (lowercase hex) with `showsFullIdentifiers`; or
    /// `none`.
    var pushToken: String
    /// `none`, `not sent yet` or `registered with the server` (push-service has the token in `apnsEnvironment`).
    var pushTokenStatus: String
    /// `sandbox` or `production`.
    var apnsEnvironment: String
    /// The permission the engine read last, or `not read yet`.
    var permission: String
    /// The `opted_in` push-service is sent.
    var optedIn: Bool
    /// The app's `optOut()`, until its `optIn()`.
    var userOptedOut: Bool
    /// The customer the app logged in, with what SallaPush knows of their link: `id hidden (linked)`, or their id, quoted,
    /// with `showsFullIdentifiers` (`"<id>" (linked)`); or `guest`, `guest (logout pending)` or `guest (no login yet)`.
    var customer: String
    /// Whether `customer` names a customer: the app logged one in.
    var signedIn: Bool
    /// The language the app set, quoted, or `device default`.
    var language: String
    /// While consent is withheld: `paused` or `withdrawing`; nil otherwise.
    var consent: String?

    /// `status.launch`: every field, after the SDK version, how the app launched and the app id.
    func launchLine(appId: String, background: Bool) -> String {
        let customerText = signedIn ? "customer \(customer)" : customer
        let consentText = consent.map { "; consent \($0)" } ?? ""
        return "SallaPush \(sallaPushSDKVersion) status at launch (\(background ? "background" : "foreground")): "
            + "app \(appId); device \(device) (\(registration)); push token \(pushToken) (\(pushTokenStatus), "
            + "apns_env \(apnsEnvironment)); permission \(permission); opted_in \(optedIn) (user opted out: "
            + "\(userOptedOut)); \(customerText); language \(language)\(consentText)."
    }

    /// `status.changed`: each field that differs from `previous`, as `<field> <old> → <new>`, in line order.
    func changes(since previous: EngineStatus) -> String {
        let changed = zip(previous.fields, fields).compactMap { old, new in
            old.value == new.value ? nil : "\(new.name) \(old.value) → \(new.value)"
        }
        return "SallaPush status changed: \(changed.joined(separator: "; "))."
    }

    /// The fields in line order, named as `status.changed` names them.
    private var fields: [(name: String, value: String)] {
        [("device", device), ("registration", registration), ("push token", pushToken),
         ("push token status", pushTokenStatus), ("apns_env", apnsEnvironment), ("permission", permission),
         ("opted_in", String(optedIn)), ("user opted out", String(userOptedOut)), ("customer", customer),
         ("language", language), ("consent", consent ?? "normal")]
    }
}

extension Engine {
    // MARK: - Status lines

    /// Logs `status.launch` once the status is complete, then `status.changed` at the end of every turn that changed it.
    /// The status is complete once the engine read the notification permission, or at once while consent is withheld,
    /// which keeps it from reading one. Main engine only, while it runs and does not drain (the guard of `publish()`):
    /// drain engines and the Notification Service Extension never log one.
    func logStatusIfChanged() {
        guard phase == .running, mode == .main, !isDraining else { return }
        guard lastLoggedStatus != nil || permission != nil || consentMode != .normal else { return }
        let current = currentStatus
        guard current != lastLoggedStatus else { return }
        let previous = lastLoggedStatus
        lastLoggedStatus = current
        guard let previous else {
            logger.log(.statusLaunch, current.launchLine(appId: config.appId, background: launchedInBackground),
                       metadata: statusMetadata)
            return
        }
        logger.log(.statusChanged, current.changes(since: previous), metadata: statusMetadata)
    }

    /// The status now, from memory only (`currentEnvironment` reads the provisioning profile once, then caches it).
    var currentStatus: EngineStatus {
        let token = state.push.token
        let environment = currentEnvironment
        let registration = state.registration
        let tokenStatus: String
        if token == nil {
            tokenStatus = "none"
        } else {
            tokenStatus = credentials != nil && registration.registeredToken == token && registration.registeredEnv == environment
                ? "registered with the server" : "not sent yet"
        }
        return EngineStatus(device: credentials?.deviceId ?? "none",
                            registration: registrationText,
                            pushToken: token.map { showsFullIdentifiers ? $0 : PushToken(hex: $0).description } ?? "none",
                            pushTokenStatus: tokenStatus,
                            apnsEnvironment: environment.rawValue,
                            permission: permission?.name ?? "not read yet",
                            optedIn: currentOptedIn,
                            userOptedOut: state.push.userOptedOut,
                            customer: customerText,
                            signedIn: identity.desired == .customer,
                            language: state.push.language.map { "\"\(LogSanitizer.clean($0))\"" } ?? "device default",
                            consent: consentText)
    }

    /// Whether the status lines show the full push token and the customer's id: the Info.plist switch
    /// `SallaPushLogFullIdentifiers`, honoured only in the sandbox APNs environment (the simulator and builds signed
    /// with a development profile), so that a TestFlight, ad hoc or App Store build never shows them.
    private var showsFullIdentifiers: Bool {
        config.logFullIdentifiers && currentEnvironment == .sandbox
    }

    /// The metadata of a status line: the app id, and the device id once known.
    private var statusMetadata: [String: String] {
        var metadata = [LogMetadataKey.appId: config.appId]
        metadata[LogMetadataKey.deviceId] = credentials?.deviceId
        return metadata
    }

    /// How the device stands with push-service, coarsely: no attempt count, retry time or backoff (`net.retry` logs
    /// those), so a retry that fails again changes nothing.
    private var registrationText: String {
        let registration = state.registration
        switch registration.status {
        case .dormant:
            let reason = registration.dormantReason.map { " (\($0.rawValue))" } ?? ""
            let until = registration.dormantUntil.map { " until \(ISO8601.string(from: $0))" } ?? ""
            return "dormant\(reason)\(until)"
        case .tokenDead:
            return "token dead"
        case .none, .registered:
            break
        }
        if credentials != nil { return "registered" }
        if let blocker = registrationBlocker { return "not registered (\(blocker))" }
        guard let op = stateOp(.register) else { return "not registered" }
        if let failure = op.retry.lastFailure { return "retrying after a \(failure.rawValue) failure" }
        return state.lastDeviceId == nil ? "registering" : "re-registering"
    }

    /// What keeps a device without credentials from registering now: the pump's conditions (consent, storage), then
    /// those of `canRegister(now:)` (the Keychain, the token, the permission, a background launch); nil when none does.
    private var registrationBlocker: String? {
        if consentMode != .normal { return "consent not given" }
        if !storageAvailable { return "storage unavailable" }
        if !keychainAvailable { return "Keychain unavailable" }
        if state.push.token == nil { return "no push token yet" }
        if permission == nil { return "permission not read yet" }
        if isBackgroundLaunch && identity.ops.isEmpty { return "background launch" }
        return nil
    }

    /// The customer the app logged in, with what SallaPush knows of their link: their id, quoted, only with
    /// `showsFullIdentifiers`, else `id hidden`; or the guest.
    private var customerText: String {
        switch identity.desired {
        case .unknown:
            return "guest (no login yet)"
        case .guest:
            return hasPendingUnlinkingOp ? "guest (logout pending)" : "guest"
        case .customer:
            // A consent withdrawal forgets the customer's id, and an earlier (pre-release) version saved none.
            let externalId = identity.desiredExternalId
            let shown = externalId.map { showsFullIdentifiers ? "\"\(LogSanitizer.clean($0))\"" : "id hidden" }
                ?? "id unknown"
            return "\(shown) (\(linkText(of: externalId)))"
        }
    }

    /// What SallaPush knows of the link of the customer `externalId`: `linked` (the server linked them and no unlink is
    /// pending, the test of `handleLogin`), `login pending`, `login refused`, `link unknown` or `not linked`.
    private func linkText(of externalId: String?) -> String {
        if let externalId, identity.serverLink == .linked, identity.linkedExternalId == externalId, !hasPendingUnlinkingOp {
            return "linked"
        }
        if let externalId, loginOp(for: externalId) != nil { return "login pending" }
        if refusedLogin != nil { return "login refused" }
        return identity.serverLink == .unknown ? "link unknown" : "not linked"
    }

    /// The consent mode while consent is withheld; nil while it is not.
    private var consentText: String? {
        switch consentMode {
        case .normal: return nil
        case .paused: return "paused"
        case .withdrawing: return "withdrawing"
        }
    }
}
