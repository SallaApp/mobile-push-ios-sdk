import Foundation
import SallaPushCore
@testable import SallaPushExtension
import UserNotifications
import XCTest

/// Records downloads and completes them only when a test says so. No network.
final class FakeDownloader: AttachmentDownloading, @unchecked Sendable {
    final class Download: AttachmentDownloadTask, @unchecked Sendable {
        let url: URL
        private let completion = Locked<(@Sendable (AttachmentDownloadResult) -> Void)?>(nil)
        private let cancelled = Locked(false)

        init(url: URL, completion: @escaping @Sendable (AttachmentDownloadResult) -> Void) {
            self.url = url
            self.completion.set(completion)
        }

        var isCancelled: Bool { cancelled.current }

        func cancel() {
            cancelled.set(true)
        }

        /// Completes the download once, as URLSession would, even after a cancel.
        func complete(_ result: AttachmentDownloadResult) {
            let handler = completion.withLock { stored -> (@Sendable (AttachmentDownloadResult) -> Void)? in
                defer { stored = nil }
                return stored
            }
            handler?(result)
        }
    }

    private let started = Locked<[Download]>([])
    /// When set, every download completes with it before `download` returns.
    let immediateResult = Locked<AttachmentDownloadResult?>(nil)

    var downloads: [Download] { started.current }

    func download(_ url: URL, completion: @escaping @Sendable (AttachmentDownloadResult) -> Void) -> AttachmentDownloadTask {
        let download = Download(url: url, completion: completion)
        started.withLock { $0.append(download) }
        if let result = immediateResult.current {
            download.complete(result)
        }
        return download
    }
}

/// Records the images the handler attaches, without the system's attachment store.
final class AttachRecorder: @unchecked Sendable {
    struct Attached {
        let file: DownloadedAttachment
        let content: UNMutableNotificationContent
    }

    let attached = Locked<[Attached]>([])
    /// When set, preparing an attachment fails with it.
    let failure = Locked<Error?>(nil)
    /// When set, preparing an attachment blocks until it is signalled (a slow system attachment store).
    let gate = Locked<DispatchSemaphore?>(nil)
    /// Signalled when a preparation starts.
    let started = DispatchSemaphore(value: 0)

    var prepare: ExtensionEnvironment.PrepareAttachment {
        { [attached, failure, gate, started] file in
            started.signal()
            gate.current?.wait()
            if let error = failure.current { throw error }
            return { content in attached.withLock { $0.append(Attached(file: file, content: content)) } }
        }
    }
}

/// Collects what the content handler receives.
final class ContentHandlerSpy: @unchecked Sendable {
    private let received = Locked<[UNNotificationContent]>([])

    var calls: [UNNotificationContent] { received.current }

    var handler: (UNNotificationContent) -> Void {
        { [received] content in received.withLock { $0.append(content) } }
    }
}

final class ServiceExtensionTests: XCTestCase {
    // XCTest creates one instance per test method, so every test starts with fresh fakes.
    private let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-nse-\(UUID().uuidString)")
    private let downloader = FakeDownloader()
    private let attacher = AttachRecorder()
    private let entries = Locked<[SallaPushLogEntry]>([])
    private let container = Locked<URL?>(nil)
    private lazy var logger: SDKLogger = {
        let logger = SDKLogger(categoryOverride: "extension", plistLevelReader: { nil }, consoleSink: { _, _, _ in })
        let entries = self.entries
        logger.setTap { entry in entries.withLock { $0.append(entry) } }
        return logger
    }()

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        container.set(temporaryRoot.appendingPathComponent("group", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: - Helpers

    private func makeHandler(appGroup: String? = "group.com.salla.test") -> SallaPushServiceExtension {
        let container = self.container
        let environment = ExtensionEnvironment(downloader: downloader, containerURL: { _ in container.current },
                                               clock: FixedClock(), logger: logger, prepareAttachment: attacher.prepare)
        return SallaPushServiceExtension(appGroupIdentifier: appGroup, environment: environment)
    }

    private func request(_ userInfo: [AnyHashable: Any], identifier: String = "request-1") -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Title"
        content.body = "Body"
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private func native(messageId: String = "msg_ab", image: String? = nil) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Title", "body": "Body"], "mutable-content": 1],
                                            "sp_v": "1", "sp_id": messageId]
        if let image { userInfo["sp_image"] = image }
        return userInfo
    }

