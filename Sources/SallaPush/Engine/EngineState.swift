import Foundation
import SallaPushCore

// The persisted schemas, frozen: apps keep these files across updates. Optional fields are written as explicit
// `null`.

/// The identity the app asserted last.
enum DesiredIdentity: String, Codable, Sendable {
    case unknown, guest, customer
}

/// What SallaPush knows about this device row's link: none after a registration or a confirmed unlink, linked after a
/// confirmed link, unknown otherwise (a reinstall that kept the credentials, a request without a usable answer).
enum ServerLink: String, Codable, Sendable {
    case unknown, none, linked
}

/// What the SDK knows about the device's server-side tags.
enum ServerTags: String, Codable, Sendable {
    case unknown, none, some
}

/// Identity operation kinds: a login links the device; a logout and its confirmation unlink it.
enum IdentityOpKind: String, Codable, Sendable {
    case login, logout
    case logoutConfirm = "logout_confirm"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // An earlier (pre-release) version queued an unlink of a link the app didn't make; it is an unlink as a
        // logout's is.
        guard let kind = raw == "unlink" ? .logout : IdentityOpKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown kind")
        }
        self = kind
    }
}

/// Why an operation's last attempt failed.
enum FailureKind: String, Codable, Sendable {
    case network, server, client
    case rateLimited = "rate_limited"
}

/// Bounds of the integers read from the persisted files. A file is written only by this SDK, so a value outside
/// them means the file is corrupt or was tampered with: decoding fails and the file is set aside.
enum PersistedInteger {
    /// Op ids and identity epochs: `0...2^53`, far beyond what a device ever reaches.
    static let maximumCounter = 1 << 53
    /// Attempt counts are clamped here when read and when counted.
    static let maximumAttempts = 10_000

    /// Decodes a counter (op id or epoch) and checks its range.
    static func counter<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> Int {
        let value = try container.decode(Int.self, forKey: key)
        try check(value, key: key, in: container)
        return value
    }

    /// Throws `DecodingError.dataCorrupted` when `value` is outside `0...maximumCounter`.
    static func check<Key: CodingKey>(_ value: Int, key: Key, in container: KeyedDecodingContainer<Key>) throws {
        guard (0...maximumCounter).contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "out of range")
        }
    }

    /// Throws `DecodingError.dataCorrupted` when the tag epoch `value` is outside `-maximumCounter...maximumCounter`
    /// (a negative epoch is a "previous customer" mark of an earlier (pre-release) version, see `TagState`).
    static func checkTagEpoch<Key: CodingKey>(_ value: Int, key: Key, in container: KeyedDecodingContainer<Key>) throws {
        guard (-maximumCounter...maximumCounter).contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "out of range")
        }
    }

    /// Decodes an attempt count, clamped to `0...maximumAttempts`.
    static func attempts<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> Int {
        let value = try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        return min(max(value, 0), maximumAttempts)
    }
}

extension Int {
    /// `self + 1`, or `self` at `Int.max`: counters never trap.
    var saturatingIncrement: Int {
        self < .max ? self + 1 : self
    }
}

/// Retry bookkeeping shared by every persisted operation.
struct RetryState: Equatable, Sendable {
    var attempts = 0
    var nextAt: Double = 0
    var lastAttemptAt: Double = 0
    var lastFailure: FailureKind?
    var dormantUntil: Double?

    /// Counts one attempt, saturating at `PersistedInteger.maximumAttempts`.
    mutating func recordAttempt() {
        attempts = min(attempts, PersistedInteger.maximumAttempts - 1) + 1
    }
}

