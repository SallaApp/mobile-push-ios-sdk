import Foundation

/// A failed push-service call, with everything the engine needs to apply push-service's answer table.
package struct APIError: Error, Sendable, Equatable {
    /// The broad class of failure.
    package enum Kind: Sendable, Equatable {
        /// A non-2xx answer whose body is a JSON object (it may lack the error envelope).
        case http
        /// A non-2xx answer whose body is not JSON (an HTML error page, a WAF challenge, an empty body).
        case nonJSON
        /// A 3xx answer; redirects are never followed.
        case redirect
        /// A 2xx answer whose body failed validation.
        case invalidResponse
        /// No HTTP answer: offline, DNS, TLS, connection reset.
        case network
        /// No HTTP answer within the timeout.
        case timeout
        /// The request was cancelled.
        case cancelled
    }

    package let kind: Kind
    package let route: Route
    /// The HTTP status, when there was an answer.
    package let status: Int?
    /// `error.code` of the envelope.
    package let code: String?
    /// `error.reason` of a `device_disabled` envelope.
    package let reason: String?
    /// `error.message`, cleaned and capped for logging.
    package let message: String?
    /// The `X-Request-Id` header.
    package let requestId: String?
    /// The clamped `Retry-After` in seconds, when the answer carried one.
    package let retryAfter: Double?
    /// A cleaned transport description, or why an answer body was not read (too large, nested too deep).
    package let detail: String?

    package init(kind: Kind, route: Route, status: Int? = nil, code: String? = nil, reason: String? = nil,
                 message: String? = nil, requestId: String? = nil, retryAfter: Double? = nil, detail: String? = nil) {
        self.kind = kind
        self.route = route
        self.status = status
        self.code = code
        self.reason = reason
        self.message = message
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.detail = detail
    }

    /// Whether this failure leaves the outcome open and is retried with backoff (no answer, 5xx, non-JSON,
    /// redirect, invalid 2xx body, a 4xx without an error code). Rate limiting is handled separately.
    package var isTransient: Bool {
        switch kind {
        case .network, .timeout, .nonJSON, .redirect, .invalidResponse, .cancelled:
            return true
        case .http:
            guard let status else { return true }
            return status >= 500 || (code == nil && status != 429)
        }
    }

    /// A 4xx (not 429) whose body is the error envelope with a code: one of push-service's answers, handled per
    /// code. A 4xx without a code (a proxy's or an edge's JSON error, such as Cloudflare's RFC 9457 bodies) is not
    /// one: it is transient and retried with backoff, as on Android.
    package var isClientError: Bool {
        guard kind == .http, let status else { return false }
        return (400..<500).contains(status) && status != 429 && code != nil
    }

    /// Whether the request may have reached the server without the client learning the outcome.
    package var outcomeUnknown: Bool {
        kind == .network || kind == .timeout || kind == .cancelled
    }

    /// Whether the request may have changed server state without a usable answer: it got no answer (a transport
    /// failure, a timeout or a cancellation), or a 2xx whose body could not be read. Every other failure is an answer
    /// that applied nothing, because the device routes are transactional (Android's `mayHaveApplied`).
    package var mayHaveApplied: Bool {
        switch kind {
        case .network, .timeout, .cancelled, .invalidResponse: return true
        case .http, .nonJSON, .redirect: return false
        }
    }

    /// `429 rate_limited`, or any 429.
    package var isRateLimited: Bool {
        status == 429
    }

    /// A short description for log lines: status, code and request id. The server's message is shown only for a client
    /// error, where it says what to fix; a retryable failure never echoes server text (`net.retry` in the log
    /// catalogue).
    package var summary: String {
        var parts: [String] = []
        switch kind {
        case .network: parts.append("network error" + (detail.map { ": \($0)" } ?? ""))
        case .timeout: parts.append("timed out")
        case .cancelled: parts.append("cancelled")
        case .redirect: parts.append("redirect \(status.map(String.init) ?? "")")
        case .invalidResponse:
            parts.append("unexpected body (\(status.map(String.init) ?? "")\(detail.map { ", \($0)" } ?? ""))")
        case .nonJSON:
            parts.append("\(status.map(String.init) ?? "") " + (detail.map { "answer not read (\($0))" } ?? "non-JSON answer"))
        case .http:
            var text = status.map(String.init) ?? ""
            if let code { text += " \(code)" }
            if isClientError, let message, !message.isEmpty { text += ": \"\(message)\"" }
            parts.append(text)
        }
        if let requestId { parts.append("request \(requestId)") }
        return parts.joined(separator: ", ")
    }

    /// Log metadata for this failure.
    package var metadata: [String: String] {
        var values: [String: String] = [LogMetadataKey.route: route.template]
        if let status { values[LogMetadataKey.httpStatus] = String(status) }
        if let code { values[LogMetadataKey.errorCode] = code }
        if let requestId { values[LogMetadataKey.requestId] = requestId }
        if let reason { values[LogMetadataKey.reason] = reason }
        return values
    }
}