    private func codes() -> [String] {
        entries.current.map(\.code)
    }

    private func inboxFiles() -> [String] {
        guard let group = container.current else { return [] }
        let folder = Inbox.folder(inContainer: group)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func pngFile() throws -> URL {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let url = temporaryRoot.appendingPathComponent("download-\(UUID().uuidString).png")
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    // MARK: - Ownership

    func test_foreignNotification_returnsFalse_withoutCallingTheHandler() {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        let foreign: [[AnyHashable: Any]] = [
            ["aps": ["alert": "x"], "custom": ["i": "onesignal-id"]],
            ["aps": ["alert": "x"], "moengage": ["cid": "1"]],
            ["aps": ["alert": "x"], "_k": "klaviyo"],
            ["aps": ["alert": "x"], "source": "webengage"],
        ]
        for (index, userInfo) in foreign.enumerated() {
            XCTAssertFalse(handler.didReceive(request(userInfo, identifier: "r\(index)"), withContentHandler: spy.handler))
            XCTAssertFalse(SallaPushServiceExtension.isSallaPushNotification(request(userInfo)))
        }
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertTrue(downloader.downloads.isEmpty)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire(), "owns nothing")
        XCTAssertTrue(spy.calls.isEmpty)
    }

    /// An Objective-C caller can pass nil for the nonnull request. Nothing crashes, the handler is
    /// never called, and the call is logged.
    func test_nilRequest_returnsFalse_withoutCallingTheHandler() {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        let nilRequest = unsafeBitCast(0 as Int, to: UNNotificationRequest.self)
        XCTAssertFalse(handler.didReceive(nilRequest, withContentHandler: spy.handler))
        XCTAssertFalse(SallaPushServiceExtension.isSallaPushNotification(nilRequest))
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire(), "owns nothing")
        let warning = entries.current.first { $0.code == "api.invalid_argument" }
        XCTAssertEqual(warning?.message, "didReceive ignored: the request is nil.")
        XCTAssertEqual(warning?.level, .warn)
        XCTAssertEqual(warning?.category, "extension")
    }

    func test_sallaPushNotification_withoutImage_callsTheHandlerExactlyOnce() {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(SallaPushServiceExtension.isSallaPushNotification(request(native())))
        XCTAssertTrue(handler.didReceive(request(native()), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.title, "Title")
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire(), "the request was finished")
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(downloader.downloads.isEmpty)
    }