/// One identity operation of `identity.json`.
struct IdentityOp: Codable, Equatable, Sendable {
    var id: Int
    var kind: IdentityOpKind
    /// The customer a login links.
    var externalId: String?
    /// The device's tags go before the link or unlink: a logout, or a login of another customer, with
    /// `clearTagsOnLogout`. It keeps the value it was queued with, so a later identity call knows what the op covers.
    var clearTags: Bool
    /// The keys the next tags request of the op removes: every key SallaPush held when the op was queued, then the keys
    /// the server still held. Empty: no key is known, and the answer names the keys the server holds.
    var tagKeys: [String] = []
    /// The tags are cleared: the link or the unlink is left.
    var tagsCleared = false
    /// The request that removes the keys the server still held is the op's last tags request.
    var tagsRechecked = false
    /// A request of the op's link or unlink may have changed the server: one is on the wire, or one got no usable answer
    /// (failed in transit, timed out, was cancelled, or got an unreadable 2xx). An answer that applied nothing restores
    /// the value it had before that request, so it sticks once set by such a failure (as on Android). The collapse
    /// rules never remove a sent op, and a sent login makes the next logout unlink.
    var sent = false
    var retry = RetryState()

    init(id: Int, kind: IdentityOpKind, externalId: String?, clearTags: Bool, tagKeys: [String], nextAt: Double) {
        self.id = id
        self.kind = kind
        self.externalId = externalId
        self.clearTags = clearTags
        self.tagKeys = tagKeys
        retry.nextAt = nextAt
    }

    /// Whether the op's next request removes the device's tags.
    var clearsTagsNext: Bool {
        clearTags && !tagsCleared
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, sent, attempts
        case externalId = "external_id"
        case clearTags = "clear_tags"
        case tagKeys = "tag_keys"
        case tagsCleared = "tags_cleared"
        case tagsRechecked = "tags_rechecked"
        case nextAt = "next_at"
        case lastAttemptAt = "last_attempt_at"
        case lastFailure = "last_failure"
        case dormantUntil = "dormant_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try PersistedInteger.counter(container, .id)
        kind = try container.decode(IdentityOpKind.self, forKey: .kind)
        externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
        clearTags = try container.decodeIfPresent(Bool.self, forKey: .clearTags) ?? false
        tagKeys = try container.decodeIfPresent([String].self, forKey: .tagKeys) ?? []
        tagsCleared = try container.decodeIfPresent(Bool.self, forKey: .tagsCleared) ?? false
        tagsRechecked = try container.decodeIfPresent(Bool.self, forKey: .tagsRechecked) ?? false
        sent = try container.decodeIfPresent(Bool.self, forKey: .sent) ?? false
        retry.attempts = try PersistedInteger.attempts(container, .attempts)
        retry.nextAt = try container.decodeIfPresent(Double.self, forKey: .nextAt) ?? 0
        retry.lastAttemptAt = try container.decodeIfPresent(Double.self, forKey: .lastAttemptAt) ?? 0
        retry.lastFailure = try container.decodeIfPresent(FailureKind.self, forKey: .lastFailure)
        retry.dormantUntil = try container.decodeIfPresent(Double.self, forKey: .dormantUntil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(externalId, forKey: .externalId)
        try container.encode(clearTags, forKey: .clearTags)
        try container.encode(tagKeys, forKey: .tagKeys)
        try container.encode(tagsCleared, forKey: .tagsCleared)
        try container.encode(tagsRechecked, forKey: .tagsRechecked)
        try container.encode(sent, forKey: .sent)
        try container.encode(retry.attempts, forKey: .attempts)
        try container.encode(retry.nextAt, forKey: .nextAt)
        try container.encode(retry.lastAttemptAt, forKey: .lastAttemptAt)
        try container.encode(retry.lastFailure, forKey: .lastFailure)
        try container.encode(retry.dormantUntil, forKey: .dormantUntil)
    }
}

/// `identity.json`: identity state plus the identity op log. Never holds an identity token or the device secret.
///
/// It reads the `identity.json` of an earlier (pre-release) version too, whose customer login went through the Store
/// API: its logins carry no external id, so they are dropped (one that may have reached the server leaves the link
/// unknown), and its token fingerprints, refusals and legacy subscription id are not read. Its logouts and unlinks are
/// logouts, sent as unlinks.
struct IdentityState: Codable, Equatable, Sendable {
    var v = 1
    var appId: String
    var apiBaseURL: String
    var desired: DesiredIdentity = .unknown
    /// The customer the app logged in, while it asserts one; nil while that customer is unknown (a login of
    /// an earlier (pre-release) version, or a consent withdrawal, which forgets it).
    var desiredExternalId: String?
    var serverLink: ServerLink = .unknown
    /// The customer of the link the server confirmed on this row; nil when the row has no link or SallaPush can't name it.
    var linkedExternalId: String?
    var serverTags: ServerTags = .unknown
    var ops: [IdentityOp] = []

