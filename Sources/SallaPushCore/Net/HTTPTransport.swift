import Foundation

/// One HTTP request to push-service.
package struct HTTPRequest: Sendable {
    package let method: String
    package let url: URL
    package let headers: [String: String]
    package let body: Data?
    /// Seconds before the request times out.
    package let timeout: Double
    /// The route, for logging by template.
    package let route: Route

    package init(method: String, url: URL, headers: [String: String], body: Data?, timeout: Double, route: Route) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.route = route
    }
}

/// What a transport produced.
package enum HTTPResult: Sendable {
    /// Any HTTP answer, redirects included (redirects are never followed). Header names are lowercased.
    case response(status: Int, headers: [String: String], body: Data)
    /// No HTTP answer.
    case failure(TransportFailure)
}

/// Why no HTTP answer arrived.
package enum TransportFailure: Sendable, Equatable {
    case network(String)
    case timeout
    case cancelled
}

/// A request in flight.
package protocol HTTPTaskHandle: Sendable {
    func cancel()
}

/// Sends requests. Completions arrive on the engine queue of the transport's owner.
package protocol HTTPTransport: AnyObject, Sendable {
    /// Starts `request`; nil, without touching any session, once the transport is invalidated.
    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) -> HTTPTaskHandle?
    /// Cancels everything and refuses every later request.
    func invalidate()
}
