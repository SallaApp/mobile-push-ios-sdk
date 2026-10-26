import Foundation

/// A validated 2xx answer.
package struct APISuccess<Value: Sendable>: Sendable {
    package let value: Value
    package let status: Int
    package let requestId: String?
}

/// The outcome of a push-service call.
package typealias APIResult<Value: Sendable> = Result<APISuccess<Value>, APIError>

// MARK: - Request bodies

/// The register body: the device fields push-service stores, nothing else. Empty optional fields are omitted, never
/// sent as ""; a registration without a push token omits `push_token`.
package struct RegisterBody: Encodable, Sendable {
    package var pushToken: String?
    package var apnsEnv: String?
    package var optedIn: Bool
    package var metadata: DeviceMetadata

    package init(pushToken: String?, apnsEnv: String?, optedIn: Bool, metadata: DeviceMetadata) {
        self.pushToken = pushToken
        self.apnsEnv = apnsEnv
        self.optedIn = optedIn
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case platform, language, timezone
        case pushToken = "push_token"
        case apnsEnv = "apns_env"
        case optedIn = "opted_in"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("ios", forKey: .platform)
        try container.encodeIfPresent(pushToken, forKey: .pushToken)
        try container.encodeIfPresent(apnsEnv, forKey: .apnsEnv)
        try container.encode(optedIn, forKey: .optedIn)
        try container.encodeIfPresent(metadata.appVersion, forKey: .appVersion)
        try container.encodeIfPresent(metadata.sdkVersion, forKey: .sdkVersion)
        try container.encodeIfPresent(metadata.osVersion, forKey: .osVersion)
        try container.encodeIfPresent(metadata.deviceModel, forKey: .deviceModel)
        try container.encodeIfPresent(metadata.language, forKey: .language)
        try container.encodeIfPresent(metadata.timezone, forKey: .timezone)
    }
}

/// The device metadata of the register and update bodies, already trimmed and truncated (UTF-16 units).
package struct DeviceMetadata: Sendable, Equatable {
    package var appVersion: String?
    package var sdkVersion: String?
    package var osVersion: String?
    package var deviceModel: String?
    package var language: String?
    package var timezone: String?

    package init(appVersion: String?, sdkVersion: String?, osVersion: String?, deviceModel: String?,
                 language: String?, timezone: String?) {
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.language = language
        self.timezone = timezone
    }
}

/// The update body. `{}` is the bare heartbeat; the SDK always sends the full metadata.
package struct UpdateBody: Encodable, Sendable {
    package var pushToken: String?
    package var apnsEnv: String?
    package var optedIn: Bool?
    package var metadata: DeviceMetadata?

    package init(pushToken: String?, apnsEnv: String?, optedIn: Bool?, metadata: DeviceMetadata?) {
        self.pushToken = pushToken
        self.apnsEnv = apnsEnv
        self.optedIn = optedIn
        self.metadata = metadata
    }

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

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pushToken, forKey: .pushToken)
        try container.encodeIfPresent(apnsEnv, forKey: .apnsEnv)
        try container.encodeIfPresent(optedIn, forKey: .optedIn)
        try container.encodeIfPresent(metadata?.appVersion, forKey: .appVersion)
        try container.encodeIfPresent(metadata?.sdkVersion, forKey: .sdkVersion)
        try container.encodeIfPresent(metadata?.osVersion, forKey: .osVersion)
        try container.encodeIfPresent(metadata?.deviceModel, forKey: .deviceModel)
        try container.encodeIfPresent(metadata?.language, forKey: .language)
        try container.encodeIfPresent(metadata?.timezone, forKey: .timezone)
    }
}

/// The link body. The identity token is revealed only here.
package struct LinkBody: Encodable, Sendable {
    package var externalId: String
    package var identityToken: SecretString

    package init(externalId: String, identityToken: SecretString) {
        self.externalId = externalId
        self.identityToken = identityToken
    }

    private enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case identityToken = "identity_token"
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(externalId, forKey: .externalId)
        try container.encode(identityToken.revealed, forKey: .identityToken)
    }
}

/// `{}`: the body of the unlink, which push-service does not read.
package struct EmptyBody: Encodable, Sendable {
    package init() {}
}