    init(appId: String, apiBaseURL: String) {
        self.appId = appId
        self.apiBaseURL = apiBaseURL
    }

    private enum CodingKeys: String, CodingKey {
        case v, desired, ops
        case appId = "app_id"
        case apiBaseURL = "api_base_url"
        case desiredExternalId = "desired_external_id"
        case serverLink = "server_link"
        case linkedExternalId = "linked_external_id"
        case serverTags = "server_tags"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        appId = try container.decode(String.self, forKey: .appId)
        apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        desired = try container.decodeIfPresent(DesiredIdentity.self, forKey: .desired) ?? .unknown
        desiredExternalId = try container.decodeIfPresent(String.self, forKey: .desiredExternalId)
        serverLink = try container.decodeIfPresent(ServerLink.self, forKey: .serverLink) ?? .unknown
        linkedExternalId = try container.decodeIfPresent(String.self, forKey: .linkedExternalId)
        serverTags = try container.decodeIfPresent(ServerTags.self, forKey: .serverTags) ?? .unknown
        let decoded = try container.decodeIfPresent([IdentityOp].self, forKey: .ops) ?? []
        ops = decoded.filter { $0.kind != .login || $0.externalId != nil }
        if serverLink == .none, decoded.contains(where: { $0.kind == .login && $0.externalId == nil && $0.sent }) {
            serverLink = .unknown
        }
    }

