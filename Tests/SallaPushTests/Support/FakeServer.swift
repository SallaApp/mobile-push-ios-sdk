import Foundation
@testable import SallaPush
@testable import SallaPushCore

/// A stateful model of push-service's device routes, with per-test scripted answers.
/// Every request is recorded; no network is used.
final class FakeServer: @unchecked Sendable {
    struct Request {
        let method: String
        let host: String
        let path: String
        let headers: [String: String]
        let json: [String: Any]
        let body: Data

        var template: String {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "apps" { return "register" }
            if parts.count == 2 { return method == "PUT" ? "update" : path }
            return parts.last ?? path
        }

        var deviceId: String? {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "devices" else { return nil }
            return parts[1]
        }
    }

    enum Reply {
        case json(Int, [String: Any], [String: String])
        case raw(Int, Data, [String: String])
        case failure(TransportFailure)
        case hold
    }

    /// What push-service's identity verification (Salla's platform) says of an identity token: it proves the
    /// customer `linked`, or it is rejected (expired, revoked, forged).
    enum CustomerAnswer {
        case linked(String)
        case rejected
    }

    /// A device row. `disabledReason` stands for push-service's `disabled` status: `rotation` when another registration
    /// took its token. push-service's device auth does not read the status, so a disabled row still answers.
    struct Device {
        var id: String
        var secret: String
        var appId: String
        var token: String?
        var environment: String?
        var externalId: String?
        var disabledReason: String?
        var tags: [String: String] = [:]
        var optedIn: Bool?
    }

    private struct Script {
        let id: Int
        let matches: (Request) -> Bool
        let reply: (Request) -> Reply
        var remaining: Int?
    }

    /// A request held back by a `.hold` reply until the test releases or cancels it.
    private struct Held {
        let request: Request
        let completion: @Sendable (HTTPResult) -> Void
        let queue: DispatchQueue
    }

    private let lock = NSLock()
    private var devices: [String: Device] = [:]
    private var log: [Request] = []
    private var scripts: [Script] = []
    private var scriptCounter = 0
    private var held: [Held] = []
    private var requestCounter = 0
    private(set) var pendingDeliveries = 0
    /// Verifies an identity token. By default `token(for:)` proves its customer, and any other token proves a customer
    /// of its own, with a stable external id.
    var customers: (String) -> CustomerAnswer = { token in .linked(FakeServer.defaultCustomer(of: token)) }

    /// The external id of the customer `token` proves; for a rejected token, the one the default would name.
    func customer(of token: String) -> String {
        if case let .linked(externalId) = customers(token) { return externalId }
        return Self.defaultCustomer(of: token)
    }

    /// A valid identity token of `externalId` (by default).
    static func token(for externalId: String) -> String {
        "eyJ." + externalId
    }

    static func defaultCustomer(of token: String) -> String {
        if token.hasPrefix("eyJ."), token.count > 4 { return String(token.dropFirst(4)) }
        return "cust_" + Fingerprint.sha256Hex(Data(token.utf8)).prefix(6)
    }

    // MARK: - Inspection

    var requests: [Request] { lock.guarded { log } }

    func requests(_ template: String) -> [Request] {
        requests.filter { $0.template == template }
    }

    var templates: [String] { requests.map(\.template) }

    func device(_ id: String?) -> Device? {
        guard let id else { return nil }
        return lock.guarded { devices[id] }
    }

    var allDevices: [Device] { lock.guarded { Array(devices.values) } }

    func mutate(_ id: String?, _ body: (inout Device) -> Void) {
        guard let id else { return }
        lock.guarded {
            if var device = devices[id] {
                body(&device)
                devices[id] = device
            }
        }
    }

    func purge(_ id: String?) {
        guard let id else { return }
        lock.guarded { _ = devices.removeValue(forKey: id) }
    }

    /// An unlink made outside SallaPush (by Salla's backend, say): the row loses its link and keeps its tags.
    func unlinkOutOfBand(_ id: String?) {
        mutate(id) { $0.externalId = nil }
    }

    /// Seeds a row as an import from another system makes one: a secret no SDK knows, and the imported link and tags.
    /// Returns its device id.
    @discardableResult
    func seedImportedDevice(appId: String = "st_42_ios", token: String, externalId: String? = nil,
                            tags: [String: String] = [:]) -> String {
        let id = UUID().uuidString.lowercased()
        lock.guarded {
            devices[id] = Device(id: id, secret: "imported-" + UUID().uuidString, appId: appId, token: token,
                                 environment: "production", externalId: externalId, tags: tags)
        }
        return id
    }

    var heldCount: Int { lock.guarded { held.count } }

    // MARK: - Scripting