/// The tags body.
package struct TagsBody: Encodable, Sendable {
    package var add: [String: String]
    package var remove: [String]

    package init(add: [String: String], remove: [String]) {
        self.add = add
        self.remove = remove
    }

    private enum CodingKeys: String, CodingKey {
        case add, remove
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !add.isEmpty { try container.encode(add, forKey: .add) }
        if !remove.isEmpty { try container.encode(remove, forKey: .remove) }
    }
}

/// One event of the events body.
package struct EventItem: Encodable, Sendable, Equatable {
    package var type: String
    package var notificationId: String
    package var at: String

    package init(type: String, notificationId: String, at: String) {
        self.type = type
        self.notificationId = notificationId
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case type, at
        case notificationId = "notification_id"
    }
}

/// The events body.
package struct EventsBody: Encodable, Sendable {
    package var events: [EventItem]

    package init(events: [EventItem]) {
        self.events = events
    }
}

// MARK: - Answers

/// `201 {device_id, device_secret}` of the register route: all push-service answers. `status`, `adopted` and `linked`,
/// which an earlier push-service also answered, are read when present and never required; absent, they read as active,
/// false and false.
package struct RegisterResponse: Sendable, Equatable {
    package let deviceId: String
    package let deviceSecret: SecretString
    /// `status: "disabled"`.
    package let isDisabled: Bool
    package let adopted: Bool
    package let linked: Bool
}

/// `200 {}` of the update route: nothing is required. `linked` is read when an earlier push-service answered it as a
/// JSON boolean; nil otherwise.
package struct UpdateResponse: Sendable, Equatable {
    package let linked: Bool?
}

/// `200 {}` of link and unlink.
package struct EmptyResponse: Sendable, Equatable {}

/// `200 {tags}` of the tags route.
package struct TagsResponse: Sendable, Equatable {
    package let tags: [String: String]
}

/// `202 {}` of the events route. Counts are optional: `accepted` and `ignored` are 0 when the answer carries none.
package struct EventsResponse: Sendable, Equatable {
    package let accepted: Int
    package let ignored: Int
}

// MARK: - Client