    /// Drops every value the SDK could not have written (an external id outside 1-128 characters, one kept while no
    /// customer is asserted or no link is known, a tag key outside `^[a-z0-9_]{1,64}$`) and the logins whose external id is
    /// invalid, which can never be sent. Returns the names of what was dropped.
    mutating func dropInvalidIdentifiers() -> [String] {
        var dropped: [String] = []
        if let id = desiredExternalId, desired != .customer || !IdentityRules.isExternalId(id) {
            desiredExternalId = nil
            dropped.append("desired_external_id")
        }
        if let id = linkedExternalId, serverLink != .linked || !IdentityRules.isExternalId(id) {
            linkedExternalId = nil
            dropped.append("linked_external_id")
        }
        var validOps: [IdentityOp] = []
        for var op in ops {
            if op.kind == .login && !(op.externalId.map(IdentityRules.isExternalId) ?? false) {
                dropped.append("ops.external_id")
                continue
            }
            let keys = op.tagKeys.filter { Validation.isLowerIdentifier($0) }
            if keys.count != op.tagKeys.count {
                op.tagKeys = keys
                dropped.append("ops.tag_keys")
            }
            validOps.append(op)
        }
        ops = validOps
        return dropped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(appId, forKey: .appId)
        try container.encode(apiBaseURL, forKey: .apiBaseURL)
        try container.encode(desired, forKey: .desired)
        try container.encode(desiredExternalId, forKey: .desiredExternalId)
        try container.encode(serverLink, forKey: .serverLink)
        try container.encode(linkedExternalId, forKey: .linkedExternalId)
        try container.encode(serverTags, forKey: .serverTags)
        try container.encode(ops, forKey: .ops)
    }
}

/// The registration status of `state.json`. `token_dead` is only read from a state an earlier (pre-release) version
/// saved; it is upgraded at load.
enum RegistrationStatus: String, Codable, Sendable {
    case none, registered, dormant
    case tokenDead = "token_dead"
}

/// Why registration is dormant.
enum DormantReason: String, Codable, Sendable {
    case unknownApp = "unknown_app"
    case notFound = "not_found"
    case appDisabled = "app_disabled"
    case platformMismatch = "platform_mismatch"
    case appMismatch = "app_mismatch"
    case invalidRequest = "invalid_request"
}

/// `state.json` → `registration`.
struct RegistrationState: Codable, Equatable, Sendable {
    var status: RegistrationStatus = .none
    var registeredToken: String?
    var registeredEnv: APNsEnvironment?
    var sentFingerprint: String?
    var lastFullUpdateAt: Double?
    var dormantUntil: Double?
    var dormantReason: DormantReason?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case status
        case registeredToken = "registered_token"
        case registeredEnv = "registered_env"
        case sentFingerprint = "sent_fingerprint"
        case lastFullUpdateAt = "last_full_update_at"
        case dormantUntil = "dormant_until"
        case dormantReason = "dormant_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(RegistrationStatus.self, forKey: .status) ?? .none
        registeredToken = try container.decodeIfPresent(String.self, forKey: .registeredToken)
        registeredEnv = try container.decodeIfPresent(APNsEnvironment.self, forKey: .registeredEnv)
        sentFingerprint = try container.decodeIfPresent(String.self, forKey: .sentFingerprint)
        lastFullUpdateAt = try container.decodeIfPresent(Double.self, forKey: .lastFullUpdateAt)
        dormantUntil = try container.decodeIfPresent(Double.self, forKey: .dormantUntil)
        dormantReason = try container.decodeIfPresent(DormantReason.self, forKey: .dormantReason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(registeredToken, forKey: .registeredToken)
        try container.encode(registeredEnv, forKey: .registeredEnv)
        try container.encode(sentFingerprint, forKey: .sentFingerprint)
        try container.encode(lastFullUpdateAt, forKey: .lastFullUpdateAt)
        try container.encode(dormantUntil, forKey: .dormantUntil)
        try container.encode(dormantReason, forKey: .dormantReason)
    }
}

/// `state.json` → `push`.
struct PushPreferences: Codable, Equatable, Sendable {
    var token: String?
    var userOptedOut = false
    var language: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case token, language
        case userOptedOut = "user_opted_out"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        userOptedOut = try container.decodeIfPresent(Bool.self, forKey: .userOptedOut) ?? false
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(userOptedOut, forKey: .userOptedOut)
        try container.encode(language, forKey: .language)
    }
}

/// Non-identity operation kinds of `state.json`.
enum StateOpKind: String, Codable, Sendable {
    case register, update, tags
}

/// One non-identity operation of `state.json`; at most one per kind.
struct StateOp: Codable, Equatable, Sendable {
    var id: Int
    var kind: StateOpKind
    var retry = RetryState()

    init(id: Int, kind: StateOpKind, nextAt: Double) {
        self.id = id
        self.kind = kind
        retry.nextAt = nextAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, attempts
        case nextAt = "next_at"
        case lastAttemptAt = "last_attempt_at"
        case lastFailure = "last_failure"
        case dormantUntil = "dormant_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try PersistedInteger.counter(container, .id)
        kind = try container.decode(StateOpKind.self, forKey: .kind)
        retry.attempts = try PersistedInteger.attempts(container, .attempts)
        retry.nextAt = try container.decodeIfPresent(Double.self, forKey: .nextAt) ?? 0
        retry.lastAttemptAt = try container.decodeIfPresent(Double.self, forKey: .lastAttemptAt) ?? 0
        retry.lastFailure = try container.decodeIfPresent(FailureKind.self, forKey: .lastFailure)
        retry.dormantUntil = try container.decodeIfPresent(Double.self, forKey: .dormantUntil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(retry.attempts, forKey: .attempts)
        try container.encode(retry.nextAt, forKey: .nextAt)
        try container.encode(retry.lastAttemptAt, forKey: .lastAttemptAt)
        try container.encode(retry.lastFailure, forKey: .lastFailure)
        try container.encode(retry.dormantUntil, forKey: .dormantUntil)
    }
}

/// `state.json`. Never holds the device secret or an identity token.
struct DeviceState: Codable, Equatable, Sendable {
    var v = 1
    var appId: String
    var lastDeviceId: String?
    var registration = RegistrationState()
    var push = PushPreferences()
    var tags = TagState()
    var ops: [StateOp] = []
    /// Used on Android only; kept for the shared schema.
    var pendingClicks: [String] = []