    /// Answers requests of `template` with `reply`, `times` times (nil: forever), before the model runs.
    @discardableResult
    func script(_ template: String, times: Int? = 1, reply: @escaping (Request) -> Reply) -> Int {
        lock.guarded {
            scriptCounter += 1
            scripts.append(Script(id: scriptCounter, matches: { $0.template == template }, reply: reply, remaining: times))
            return scriptCounter
        }
    }

    func clearScripts() {
        lock.guarded { scripts = [] }
    }

    static func error(_ status: Int, _ code: String, reason: String? = nil, headers: [String: String] = [:]) -> Reply {
        var envelope: [String: Any] = ["code": code, "message": "\(code) message"]
        if let reason { envelope["reason"] = reason }
        return .json(status, ["error": envelope], headers)
    }

    /// Releases the oldest held request with `reply`, or with the model's answer when nil.
    func releaseHeld(_ reply: Reply? = nil) {
        let entry: Held? = lock.guarded {
            held.isEmpty ? nil : held.removeFirst()
        }
        guard let entry else { return }
        deliver(reply ?? model(entry.request), to: entry.completion, on: entry.queue)
    }

    /// Cancels held requests the way URLSession does.
    func cancelHeld(where predicate: (Request) -> Bool) {
        let cancelled = lock.guarded { () -> [Held] in
            let matching = held.filter { predicate($0.request) }
            held.removeAll { predicate($0.request) }
            return matching
        }
        for entry in cancelled {
            deliver(.failure(.cancelled), to: entry.completion, on: entry.queue)
        }
    }

    // MARK: - Transport entry

    func handle(_ httpRequest: HTTPRequest, queue: DispatchQueue, completion: @escaping @Sendable (HTTPResult) -> Void) {
        var headers: [String: String] = [:]
        for (name, value) in httpRequest.headers { headers[name.lowercased()] = value }
        let body = httpRequest.body ?? Data()
        let json = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        let request = Request(method: httpRequest.method, host: httpRequest.url.host ?? "",
                              path: Self.routePath(httpRequest.url.path), headers: headers, json: json, body: body)
        let scripted: Reply? = lock.guarded {
            log.append(request)
            guard let index = scripts.firstIndex(where: { $0.matches(request) }) else { return nil }
            let script = scripts[index]
            if let remaining = script.remaining {
                if remaining <= 1 { scripts.remove(at: index) } else { scripts[index].remaining = remaining - 1 }
            }
            return script.reply(request)
        }
        guard let scripted else {
            deliver(model(request), to: completion, on: queue)
            return
        }
        if case .hold = scripted {
            lock.guarded { held.append(Held(request: request, completion: completion, queue: queue)) }
            return
        }
        deliver(scripted, to: completion, on: queue)
    }

    /// The route part of a request path, from `/apps/` or `/devices/` on: a base URL with a path (the default's
    /// `/notifications/v1/sallapush`) is served like one without.
    static func routePath(_ path: String) -> String {
        for marker in ["/apps/", "/devices/"] {
            if let range = path.range(of: marker) { return String(path[range.lowerBound...]) }
        }
        return path
    }

