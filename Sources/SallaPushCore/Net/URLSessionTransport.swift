import Foundation

/// The live transport: one ephemeral `URLSession` per engine, with no cookies, no cache, two connections per host,
/// a 20 s request timeout (link 30 s), a 60 s resource timeout, and a delegate that refuses redirects and reads at
/// most `maximumBodyBytes + 1` bytes of an answer. Completions run on the engine queue. Once invalidated, the session is
/// never used again.
package final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: TransportDelegate
    private let invalidated = Locked(false)

    /// - Parameters:
    ///   - queue: the engine queue; completions are delivered on it.
    ///   - userAgent: `SallaPush-iOS/<version> (iOS <os>; <model>)`.
    ///   - protocolClasses: URL loading protocols placed first (local test servers); nil keeps the system defaults.
    ///   - maximumBodyBytes: answers longer than this are cut at one byte more, which the API client rejects.
    package init(queue: DispatchQueue, userAgent: String, protocolClasses: [AnyClass]? = nil,
                 maximumBodyBytes: Int = APIClient.maximumAnswerBytes) {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        delegate = TransportDelegate(maximumBodyBytes: maximumBodyBytes)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    package func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) -> HTTPTaskHandle? {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Duration.clamped(request.timeout)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // Checked and used under the same lock as invalidate(), so no task is ever created on an invalidated session.
        let task: URLSessionDataTask? = invalidated.withLock { isInvalidated in
            if isInvalidated { return nil }
            let task = session.dataTask(with: urlRequest)
            delegate.expect(task, completion: completion)
            return task
        }
        guard let task else { return nil }
        task.resume()
        return DataTaskHandle(task: task)
    }

    package func invalidate() {
        invalidated.withLock { isInvalidated in
            if isInvalidated { return }
            isInvalidated = true
            session.invalidateAndCancel()
        }
    }

    /// Builds `SallaPush-iOS/<version> (iOS <os>; <model>)`.
    package static func userAgent(sdkVersion: String, osVersion: String, model: String) -> String {
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        let safeModel = LogSanitizer.clean(model).replacingOccurrences(of: ";", with: "")
        return "SallaPush-iOS/\(sdkVersion) (\(platform) \(osVersion); \(safeModel))"
    }
}

/// The session delegate. It refuses every redirect, so the `Authorization` header and request bodies never reach
/// another URL (the 3xx answer itself completes the task and is handled as a retryable error), and it collects each
/// answer, keeping at most `maximumBodyBytes + 1` bytes: a longer answer stops downloading there, so a wrong or hostile
/// host can never make the SDK buffer an unbounded body. URLSession calls it on the engine queue, one call at a time.
private final class TransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// One answer being received.
    private struct Exchange {
        let completion: @Sendable (HTTPResult) -> Void
        var body = Data()
        var cut = false
    }

    /// The bytes kept of an answer: the cap, and one more that tells the API client the answer was longer.
    private let limit: Int
    private let exchanges = Locked<[Int: Exchange]>([:])

    init(maximumBodyBytes: Int) {
        limit = maximumBodyBytes < Int.max ? max(maximumBodyBytes, 0) + 1 : Int.max
        super.init()
    }

    /// Registers the completion of `task` before it is resumed.
    func expect(_ task: URLSessionTask, completion: @escaping @Sendable (HTTPResult) -> Void) {
        exchanges.withLock { $0[task.taskIdentifier] = Exchange(completion: completion) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cutNow = exchanges.withLock { exchanges -> Bool in
            guard var exchange = exchanges[dataTask.taskIdentifier], !exchange.cut else { return false }
            exchange.body.append(data.prefix(limit - exchange.body.count))
            exchange.cut = exchange.body.count >= limit
            exchanges[dataTask.taskIdentifier] = exchange
            return exchange.cut
        }
        if cutNow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchanges.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        // A cut answer completes with the cancellation it caused; it is delivered with the bytes kept.
        exchange.completion(Self.result(body: exchange.body, response: task.response, error: exchange.cut ? nil : error))
    }

    private static func result(body: Data, response: URLResponse?, error: Error?) -> HTTPResult {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut: return .failure(.timeout)
                case NSURLErrorCancelled: return .failure(.cancelled)
                default: break
                }
            }
            return .failure(.network(LogSanitizer.describe(error)))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("no HTTP response"))
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return .response(status: http.statusCode, headers: headers, body: body)
    }
}

private struct DataTaskHandle: HTTPTaskHandle, @unchecked Sendable {
    let task: URLSessionDataTask

    func cancel() {
        task.cancel()
    }
}
