import Foundation
import SallaPushCore

/// A downloaded image, moved into the extension's temporary directory with a matching extension.
struct DownloadedAttachment: Sendable, Equatable {
    let fileURL: URL
    /// The uniform type identifier passed as `UNNotificationAttachmentOptionsTypeHintKey`.
    let typeIdentifier: String
}

/// The outcome of an image download.
enum AttachmentDownloadResult: Sendable, Equatable {
    case success(DownloadedAttachment)
    case failure(String)
}

/// A running download.
protocol AttachmentDownloadTask: Sendable {
    func cancel()
}

/// Downloads notification images. Injected so tests run without a network.
protocol AttachmentDownloading: Sendable {
    func download(_ url: URL, completion: @escaping @Sendable (AttachmentDownloadResult) -> Void) -> AttachmentDownloadTask
}

/// Image rules shared by the live downloader and the tests.
enum AttachmentRules {
    /// The largest image attached, in bytes.
    static let maximumBytes: Int64 = 10 * 1_024 * 1_024

    /// The type identifier and file extension for a MIME type, else the URL's extension, else JPEG.
    static func type(mimeType: String?, url: URL) -> (identifier: String, fileExtension: String) {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return ("public.jpeg", "jpg")
        case "image/png": return ("public.png", "png")
        case "image/gif": return ("com.compuserve.gif", "gif")
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "png": return ("public.png", "png")
        case "gif": return ("com.compuserve.gif", "gif")
        default: return ("public.jpeg", "jpg")
        }
    }
}

/// One ephemeral `URLSession` per download, invalidated after use; 10 s request and 20 s resource timeouts;
/// streamed to disk, never decoded in memory; https only, redirects included. The download is cancelled as soon as
/// the answer is not a 2xx or the image is known to exceed 10 MB (declared length or bytes written), so an oversized
/// image is never fetched in full.
final class URLSessionAttachmentDownloader: AttachmentDownloading, @unchecked Sendable {
    private let temporaryDirectory: URL
    private let protocolClasses: [AnyClass]?

    /// - Parameter protocolClasses: URL loading protocols placed first (local test servers); nil keeps the defaults.
    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory, protocolClasses: [AnyClass]? = nil) {
        self.temporaryDirectory = temporaryDirectory
        self.protocolClasses = protocolClasses
    }

    func download(_ url: URL, completion: @escaping @Sendable (AttachmentDownloadResult) -> Void) -> AttachmentDownloadTask {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let delegate = DownloadDelegate(url: url, directory: temporaryDirectory, completion: completion)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
        // The session is invalidated once its only task completes, which releases the delegate.
        session.finishTasksAndInvalidate()
        return DownloadTaskHandle(task: task, session: session)
    }

    /// Checks a finished download against the image rules and moves the file into `directory`.
    static func result(location: URL?, response: URLResponse?, error: Error?, url: URL,
                       directory: URL) -> AttachmentDownloadResult {
        if let error { return .failure(LogSanitizer.describe(error)) }
        guard let http = response as? HTTPURLResponse else { return .failure("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { return .failure("HTTP \(http.statusCode)") }
        guard http.expectedContentLength <= AttachmentRules.maximumBytes else { return .failure("image larger than 10 MB") }
        guard let location else { return .failure("no file") }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { return .failure("empty image") }
        guard Int64(size) <= AttachmentRules.maximumBytes else { return .failure("image larger than 10 MB") }
        let type = AttachmentRules.type(mimeType: http.mimeType, url: url)
        let destination = directory.appendingPathComponent("sallapush-\(UUID().uuidString).\(type.fileExtension)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            return .failure(LogSanitizer.describe(error))
        }
        return .success(DownloadedAttachment(fileURL: destination, typeIdentifier: type.identifier))
    }

    /// Why a download is stopped before it completes, from its first bytes: nil while it may go on.
    static func earlyRejection(response: URLResponse?, totalBytesWritten: Int64, totalBytesExpected: Int64) -> String? {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return "HTTP \(http.statusCode)"
        }
        if totalBytesExpected > AttachmentRules.maximumBytes || totalBytesWritten > AttachmentRules.maximumBytes {
            return "image larger than 10 MB"
        }
        return nil
    }
}

/// The delegate of one download. URLSession calls it on the session's private serial queue; the first outcome wins
/// and the completion runs once.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let directory: URL
    private let completion: @Sendable (AttachmentDownloadResult) -> Void
    private let outcome = Locked<AttachmentDownloadResult?>(nil)
    private let once = Once()

    init(url: URL, directory: URL, completion: @escaping @Sendable (AttachmentDownloadResult) -> Void) {
        self.url = url
        self.directory = directory
        self.completion = completion
        super.init()
    }

    /// Keeps the first outcome; later ones are ignored.
    private func record(_ result: AttachmentDownloadResult) {
        outcome.withLock { current in
            if current == nil { current = result }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let reason = URLSessionAttachmentDownloader.earlyRejection(response: downloadTask.response,
                                                                       totalBytesWritten: totalBytesWritten,
                                                                       totalBytesExpected: totalBytesExpectedToWrite)
        else { return }
        record(.failure(reason))
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes the file when this method returns, so it is checked and moved now.
        record(URLSessionAttachmentDownloader.result(location: location, response: downloadTask.response, error: nil,
                                                     url: url, directory: directory))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let recorded = outcome.current
        let result = recorded ?? .failure(error.map(LogSanitizer.describe) ?? "no file")
        guard once.claim() else { return }
        completion(result)
    }

    /// Follows a redirect only to another https URL.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

private struct DownloadTaskHandle: AttachmentDownloadTask, @unchecked Sendable {
    let task: URLSessionDownloadTask
    let session: URLSession

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
    }
}