    init(appId: String) {
        self.appId = appId
    }

    private enum CodingKeys: String, CodingKey {
        case v, registration, push, tags, ops
        case appId = "app_id"
        case lastDeviceId = "last_device_id"
        case pendingClicks = "pending_clicks"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        appId = try container.decode(String.self, forKey: .appId)
        lastDeviceId = try container.decodeIfPresent(String.self, forKey: .lastDeviceId)
        registration = try container.decodeIfPresent(RegistrationState.self, forKey: .registration) ?? RegistrationState()
        push = try container.decodeIfPresent(PushPreferences.self, forKey: .push) ?? PushPreferences()
        tags = try container.decodeIfPresent(TagState.self, forKey: .tags) ?? TagState()
        ops = try container.decodeIfPresent([StateOp].self, forKey: .ops) ?? []
        pendingClicks = try container.decodeIfPresent([String].self, forKey: .pendingClicks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(appId, forKey: .appId)
        try container.encode(lastDeviceId, forKey: .lastDeviceId)
        try container.encode(registration, forKey: .registration)
        try container.encode(push, forKey: .push)
        try container.encode(tags, forKey: .tags)
        try container.encode(ops, forKey: .ops)
        try container.encode(pendingClicks, forKey: .pendingClicks)
    }
}

/// Event types of the events route.
enum EventType: String, Codable, Sendable {
    case received, displayed, opened, dismissed
}

/// One event waiting to be sent (`events.json` → `pending`).
struct PendingEvent: Codable, Equatable, Sendable {
    var id: String
    var type: EventType
    /// ISO-8601 UTC, the moment the SDK saw the event.
    var at: String
    var actionId: String?

    private enum CodingKeys: String, CodingKey {
        case id, type, at
        case actionId = "action_id"
    }

    init(id: String, type: EventType, at: String, actionId: String?) {
        self.id = id
        self.type = type
        self.at = at
        self.actionId = actionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(EventType.self, forKey: .type)
        at = try container.decode(String.self, forKey: .at)
        actionId = try container.decodeIfPresent(String.self, forKey: .actionId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(at, forKey: .at)
        try container.encode(actionId, forKey: .actionId)
    }
}

/// `events.json`: pending events and the dedupe keys (`<id>|<type>`, oldest first).
struct EventsState: Codable, Equatable, Sendable {
    var v = 1
    var pending: [PendingEvent] = []
    var seen: [String] = []
}

/// `consent.json`.
struct ConsentFile: Codable, Equatable, Sendable {
    var v = 1
    var given: Bool
}

/// The Keychain credentials item of one (app id, API host): device id and secret never split.
struct StoredCredentials: Codable, Equatable, Sendable {
    var v = 1
    var appId: String
    var apiHost: String
    var deviceId: String
    var deviceSecret: String

    private enum CodingKeys: String, CodingKey {
        case v
        case appId = "app_id"
        case apiHost = "api_host"
        case deviceId = "device_id"
        case deviceSecret = "device_secret"
    }
}

/// Device credentials in memory.
struct Credentials: Equatable, Sendable {
    var deviceId: String
    var secret: SecretString
}

/// Permission as the SDK tracks it.
enum PermissionStatus: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral

    /// Authorized, provisional and ephemeral count as granted.
    var isGranted: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        }
    }

    var name: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        }
    }
}
