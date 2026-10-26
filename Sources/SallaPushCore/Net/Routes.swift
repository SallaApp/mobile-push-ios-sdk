import Foundation

/// The push-service routes the SDKs call.
package enum Route: Sendable, Equatable {
    case register(appId: String)
    case update(deviceId: String)
    case link(deviceId: String)
    case unlink(deviceId: String)
    case tags(deviceId: String)
    case events(deviceId: String)

    /// The HTTP method. Tags use PATCH on iOS.
    package var method: String {
        switch self {
        case .register, .link, .unlink, .events: return "POST"
        case .update: return "PUT"
        case .tags: return "PATCH"
        }
    }

    /// The concrete path. Ids are validated before they reach a path.
    package var path: String {
        switch self {
        case let .register(appId): return "/apps/\(appId)/devices"
        case let .update(deviceId): return "/devices/\(deviceId)"
        case let .link(deviceId): return "/devices/\(deviceId)/link"
        case let .unlink(deviceId): return "/devices/\(deviceId)/unlink"
        case let .tags(deviceId): return "/devices/\(deviceId)/tags"
        case let .events(deviceId): return "/devices/\(deviceId)/events"
        }
    }

    /// The path template that logs show instead of ids.
    package var template: String {
        switch self {
        case .register: return "/apps/{app_id}/devices"
        case .update: return "/devices/{id}"
        case .link: return "/devices/{id}/link"
        case .unlink: return "/devices/{id}/unlink"
        case .tags: return "/devices/{id}/tags"
        case .events: return "/devices/{id}/events"
        }
    }
}

/// A validated push-service base URL.
package struct APIBase: Sendable, Equatable {
    /// The production default.
    package static let defaultString = "https://api.salla.dev/notifications/v1/sallapush"

    /// The base, without a trailing slash or a final `/v1`.
    package let string: String
    /// The base as a URL.
    package let url: URL
    /// The lowercased `scheme://host[:port]`.
    package let origin: String
    /// The storage partition of this host.
    package let hostTag: String

    /// The production base.
    package static var production: APIBase {
        // The constant always parses; the fallback branch only satisfies the compiler without a force unwrap.
        validated(URL(string: defaultString)) ?? APIBase(string: defaultString, url: URL(fileURLWithPath: "/"))
    }

    private init(string: String, url: URL) {
        self.string = string
        self.url = url
        origin = HostTag.origin(of: url)
        hostTag = HostTag.make(for: url)
    }

    /// `url` when it is https, or http on localhost, 127.0.0.1 or ::1; without credentials, query or fragment. Routes
    /// add `/apps/...` or `/devices/...` to it. One final path segment `v1` is dropped, so a URL copied with a trailing
    /// `/v1` doesn't put a second version segment in every route.
    package static func validated(_ url: URL?) -> APIBase? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }
        switch scheme {
        case "https":
            break
        case "http":
            guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return nil }
        default:
            return nil
        }
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if components.path.split(separator: "/").last == "v1", text.hasSuffix("/v1") {
            text.removeLast(3)
            while text.hasSuffix("/") { text.removeLast() }
        }
        guard let normalized = URL(string: text) else { return nil }
        return APIBase(string: text, url: normalized)
    }

    /// The URL of `route` under this base.
    package func url(for route: Route) -> URL? {
        URL(string: string + route.path)
    }
}