    func test_image_isDownloadedAndAttached_thenTheHandlerCalledOnce() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        XCTAssertTrue(spy.calls.isEmpty, "waits for the image")
        let download = try XCTUnwrap(downloader.downloads.first)
        XCTAssertEqual(download.url.absoluteString, "https://cdn.salla.test/p.png")
        let file = DownloadedAttachment(fileURL: try pngFile(), typeIdentifier: "public.png")
        download.complete(.success(file))
        XCTAssertEqual(attacher.attached.current.map(\.file), [file])
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(spy.calls.first === attacher.attached.current.first?.content, "the image goes into the delivered content")
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(spy.calls.count, 1)
    }

    func test_attachFailure_deliversWithoutTheImage_andDeletesTheFile() throws {
        attacher.failure.set(CocoaError(.fileReadCorruptFile))
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        let download = try XCTUnwrap(downloader.downloads.first)
        let file = DownloadedAttachment(fileURL: try pngFile(), typeIdentifier: "public.png")
        download.complete(.success(file))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.attachments.count, 0)
        XCTAssertEqual(entries.current.filter { $0.code == "nse.attachment_failed" }.map(\.level), [.warn])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path), "an image that was not attached is deleted")
    }

    func test_slowAttachmentStep_neverDelaysTheExpiryDelivery() throws {
        let gate = DispatchSemaphore(value: 0)
        attacher.gate.set(gate)
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        let download = try XCTUnwrap(downloader.downloads.first)
        let file = DownloadedAttachment(fileURL: try pngFile(), typeIdentifier: "public.png")
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            download.complete(.success(file))
            completed.signal()
        }
        XCTAssertEqual(attacher.started.wait(timeout: .now() + 5), .success, "the attachment step started")
        // The attachment step is still blocked: the expiry path must not wait for it.
        let expired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            handler.serviceExtensionTimeWillExpire()
            expired.signal()
        }
        XCTAssertEqual(expired.wait(timeout: .now() + 5), .success, "expiry waited behind the attachment step")
        XCTAssertEqual(spy.calls.count, 1, "delivered at expiry")
        gate.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(spy.calls.count, 1, "exactly one handler call")
        XCTAssertTrue(attacher.attached.current.isEmpty, "nothing is attached after delivery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path), "the unattached image is deleted")
    }

    func test_ownCancellation_isNotReportedAsAnAttachmentFailure() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        let download = try XCTUnwrap(downloader.downloads.first)
        XCTAssertTrue(handler.serviceExtensionTimeWillExpire())
        download.complete(.failure("NSURLErrorDomain -999, cancelled"))
        XCTAssertEqual(codes().filter { $0.hasPrefix("nse.") && !$0.hasPrefix("nse.badge") }, ["nse.expired"], "one warning for one event")
        XCTAssertEqual(spy.calls.count, 1)
    }

    #if os(macOS)
    // The live step against the framework. macOS only: in an iOS Simulator logic-test bundle the system attachment
    // store takes many seconds to answer.
    func test_liveAttach_addsOneImageWithTheTypeHint() throws {
        let content = UNMutableNotificationContent()
        let file = DownloadedAttachment(fileURL: try pngFile(), typeIdentifier: "public.png")
        let apply = try ExtensionEnvironment.systemAttachment(file)
        apply(content)
        XCTAssertEqual(content.attachments.map(\.identifier), ["sallapush-image"])
    }
    #endif

    func test_compatImage_comesFromAttId() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        let compat: [AnyHashable: Any] = ["aps": ["alert": "x", "mutable-content": 1],
                                          "custom": ["i": "os-id", "a": ["push_ref": "msg_cd"]],
                                          "att": ["id": "https://cdn.salla.test/c.jpg"]]
        XCTAssertTrue(handler.didReceive(request(compat), withContentHandler: spy.handler))
        XCTAssertEqual(downloader.downloads.first?.url.absoluteString, "https://cdn.salla.test/c.jpg")
        downloader.downloads.first?.complete(.failure("HTTP 404"))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.attachments.count, 0)
        XCTAssertTrue(codes().contains("nse.attachment_failed"))
        XCTAssertEqual(entries.current.first { $0.code == "nse.attachment_failed" }?.level, .warn)
        XCTAssertEqual(entries.current.first { $0.code == "nse.attachment_failed" }?.category, "extension")
    }

    func test_nonHTTPSImage_isIgnored() {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        for (index, image) in ["http://cdn.salla.test/p.png", "file:///etc/hosts", "ftp://x/y.png", "not a url"].enumerated() {
            XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_\(index)", image: image)), withContentHandler: spy.handler))
        }
        XCTAssertTrue(downloader.downloads.isEmpty)
        XCTAssertEqual(spy.calls.count, 4)
        XCTAssertTrue(spy.calls.allSatisfy { $0.attachments.isEmpty })
    }

    // MARK: - Expiry and reuse

    func test_expiryBeforeTheDownloadCompletes_deliversTheBestAttemptOnce() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        let download = try XCTUnwrap(downloader.downloads.first)
        XCTAssertTrue(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.attachments.count, 0)
        XCTAssertTrue(download.isCancelled)
        XCTAssertEqual(entries.current.filter { $0.code == "nse.expired" }.map(\.level), [.warn])
        download.complete(.success(DownloadedAttachment(fileURL: try pngFile(), typeIdentifier: "public.png")))
        XCTAssertEqual(spy.calls.count, 1, "a late image never causes a second call")
        XCTAssertTrue(attacher.attached.current.isEmpty, "nothing is attached after delivery")
        XCTAssertFalse(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(spy.calls.count, 1)
    }

    func test_reuse_deliversTheFirstRequestBeforeTakingTheSecond() throws {
        let handler = makeHandler()
        let first = ContentHandlerSpy()
        let second = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_1", image: "https://cdn.salla.test/1.png"), identifier: "r1"),
                                         withContentHandler: first.handler))
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_2", image: "https://cdn.salla.test/2.png"), identifier: "r2"),
                                         withContentHandler: second.handler))
        XCTAssertEqual(first.calls.count, 1)
        XCTAssertTrue(second.calls.isEmpty)
        XCTAssertEqual(entries.current.filter { $0.code == "nse.replaced_request" }.map(\.level), [.debug])
        XCTAssertTrue(downloader.downloads[0].isCancelled)
        downloader.downloads[0].complete(.failure("cancelled"))
        XCTAssertEqual(first.calls.count, 1)
        XCTAssertTrue(second.calls.isEmpty, "the first download's completion does not finish the second request")
        XCTAssertTrue(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(second.calls.count, 1)
        XCTAssertEqual(first.calls.count, 1)
    }

    func test_completionRacingExpiry_callsTheHandlerExactlyOnce() throws {
        for round in 0..<200 {
            let handler = makeHandler(appGroup: nil)
            let spy = ContentHandlerSpy()
            XCTAssertTrue(handler.didReceive(request(native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
            let download = try XCTUnwrap(downloader.downloads.last)
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    download.complete(.failure("HTTP 500"))
                } else {
                    handler.serviceExtensionTimeWillExpire()
                }
            }
            XCTAssertEqual(spy.calls.count, 1, "round \(round)")
        }
    }

    // MARK: - Inbox

    func test_received_writtenToInbox() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_ab")), withContentHandler: spy.handler))
        let files = inboxFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".json") && !$0.hasSuffix(".tmp") })
        let group = try XCTUnwrap(container.current)
        let ingestion = Inbox(folder: Inbox.folder(inContainer: group)).ingest(now: FixedClock().now() + 5)
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_ab"])
        XCTAssertEqual(ingestion.records.first?.at, FixedClock().now())
        XCTAssertEqual(spy.calls.count, 1)
    }

    /// The extension writes `at` in UTC with milliseconds, the form push-service needs, and the app reads it back.
    func test_received_recordsAtWithMilliseconds() throws {
        let container = self.container
        let environment = ExtensionEnvironment(downloader: downloader, containerURL: { _ in container.current },
                                               clock: QuarterPastClock(), logger: logger, prepareAttachment: attacher.prepare)
        let handler = SallaPushServiceExtension(appGroupIdentifier: "group.com.salla.test", environment: environment)
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_ab")), withContentHandler: spy.handler))
        let folder = Inbox.folder(inContainer: try XCTUnwrap(container.current))
        let name = try XCTUnwrap(inboxFiles().first)
        XCTAssertTrue(name.hasPrefix("1790000000250-"), name)
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["at"] as? String, "2026-09-21T14:13:20.250Z")
        let records = Inbox(folder: folder).ingest(now: QuarterPastClock().now()).records
        XCTAssertEqual(records.map(\.messageId), ["msg_ab"])
        XCTAssertEqual(records.first?.at, QuarterPastClock().now())
        XCTAssertEqual(spy.calls.count, 1)
    }

    func test_received_usesThePushRef_forCompatPayloads_andSkipsLocalCopies() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        let compat: [AnyHashable: Any] = ["aps": ["alert": "x"], "custom": ["i": "os-id", "a": ["push_ref": "msg_cd"]]]
        XCTAssertTrue(handler.didReceive(request(compat, identifier: "c"), withContentHandler: spy.handler))
        var local = native(messageId: "msg_local")
        local["sp_local"] = "1"
        XCTAssertTrue(handler.didReceive(request(local, identifier: "l"), withContentHandler: spy.handler))
        let group = try XCTUnwrap(container.current)
        let ingestion = Inbox(folder: Inbox.folder(inContainer: group)).ingest(now: FixedClock().now())
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_cd"])
        XCTAssertEqual(spy.calls.count, 2)
    }

    func test_withoutAnAppGroup_receivedIsSkipped_withOneMessage() {
        let handler = makeHandler(appGroup: "   ")
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_1"), identifier: "1"), withContentHandler: spy.handler))
        XCTAssertTrue(handler.didReceive(request(native(messageId: "msg_2"), identifier: "2"), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertEqual(codes().filter { $0 == "config.no_app_group" }.count, 1)
    }

    func test_unavailableAppGroup_isAnError_andNeverBlocksDelivery() {
        container.set(nil)
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native()), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(entries.current.filter { $0.code == "storage.failed" }.map(\.level), [.error])
    }

    func test_unwritableAppGroup_isAnError_andNeverBlocksDelivery() throws {
        let blocker = temporaryRoot.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        container.set(blocker)
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native()), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(entries.current.filter { $0.code == "storage.failed" }.map(\.level), [.error])
    }

    func test_fullInbox_isReportedAsAFullEventQueue_andNeverBlocksDelivery() throws {
        let group = try XCTUnwrap(container.current)
        let folder = Inbox.folder(inContainer: group)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<Inbox.capacity {
            try Data().write(to: folder.appendingPathComponent("1-\(index).json"))
        }
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request(native()), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(entries.current.filter { $0.code == "events.queue_full" }.map(\.level), [.warn])
        XCTAssertEqual(entries.current.first { $0.code == "events.queue_full" }?.category, "extension")
    }

    // MARK: - Image rules

    func test_imageRules_typeFromMIME_thenExtension_thenJPEG() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.salla.test/a.gif"))
        XCTAssertEqual(AttachmentRules.type(mimeType: "image/png", url: url).identifier, "public.png")
        XCTAssertEqual(AttachmentRules.type(mimeType: "IMAGE/JPEG", url: url).fileExtension, "jpg")
        XCTAssertEqual(AttachmentRules.type(mimeType: "image/gif", url: url).identifier, "com.compuserve.gif")
        XCTAssertEqual(AttachmentRules.type(mimeType: nil, url: url).identifier, "com.compuserve.gif")
        let png = try XCTUnwrap(URL(string: "https://cdn.salla.test/a.PNG"))
        XCTAssertEqual(AttachmentRules.type(mimeType: "application/octet-stream", url: png).identifier, "public.png")
        let bare = try XCTUnwrap(URL(string: "https://cdn.salla.test/image"))
        XCTAssertEqual(AttachmentRules.type(mimeType: nil, url: bare).identifier, "public.jpeg")
    }

    func test_downloadResult_acceptsASmallImage_andMovesIt() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.salla.test/p"))
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png", "Content-Length": "67"])
        let location = try pngFile()
        let directory = temporaryRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = URLSessionAttachmentDownloader.result(location: location, response: response, error: nil, url: url,
                                                           directory: directory)
        guard case let .success(file) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(file.typeIdentifier, "public.png")
        XCTAssertEqual(file.fileURL.pathExtension, "png")
        XCTAssertEqual(file.fileURL.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    func test_downloadResult_rejectsOversizedImages_byHeaderAndByFileSize() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.salla.test/big.jpg"))
        let directory = temporaryRoot
        let declared = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(AttachmentRules.maximumBytes + 1)"])
        XCTAssertEqual(URLSessionAttachmentDownloader.result(location: try pngFile(), response: declared, error: nil, url: url,
                                                             directory: directory),
                       .failure("image larger than 10 MB"))
        let large = temporaryRoot.appendingPathComponent("large.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(AttachmentRules.maximumBytes + 1))
        try handle.close()
        let undeclared = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        XCTAssertEqual(URLSessionAttachmentDownloader.result(location: large, response: undeclared, error: nil, url: url,
                                                             directory: directory),
                       .failure("image larger than 10 MB"))
    }

    func test_downloadResult_rejectsErrorsStatusesAndEmptyFiles() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.salla.test/p.png"))
        let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])
        XCTAssertEqual(URLSessionAttachmentDownloader.result(location: try pngFile(), response: notFound, error: nil, url: url,
                                                             directory: temporaryRoot),
                       .failure("HTTP 404"))
        let empty = temporaryRoot.appendingPathComponent("empty.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        XCTAssertEqual(URLSessionAttachmentDownloader.result(location: empty, response: success, error: nil, url: url,
                                                             directory: temporaryRoot),
                       .failure("empty image"))
        XCTAssertEqual(URLSessionAttachmentDownloader.result(location: nil, response: URLResponse(), error: nil, url: url,
                                                             directory: temporaryRoot),
                       .failure("no HTTP response"))
        let failure = URLSessionAttachmentDownloader.result(location: nil, response: nil, error: URLError(.timedOut), url: url,
                                                            directory: temporaryRoot)
        guard case .failure = failure else { return XCTFail("expected a failure") }
    }

    func test_publicInitializers_treatABlankAppGroupAsNone() {
        let spy = ContentHandlerSpy()
        let handler = SallaPushServiceExtension(appGroupIdentifier: " ")
        XCTAssertTrue(handler.didReceive(request(native()), withContentHandler: spy.handler))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertFalse(SallaPushServiceExtension().serviceExtensionTimeWillExpire())
    }
}

/// 2026-09-21 14:13:20 UTC.
struct FixedClock: Clock {
    func now() -> Double {
        1_790_000_000
    }
}

/// 2026-09-21 14:13:20.250 UTC.
private struct QuarterPastClock: Clock {
    func now() -> Double {
        1_790_000_000.25
    }
}
