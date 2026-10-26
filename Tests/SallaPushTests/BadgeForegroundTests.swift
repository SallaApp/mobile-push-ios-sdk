import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// The badge while the app is open: `willPresent` leaves out `.badge` while `autoClearBadge` is on, a notification the
/// badge doesn't show leaves the count, a tap lowers it at once, and `display()`'s copy carries SallaPush's badge.
final class BadgeForegroundTests: XCTestCase {
    private var container: URL = FileManager.default.temporaryDirectory
    private let native: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Order", "body": "Shipped"], "sound": "default", "badge": 1],
        "sp_v": "1", "sp_id": "msg_ab12",
    ]

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-badge-fg-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func started(autoClearBadge: Bool = true, autoUpdateBadge: Bool = true, consent: Bool = false) -> Harness {
        let h = Harness()
        h.appGroupContainer.set(container)
        if consent { h.runtime.setConsentGiven(true) }
        h.initialize { configuration in
            configuration.appGroupIdentifier = BadgeTests.group
            configuration.autoClearBadge = autoClearBadge
            configuration.autoUpdateBadge = autoUpdateBadge
            configuration.requiresUserConsent = consent
        }
        return h
    }

    private func store() throws -> BadgeStore {
        try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: "com.salla.test"))
    }

    /// The extension counted request `identifier` as the notification arrived.
    private func counted(_ h: Harness, _ identifier: String) throws {
        XCTAssertEqual(try store().add(identifier: identifier, at: h.clock.now()), .added)
    }

    // MARK: - willPresent

    func test_withAutoClearBadge_theOptionsLeaveOutBadge_andTheMarkGoes() throws {
        let h = started()
        try counted(h, "r1")
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [.banner, .list, .sound])
        h.settle()
        XCTAssertEqual(try store().count(), 0, "the badge stays at 0 while the app is open")
    }

    func test_withAutoClearBadgeOff_theOptionsKeepBadge_andTheMarkStays() throws {
        let h = started(autoClearBadge: false)
        try counted(h, "r1")
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [.banner, .list, .sound, .badge])
        h.settle()
        XCTAssertEqual(try store().count(), 1)
    }

    func test_withAutoUpdateBadgeOff_autoClearBadgeStillLeavesOutBadge() throws {
        let h = started(autoUpdateBadge: false)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [.banner, .list, .sound])
    }

    func test_aNotificationHeldBack_isNotShown_andLeavesTheCount() throws {
        let h = started(autoClearBadge: false)
        let observation = h.runtime.router.addForegroundHandler { $0.preventDefault() }
        try counted(h, "r1")
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [])
        h.settle()
        XCTAssertEqual(try store().count(), 0)
        observation.cancel()
    }

    func test_whileOptedOut_theNotificationLeavesTheCount() throws {
        let h = started(autoClearBadge: false)
        h.submit(.optOut)
        try counted(h, "r1")
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [])
        h.settle()
        XCTAssertEqual(try store().count(), 0)
    }

    func test_thePublicForm_passesTheRequestId() throws {
        let h = started()
        h.installAsShared()
        try counted(h, "request-7")
        let notification = try XCTUnwrap(SystemObjects.notification(identifier: "request-7", userInfo: native))
        XCTAssertEqual(SallaPush.Notifications.willPresent(notification), [.banner, .list, .sound])
        h.settle()
        XCTAssertEqual(try store().count(), 0)
    }

    // MARK: - Taps

    func test_aTap_removesTheMark_andWithoutAutoClearBadgeSetsTheIconToTheCount() throws {
        let h = started(autoClearBadge: false)
        try counted(h, "r1")
        try counted(h, "r2")
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                  userInfo: native))
        h.settle()
        XCTAssertEqual(try store().count(), 1)
        XCTAssertEqual(h.center.badgeCounts.last, 1)
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "r2", actionIdentifier: UNNotificationDismissActionIdentifier,
                                                  userInfo: native))
        h.settle()
        XCTAssertEqual(try store().count(), 0, "a dismiss action lowers it too")
        XCTAssertEqual(h.center.badgeCounts.last, 0)
    }

    func test_aTap_withAutoClearBadge_removesTheMark_andLeavesTheIconToTheActivation() throws {
        let h = started()
        try counted(h, "r1")
        let counts = h.center.badgeCounts
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                  userInfo: native))
        h.settle()
        XCTAssertEqual(try store().count(), 0)
        XCTAssertEqual(h.center.badgeCounts, counts)
    }

    func test_aTapBeforeInitialize_changesNothing() throws {
        let h = Harness()
        h.appGroupContainer.set(container)
        try counted(h, "r1")
        XCTAssertTrue(h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                  userInfo: native))
        h.settle()
        XCTAssertEqual(try store().count(), 1, "the activation once SallaPush started corrects it")
        XCTAssertTrue(h.center.badgeCounts.isEmpty)
    }

    // MARK: - display()

    /// Shows a copy of `native` through `display()` and returns it.
    private func displayedCopy(_ h: Harness) throws -> LocalNotificationRequest {
        let seen = Locked<SallaPushWillDisplayEvent?>(nil)
        let observation = h.runtime.router.addForegroundHandler { event in
            event.preventDefault()
            seen.set(event)
        }
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [])
        h.runtime.router.display(try XCTUnwrap(seen.current).notification)
        h.settle()
        observation.cancel()
        return try XCTUnwrap(h.center.added.last)
    }

    func test_theCopy_withAutoClearBadgeOff_isCounted_andCarriesTheCount() throws {
        let h = started(autoClearBadge: false)
        try counted(h, "other")
        let copy = try displayedCopy(h)
        XCTAssertEqual(copy.identifier, "sallapush.local.msg_ab12")
        XCTAssertEqual(copy.badge, 2)
        XCTAssertEqual(try store().add(identifier: "sallapush.local.msg_ab12", at: h.clock.now()), .alreadyCounted)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: copy.userInfo, identifier: copy.identifier),
                       [.banner, .list, .sound, .badge])
        h.settle()
        XCTAssertEqual(try store().count(), 2, "the copy shows, and counts")
    }

    func test_theCopy_withAutoClearBadge_carriesNoBadge() throws {
        let h = started()
        let copy = try displayedCopy(h)
        XCTAssertNil(copy.badge)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: copy.userInfo, identifier: copy.identifier),
                       [.banner, .list, .sound])
        XCTAssertEqual(try store().count(), 0)
    }

    func test_theCopy_withAutoUpdateBadgeOff_carriesThePushsBadge() throws {
        let h = started(autoClearBadge: false, autoUpdateBadge: false)
        XCTAssertEqual(try displayedCopy(h).badge, 1)
        XCTAssertEqual(try store().count(), 0)
    }

    /// Consent withdrawn before the copy is counted: it isn't counted and carries the push's own badge, and once the
    /// withdrawal removed the badge files, no mark comes back.
    func test_theCopy_whenConsentIsWithdrawnBeforeItIsCounted_isNotCounted() throws {
        let h = started(autoClearBadge: false, consent: true)
        try counted(h, "other")
        let seen = Locked<SallaPushWillDisplayEvent?>(nil)
        let observation = h.runtime.router.addForegroundHandler { event in
            event.preventDefault()
            seen.set(event)
        }
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native, identifier: "r1"), [])
        h.settle()
        let notification = try XCTUnwrap(seen.current).notification
        let engine = try XCTUnwrap(h.engine)
        h.runtime.badge.queue.suspend()
        h.runtime.router.display(notification)
        h.runtime.setConsentGiven(false)
        h.runtime.controlQueue.sync {}
        engine.queue.sync {}
        h.runtime.badge.queue.resume()
        h.settle()
        observation.cancel()
        XCTAssertEqual(h.center.added.last?.badge, 1, "the push's own badge, not SallaPush's count of 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path), "no mark comes back")
    }
}
