import Foundation
import SallaPushCore
@testable import SallaPushExtension
import UserNotifications
import XCTest

/// The extension counts SallaPush notifications on the app icon badge while the app's settings say so: one mark per
/// request id in the App Group, and the count on each notification at hand-over, in place of the push's own badge.
final class BadgeTests: XCTestCase {
    // XCTest creates one instance per test method, so every test starts with fresh fakes.
    private let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-nse-badge-\(UUID().uuidString)")
    private let downloader = FakeDownloader()
    private let attacher = AttachRecorder()
    private let entries = Locked<[SallaPushLogEntry]>([])
    private let container = Locked<URL?>(nil)
    private let appBundle = Locked<String?>("com.salla.test")
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
        let appBundle = self.appBundle
        let environment = ExtensionEnvironment(downloader: downloader, containerURL: { _ in container.current },
                                               clock: FixedClock(), logger: logger, prepareAttachment: attacher.prepare,
                                               appBundleIdentifier: { appBundle.current })
        return SallaPushServiceExtension(appGroupIdentifier: appGroup, environment: environment)
    }

    /// The app's badge files.
    private func store() throws -> BadgeStore {
        try XCTUnwrap(BadgeStore(container: try XCTUnwrap(container.current), appBundleIdentifier: "com.salla.test"))
    }

    /// The app wrote its settings, as it does at each start with consent.
    private func appSettings(autoUpdateBadge: Bool = true) throws {
        XCTAssertTrue(try store().writeSettings(BadgeSettings(autoUpdateBadge: autoUpdateBadge)))
    }

    /// A notification of `userInfo`, with the push's own `aps.badge` when `badge` is set.
    private func request(_ identifier: String, _ userInfo: [AnyHashable: Any]? = nil, badge: Int? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Title"
        content.userInfo = userInfo ?? native()
        content.badge = badge.map { NSNumber(value: $0) }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private func native(messageId: String = "msg_ab", image: String? = nil) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Title"], "mutable-content": 1],
                                            "sp_v": "1", "sp_id": messageId]
        if let image { userInfo["sp_image"] = image }
        return userInfo
    }

    private func badges(_ spy: ContentHandlerSpy) -> [Int?] {
        spy.calls.map { $0.badge?.intValue }
    }

    private func skipped() -> [String] {
        entries.current.filter { $0.code == "nse.badge_skipped" }.map { $0.metadata[LogMetadataKey.reason] ?? "" }
    }

    // MARK: - Counting

    func test_eachNotification_carriesTheCount() throws {
        try appSettings()
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request("r1"), withContentHandler: spy.handler))
        XCTAssertTrue(handler.didReceive(request("r2", native(messageId: "msg_cd")), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [1, 2])
        XCTAssertEqual(try store().count(), 2)
        let set = entries.current.filter { $0.code == "nse.badge_set" }
        XCTAssertEqual(set.map(\.level), [.debug, .debug])
        XCTAssertEqual(set.map(\.category), ["extension", "extension"])
        XCTAssertEqual(set.last?.metadata, [LogMetadataKey.count: "2"])
        XCTAssertTrue(skipped().isEmpty)
    }

    func test_theSameRequestIdTwice_carriesTheSameCount() throws {
        try appSettings()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(makeHandler().didReceive(request("collapse-1"), withContentHandler: spy.handler))
        XCTAssertTrue(makeHandler().didReceive(request("collapse-1"), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [1, 1], "a replacement with the same collapse id adds nothing")
    }

    func test_pushesThatCarryABadgeOf1_carryTheCountInstead() throws {
        try appSettings()
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        for index in 1...3 {
            XCTAssertTrue(handler.didReceive(request("r\(index)", native(messageId: "msg_\(index)"), badge: 1),
                                             withContentHandler: spy.handler))
        }
        XCTAssertEqual(badges(spy), [1, 2, 3])
    }

    // MARK: - Not counted

    func test_withoutTheAppsSettings_theBadgeIsUntouched_andTheReasonLoggedOnce() throws {
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request("r1", badge: 7), withContentHandler: spy.handler))
        XCTAssertTrue(handler.didReceive(request("r2", native(messageId: "msg_cd")), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [7, nil], "the push's own badge applies")
        XCTAssertEqual(try store().count(), 0)
        XCTAssertEqual(skipped(), ["no_settings"])
        let entry = try XCTUnwrap(entries.current.first { $0.code == "nse.badge_skipped" })
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.message, "SallaPush doesn't count notifications on the app badge (the app hasn't run this "
                           + "SallaPush version with consent, or it uses another App Group).")
    }

    func test_withAutoUpdateBadgeOff_nothingIsCounted() throws {
        try appSettings(autoUpdateBadge: false)
        let spy = ContentHandlerSpy()
        XCTAssertTrue(makeHandler().didReceive(request("r1", badge: 3), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [3])
        XCTAssertEqual(try store().count(), 0)
        XCTAssertTrue(skipped().isEmpty)
        XCTAssertFalse(entries.current.contains { $0.code == "nse.badge_set" })
    }

    func test_withoutAnAppGroup_orTheAppsBundleId_nothingIsCounted() throws {
        try appSettings()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(makeHandler(appGroup: nil).didReceive(request("r1", badge: 2), withContentHandler: spy.handler))
        appBundle.set(nil)
        XCTAssertTrue(makeHandler().didReceive(request("r2", badge: 2), withContentHandler: spy.handler))
        appBundle.set("com.salla.test")
        container.set(nil)
        XCTAssertTrue(makeHandler().didReceive(request("r3", badge: 2), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [2, 2, 2])
        container.set(temporaryRoot.appendingPathComponent("group", isDirectory: true))
        XCTAssertEqual(try store().count(), 0)
        XCTAssertEqual(skipped(), ["no_app_group", "no_app_bundle"], "each reason once per process")
    }

    func test_anotherSDKsNotification_isNeverCounted() throws {
        try appSettings()
        let spy = ContentHandlerSpy()
        let foreign = request("other", ["aps": ["alert": "x", "badge": 4], "custom": ["i": "onesignal-id"]], badge: 4)
        XCTAssertFalse(makeHandler().didReceive(foreign, withContentHandler: spy.handler))
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertEqual(try store().count(), 0)
    }

    // MARK: - Hand-over

    func test_anImageThatArrivesLater_carriesTheCountAtItsHandOver() throws {
        try appSettings()
        let spy = ContentHandlerSpy()
        let imageHandler = makeHandler()
        XCTAssertTrue(imageHandler.didReceive(request("image", native(messageId: "msg_1", image: "https://cdn.salla.test/p.png")),
                                              withContentHandler: spy.handler))
        XCTAssertTrue(spy.calls.isEmpty, "waits for its image")
        XCTAssertTrue(makeHandler().didReceive(request("plain", native(messageId: "msg_2")), withContentHandler: spy.handler))
        XCTAssertEqual(badges(spy), [2])
        try XCTUnwrap(downloader.downloads.first).complete(.failure("HTTP 404"))
        XCTAssertEqual(badges(spy), [2, 2], "the last one shown carries the full count")
    }

    func test_expiry_deliversWithTheCount() throws {
        try appSettings()
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request("image", native(image: "https://cdn.salla.test/p.png")), withContentHandler: spy.handler))
        XCTAssertTrue(handler.serviceExtensionTimeWillExpire())
        XCTAssertEqual(badges(spy), [1])
    }

    func test_aReplacedRequest_isDeliveredWithTheCount() throws {
        try appSettings()
        let handler = makeHandler()
        let first = ContentHandlerSpy()
        let second = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request("r1", native(messageId: "msg_1", image: "https://cdn.salla.test/1.png")),
                                         withContentHandler: first.handler))
        XCTAssertTrue(handler.didReceive(request("r2", native(messageId: "msg_2")), withContentHandler: second.handler))
        XCTAssertEqual(badges(first), [2], "delivered as the second one arrived, after it was counted")
        XCTAssertEqual(badges(second), [2])
    }

    func test_marksResetBeforeTheHandOver_leaveTheBadgeUnset_neverZero() throws {
        try appSettings()
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        XCTAssertTrue(handler.didReceive(request("image", native(image: "https://cdn.salla.test/p.png"), badge: 5),
                                         withContentHandler: spy.handler))
        try store().reset()
        try XCTUnwrap(downloader.downloads.first).complete(.failure("HTTP 404"))
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertNil(spy.calls.first?.badge, "nil leaves the icon as it is; 0 could hide the banner")
        XCTAssertFalse(entries.current.contains { $0.code == "nse.badge_set" })
    }

    func test_onTheMainThread_theNotificationIsCounted_withoutWaiting() throws {
        try appSettings()
        let handler = makeHandler()
        let spy = ContentHandlerSpy()
        let done = expectation(description: "main")
        DispatchQueue.main.async { [self] in
            XCTAssertTrue(handler.didReceive(request("r1"), withContentHandler: spy.handler))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(badges(spy), [1])
    }
}