/// Builds the device routes' requests, sends them through the transport and validates every answer.
package final class APIClient: Sendable {
    /// Request timeout of every route except link, unless an events call names its own.
    package static let requestTimeout: Double = 20
    /// Link waits for Salla's platform to verify the identity token, so it gets longer.
    package static let linkTimeout: Double = 30
    /// The largest answer body read, in bytes. The largest answer the contract allows is a tags answer: 100 tags whose
    /// 255-unit values may be JSON-escaped to 6 bytes a unit, about 160 KB.
    package static let maximumAnswerBytes = 262_144
    /// Answers nested deeper than this are never parsed (the payload limit; real answers nest 2 levels).
    package static let maximumAnswerDepth = JSONValue.maximumDepth

    package let base: APIBase
    private let transport: HTTPTransport
    private let clock: Clock

    package init(base: APIBase, transport: HTTPTransport, clock: Clock) {
        self.base = base
        self.transport = transport
        self.clock = clock
    }

    // Every call returns nil, without calling `completion`, when the request was not started
    // (the transport is invalidated). Otherwise `completion` runs exactly once, on the engine queue.

    /// Registers the device (no device auth).
    package func register(appId: String, body: RegisterBody,
                          completion: @escaping @Sendable (APIResult<RegisterResponse>) -> Void) -> HTTPTaskHandle? {
        send(.register(appId: appId), secret: nil, body: body, hiding: [body.pushToken].compactMap { $0 },
             decode: Self.decodeRegister, completion: completion)
    }

    /// Updates the device. Any JSON object is a success.
    package func update(deviceId: String, secret: SecretString, body: UpdateBody,
                        completion: @escaping @Sendable (APIResult<UpdateResponse>) -> Void) -> HTTPTaskHandle? {
        send(.update(deviceId: deviceId), secret: secret, body: body, hiding: [body.pushToken].compactMap { $0 },
             decode: { object in
                 guard let object else { return nil }
                 return UpdateResponse(linked: object["linked"].flatMap { Self.jsonBool($0) })
             }, completion: completion)
    }

    /// Links the device: push-service verifies the identity token with Salla's platform and links the device to the
    /// customer.
    package func link(deviceId: String, secret: SecretString, body: LinkBody,
                      completion: @escaping @Sendable (APIResult<EmptyResponse>) -> Void) -> HTTPTaskHandle? {
        send(.link(deviceId: deviceId), secret: secret, body: body, hiding: [body.identityToken.revealed],
             decode: { object in object == nil ? nil : EmptyResponse() }, completion: completion)
    }

    /// Unlinks the device: it stays registered, linked to no customer.
    package func unlink(deviceId: String, secret: SecretString,
                        completion: @escaping @Sendable (APIResult<EmptyResponse>) -> Void) -> HTTPTaskHandle? {
        send(.unlink(deviceId: deviceId), secret: secret, body: EmptyBody(),
             decode: { object in object == nil ? nil : EmptyResponse() }, completion: completion)
    }

    /// Removes, then adds, the device's tags.
    package func tags(deviceId: String, secret: SecretString, body: TagsBody,
                      completion: @escaping @Sendable (APIResult<TagsResponse>) -> Void) -> HTTPTaskHandle? {
        send(.tags(deviceId: deviceId), secret: secret, body: body,
             decode: { object in
                 guard let object, let raw = object["tags"] as? [String: Any] else { return nil }
                 var tags: [String: String] = [:]
                 for (key, value) in raw {
                     guard let value = value as? String else { return nil }
                     tags[key] = value
                 }
                 return TagsResponse(tags: tags)
             }, completion: completion)
    }

    /// Sends events. Any JSON object is a success. `timeout` is this request's own, `requestTimeout` unless given: a
    /// caller with a deadline passes the time it has left, so a slow answer is waited for, never cut and sent again.
    package func events(deviceId: String, secret: SecretString, body: EventsBody,
                        timeout: Double = APIClient.requestTimeout,
                        completion: @escaping @Sendable (APIResult<EventsResponse>) -> Void) -> HTTPTaskHandle? {
        send(.events(deviceId: deviceId), secret: secret, body: body, timeout: timeout,
             decode: { object in
                 guard let object else { return nil }
                 let accepted = (object["accepted"] as? NSNumber)?.intValue ?? 0
                 let ignored = (object["ignored"] as? NSNumber)?.intValue ?? 0
                 return EventsResponse(accepted: accepted, ignored: ignored)
             }, completion: completion)
    }

    // MARK: - Plumbing

    /// Sends one request. `hiding` lists the secrets the request carries besides the device secret (the push token, the
    /// identity token): a server that echoes one never gets it into a log line. `timeout`, when set, replaces the
    /// route's own.
    private func send<Body: Encodable, Value: Sendable>(
        _ route: Route,
        secret: SecretString?,
        body: Body,
        hiding carried: [String] = [],
        timeout: Double? = nil,
        decode: @escaping @Sendable ([String: Any]?) -> Value?,
        completion: @escaping @Sendable (APIResult<Value>) -> Void
    ) -> HTTPTaskHandle? {
        // Ids are validated before they reach a path and every body is a plain struct, so neither guard
        // fails in practice; a nil return is handled like a refused send.
        guard let url = base.url(for: route) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(body) else { return nil }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let secret {
            headers["Authorization"] = "Device " + secret.revealed
        }
        let request = HTTPRequest(method: route.method, url: url, headers: headers, body: data,
                                  timeout: timeout ?? Self.timeout(for: route), route: route)
        let clock = self.clock
        let secrets = carried + (secret.map { [$0.revealed] } ?? [])
        return transport.send(request) { result in
            completion(Self.interpret(result, route: route, now: clock.now(), hiding: secrets, decode: decode))
        }
    }

    /// Link waits for Salla's platform behind the push service, so it gets longer than the other routes.
    private static func timeout(for route: Route) -> Double {
        if case .link = route { return linkTimeout }
        return requestTimeout
    }

    /// The longest error code read from an envelope; a longer one, or an empty one, makes the body no envelope.
    package static let maximumCodeLength = 64

    /// Maps a transport result to a validated success or a classified failure. A non-2xx body is read as one of
    /// push-service's answers only when it is the error envelope with a code of 1-64 characters (Android's rule);
    /// the envelope's message is outside text, so `secrets` (what the request carried) and token-like runs are
    /// masked in it.
    package static func interpret<Value: Sendable>(_ result: HTTPResult, route: Route, now: Double,
                                                   hiding secrets: [String] = [],
                                                   decode: ([String: Any]?) -> Value?) -> APIResult<Value> {
        switch result {
        case let .failure(failure):
            switch failure {
            case .timeout: return .failure(APIError(kind: .timeout, route: route))
            case .cancelled: return .failure(APIError(kind: .cancelled, route: route))
            case let .network(detail): return .failure(APIError(kind: .network, route: route, detail: detail))
            }
        case let .response(status, headers, body):
            let requestId = headers["x-request-id"].map { String(LogSanitizer.clean($0).prefix(64)) }
            let retryAfter = RetryAfter.seconds(from: headers["retry-after"], now: now)
            let answer = AnswerBody(body)
            switch status {
            case 200..<300:
                guard let value = decode(answer.object) else {
                    return .failure(APIError(kind: .invalidResponse, route: route, status: status,
                                             requestId: requestId, retryAfter: retryAfter, detail: answer.rejection))
                }
                return .success(APISuccess(value: value, status: status, requestId: requestId))
            case 300..<400:
                return .failure(APIError(kind: .redirect, route: route, status: status,
                                         requestId: requestId, retryAfter: retryAfter))
            default:
                guard let object = answer.object else {
                    return .failure(APIError(kind: .nonJSON, route: route, status: status,
                                             requestId: requestId, retryAfter: retryAfter, detail: answer.rejection))
                }
                let envelope = object["error"] as? [String: Any]
                let code = (envelope?["code"] as? String)
                    .flatMap { (1...maximumCodeLength).contains($0.utf16.count) ? LogSanitizer.clean($0) : nil }
                    .flatMap { $0.isEmpty ? nil : $0 }
                let reason = (envelope?["reason"] as? String).map { String(LogSanitizer.clean($0).prefix(32)) }
                let message = (envelope?["message"] as? String).map { LogSanitizer.serverText($0, hiding: secrets) }
                return .failure(APIError(kind: .http, route: route, status: status, code: code, reason: reason,
                                         message: message, requestId: requestId, retryAfter: retryAfter))
            }
        }
    }

    /// An answer body: the JSON object it holds, if any. A body over the size cap, not UTF-8 (the contract's encoding)
    /// or nested past the depth limit is never handed to `JSONSerialization` (its recursion would overflow the engine
    /// queue's stack) and reads as no object, with the reason, so it is retried with backoff like any unreadable answer.
    private struct AnswerBody {
        let object: [String: Any]?
        let rejection: String?

        init(_ data: Data) {
            if data.count > APIClient.maximumAnswerBytes {
                object = nil
                rejection = "larger than \(APIClient.maximumAnswerBytes / 1_024) KB"
            } else if data.contains(0) {
                object = nil
                rejection = "not UTF-8 text"
            } else if !DepthLimit.jsonFits(data, maxDepth: APIClient.maximumAnswerDepth) {
                object = nil
                rejection = "nested deeper than \(APIClient.maximumAnswerDepth) levels"
            } else {
                object = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                rejection = nil
            }
        }
    }

    /// A JSON boolean; numbers are not accepted as booleans.
    package static func jsonBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, number.isBoolean else { return nil }
        return number.boolValue
    }

    /// Only `device_id` (a UUID) and `device_secret` (base64url) are required; `status`, `adopted` and `linked` count only
    /// as a JSON string or boolean, and anything else reads as absent.
    private static let decodeRegister: @Sendable ([String: Any]?) -> RegisterResponse? = { object in
        guard let object,
              let deviceId = object["device_id"] as? String, Validation.isUUID(deviceId),
              let secret = object["device_secret"] as? String, Validation.isBase64URL(secret)
        else { return nil }
        return RegisterResponse(deviceId: deviceId.lowercased(), deviceSecret: SecretString(secret),
                                isDisabled: object["status"] as? String == "disabled",
                                adopted: object["adopted"].flatMap { jsonBool($0) } ?? false,
                                linked: object["linked"].flatMap { jsonBool($0) } ?? false)
    }
}