    private func deliver(_ reply: Reply, to completion: @escaping @Sendable (HTTPResult) -> Void, on queue: DispatchQueue) {
        let result: HTTPResult
        switch reply {
        case let .json(status, body, headers):
            var allHeaders = headers
            allHeaders["x-request-id"] = allHeaders["x-request-id"] ?? nextRequestId()
            result = .response(status: status, headers: allHeaders,
                               body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        case let .raw(status, data, headers):
            result = .response(status: status, headers: headers, body: data)
        case let .failure(failure):
            result = .failure(failure)
        case .hold:
            result = .failure(.cancelled)
        }
        lock.guarded { pendingDeliveries += 1 }
        queue.async { [self] in
            completion(result)
            lock.guarded { pendingDeliveries -= 1 }
        }
    }

    private func nextRequestId() -> String {
        lock.guarded {
            requestCounter += 1
            return "req-\(requestCounter)"
        }
    }

    // MARK: - The model

    private func model(_ request: Request) -> Reply {
        if request.template == "register" { return register(request) }
        guard let id = request.deviceId else { return Self.error(404, "not_found") }
        let auth = lock.guarded { () -> Reply? in
            guard let header = request.headers["authorization"], header.hasPrefix("Device ") else {
                return Self.error(401, "invalid_device_secret")
            }
            guard let device = devices[id] else { return Self.error(404, "unknown_device") }
            guard device.secret == String(header.dropFirst("Device ".count)) else { return Self.error(401, "invalid_device_secret") }
            return nil
        }
        if let auth { return auth }
        switch request.template {
        case "update": return update(id, request)
        case "link": return link(id, request)
        case "unlink": return unlink(id)
        case "tags": return tags(id, request)
        case "events":
            return .json(202, [:], [:])
        default:
            return Self.error(404, "not_found")
        }
    }

    /// A registration as push-service runs it: every registration inserts a new device, and the rows of
    /// the app that held its push token let go of it and are disabled. The answer holds the id and the secret alone.
    private func register(_ request: Request) -> Reply {
        let parts = request.path.split(separator: "/").map(String.init)
        let appId = parts.count > 1 ? parts[1] : ""
        let token = (request.json["push_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let environment = request.json["apns_env"] as? String
        let optedIn = request.json["opted_in"] as? Bool
        let secret = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return lock.guarded {
            if let token {
                for holder in devices.values where holder.appId == appId && holder.token == token {
                    disable(holder.id)
                }
            }
            let id = UUID().uuidString.lowercased()
            devices[id] = Device(id: id, secret: secret, appId: appId, token: token, environment: environment,
                                 optedIn: optedIn ?? true)
            return .json(201, ["device_id": id, "device_secret": secret], [:])
        }
    }

    /// The row lets go of its push token and is disabled; its link and its tags stay. Called under the lock.
    private func disable(_ id: String) {
        guard var row = devices[id] else { return }
        row.token = nil
        row.disabledReason = "rotation"
        devices[id] = row
    }

    /// An update: a `push_token` that another row of the app holds moves to this row, and that row is disabled.
    private func update(_ id: String, _ request: Request) -> Reply {
        lock.guarded {
            guard var device = devices[id] else { return }
            if let token = request.json["push_token"] as? String {
                for holder in devices.values where holder.id != id && holder.appId == device.appId && holder.token == token {
                    disable(holder.id)
                }
                device.token = token
            }
            if let environment = request.json["apns_env"] as? String { device.environment = environment }
            if let optedIn = request.json["opted_in"] as? Bool { device.optedIn = optedIn }
            devices[id] = device
        }
        return .json(200, [:], [:])
    }

    /// A link as push-service runs it: the body must hold `external_id` (1-128 characters, counted as JavaScript
    /// counts them) and a non-empty `identity_token`, else `400 invalid_request`; the token must prove that customer,
    /// else `403 invalid_identity_token`. The link replaces any earlier one; the tags stay.
    private func link(_ id: String, _ request: Request) -> Reply {
        guard let externalId = request.json["external_id"] as? String, (1...128).contains(externalId.utf16.count),
              let token = request.json["identity_token"] as? String, !token.isEmpty
        else { return Self.error(400, "invalid_request") }
        guard case let .linked(subject) = customers(token), subject == externalId else {
            return Self.error(403, "invalid_identity_token")
        }
        mutate(id) { $0.externalId = externalId }
        return .json(200, [:], [:])
    }

    /// An unlink as push-service runs it: the body is not read; the link goes, the tags stay.
    private func unlink(_ id: String) -> Reply {
        mutate(id) { $0.externalId = nil }
        return .json(200, [:], [:])
    }

    /// A tags request as push-service runs it: every added key must match `^[a-z0-9_]{1,64}$`, and the row's tags plus
    /// the added keys minus the removed ones, counted before the change, must not pass 100, else `400 invalid_request`:
    /// an added key the row already holds still counts as one more, and a removed key it doesn't hold as one less. Then
    /// the removals go, then the additions.
    private func tags(_ id: String, _ request: Request) -> Reply {
        let add = request.json["add"] as? [String: String] ?? [:]
        let remove = request.json["remove"] as? [String] ?? []
        for key in add.keys where !Validation.isLowerIdentifier(key) {
            return Self.error(400, "invalid_request")
        }
        var result: [String: String] = [:]
        var tooMany = false
        mutate(id) { device in
            if device.tags.count + add.count - remove.count > 100 {
                tooMany = true
                return
            }
            for key in remove { device.tags.removeValue(forKey: key) }
            for (key, value) in add { device.tags[key] = value }
            result = device.tags
        }
        if tooMany { return Self.error(400, "invalid_request") }
        return .json(200, ["tags": result], [:])
    }
}

/// The transport each engine gets: it hands requests to the shared fake server.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let server: FakeServer
    let queue: DispatchQueue
    private let invalidated = Locked(false)
    let sendsAfterInvalidate = Locked(0)

    init(server: FakeServer, queue: DispatchQueue) {
        self.server = server
        self.queue = queue
    }

    var isInvalidated: Bool { invalidated.current }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) -> HTTPTaskHandle? {
        if invalidated.current {
            sendsAfterInvalidate.withLock { $0 += 1 }
            return nil
        }
        server.handle(request, queue: queue, completion: completion)
        let server = self.server
        let path = FakeServer.routePath(request.url.path)
        return Handle { server.cancelHeld { $0.path == path } }
    }

    func invalidate() {
        invalidated.set(true)
    }

    private struct Handle: HTTPTaskHandle, @unchecked Sendable {
        let action: () -> Void

        func cancel() { action() }
    }
}
