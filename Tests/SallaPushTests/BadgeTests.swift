import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// The app's side of the badge: the settings it shares with the extension, the clear when the app becomes active, the
/// corrections from Notification Center without it, `clearAll()`, iOS 15's guarded 0, and consent.
final class BadgeTests: XCTestCase {
    static let group = "group.com.salla.test"
    private var container: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-badge-app-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    /// A harness whose app shares an App Group with its extension.
    private func harness() -> Harness {
        let h = Harness()
        h.appGroupContainer.set(container)
        return h
    }

    /// The app's badge files, as the extension sees them.
    private func store() throws -> BadgeStore {
        try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: "com.salla.test"))
    }

    private func start(_ h: Harness, autoClearBadge: Bool = true, autoUpdateBadge: Bool = true, appGroup: Bool = true,
                       consent: Bool = false) {
        h.initialize { configuration in
            configuration.appGroupIdentifier = appGroup ? Self.group : nil
            configuration.autoClearBadge = autoClearBadge
            configuration.autoUpdateBadge = autoUpdateBadge
            configuration.requiresUserConsent = consent
        }
    }

    static func notification(_ identifier: String, _ messageId: String = "msg_ab") -> DeliveredNotification {
        DeliveredNotification(identifier: identifier, userInfo: ["sp_v": "1", "sp_id": messageId])
    }

    static let moengage = DeliveredNotification(identifier: "moengage", userInfo: ["moengage": ["cid": "1"]])

    private func codes(_ h: Harness, _ code: String) -> [SallaPushLogEntry] {
        h.logs.all.filter { $0.code == code }
    }

    // MARK: - Settings for the extension

    func test_aStartWithConsent_writesTheSettings_forEachValue() throws {
        let counting = harness()
        start(counting)
        XCTAssertEqual(try store().readSettings(), BadgeSettings(autoUpdateBadge: true))
        XCTAssertEqual(try store().add(identifier: "a", at: counting.clock.now()), .added)

        let off = counting.relaunch()
        start(off, autoClearBadge: false, autoUpdateBadge: false)
        XCTAssertEqual(try store().readSettings(), BadgeSettings(autoUpdateBadge: false))
        XCTAssertEqual(try store().count(), 0, "with autoUpdateBadge off the marks go")
    }

    func test_withoutAnAppGroup_nothingIsWritten() throws {
        let h = harness()
        start(h, appGroup: false)
        XCTAssertNil(try store().readSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
    }

    // MARK: - The app becomes active

    func test_withAutoClearBadge_eachActivation_resetsTheCount_andSetsTheIconTo0() throws {
        let h = harness()
        start(h)
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now()), .added)
        XCTAssertEqual(store.add(identifier: "b", at: h.clock.now()), .added)
        let before = h.center.badgeResets
        h.send(.didBecomeActive)
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(h.center.badgeResets, before + 1)
        XCTAssertTrue(h.application.iconBadges.isEmpty, "iOS 16 and later: setBadgeCount only")
        let cleared = try XCTUnwrap(codes(h, "badge.cleared").last)
        XCTAssertEqual(cleared.level, .debug)
        XCTAssertEqual(cleared.category, "notifications")
    }

    func test_iOS15Path_clearsTheIconBadge() {
        let h = harness()
        h.center.supportsBadgeCount = false
        start(h)
        h.send(.didBecomeActive)
        XCTAssertTrue(h.application.calls.contains("setIconBadge:0"))
        XCTAssertTrue(h.center.badgeCounts.isEmpty)
    }

    func test_withAutoClearBadgeOff_andWithoutAnAppGroup_theIconIsNeverSet() {
        let h = harness()
        h.center.deliver([Self.notification("a")])
        start(h, autoClearBadge: false, appGroup: false)
        h.send(.didBecomeActive)
        h.send(.didEnterBackground)
        _ = h.runtime.router.didReceive(identifier: "a", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: Self.notification("a").userInfo)
        h.settle()
        XCTAssertTrue(h.center.badgeCounts.isEmpty)
        XCTAssertFalse(h.application.calls.contains { $0.hasPrefix("setIconBadge") })
    }

    func test_withAutoClearBadgeOff_anActivation_dropsTheMarksOfNotificationsNoLongerDelivered() throws {
        let h = harness()
        let store = try store()
        let now = h.clock.now()
        XCTAssertEqual(store.add(identifier: "a", at: now - 3_600), .added)
        XCTAssertEqual(store.add(identifier: "b", at: now - 3_600), .added)
        XCTAssertEqual(store.add(identifier: "c", at: now - 10), .added)
        h.center.deliver([Self.notification("a"), Self.moengage])
        start(h, autoClearBadge: false)
        XCTAssertEqual(store.count(), 2, "b left Notification Center; c may still be in the extension")
        XCTAssertEqual(h.center.badgeCounts.last, 2)
        let set = try XCTUnwrap(codes(h, "badge.set").last)
        XCTAssertEqual(set.level, .debug)
        XCTAssertEqual(set.metadata, [LogMetadataKey.count: "2"])
    }

    func test_withAutoClearBadgeOff_aDeliveredNotificationWithoutAMark_isCounted_butATappedOneIsNotAddedBack() throws {
        let h = harness()
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("a"), Self.notification("b", "msg_cd")])
        start(h, autoClearBadge: false)
        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(h.center.badgeCounts.last, 2)
        // A tap removes its mark at once; iOS takes the notification out of Notification Center a little later.
        _ = h.runtime.router.didReceive(identifier: "a", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: Self.notification("a").userInfo)
        h.settle()
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(h.center.badgeCounts.last, 1)
        h.send(.didBecomeActive)
        XCTAssertEqual(store.count(), 1, "the tapped notification isn't counted again")
        XCTAssertEqual(h.center.badgeCounts.last, 1)
    }

    func test_withAutoClearBadgeOff_goingToTheBackground_correctsTheCountToo() throws {
        let h = harness()
        start(h, autoClearBadge: false)
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now() - 3_600), .added)
        XCTAssertEqual(store.add(identifier: "b", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("b")])
        h.send(.didEnterBackground)
        XCTAssertEqual(store.count(), 1, "a was cleared in Notification Center")
        XCTAssertEqual(h.center.badgeCounts.last, 1)
    }

    func test_withAutoClearBadgeOn_goingToTheBackground_changesNothing() throws {
        let h = harness()
        start(h)
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now() - 3_600), .added)
        let counts = h.center.badgeCounts
        h.send(.didEnterBackground)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(h.center.badgeCounts, counts)
    }

    func test_iOS15_aCountAbove0_setsTheIconBadgeNumber() throws {
        let h = harness()
        h.center.supportsBadgeCount = false
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("a")])
        start(h, autoClearBadge: false)
        XCTAssertEqual(h.application.iconBadges, [1])
    }

    func test_iOS15_aCorrectionTo0_waitsWhileAnotherSDKsNotificationIsDelivered() throws {
        let h = harness()
        h.center.supportsBadgeCount = false
        h.center.deliver([Self.moengage])
        start(h, autoClearBadge: false)
        XCTAssertTrue(h.application.iconBadges.isEmpty)
        XCTAssertEqual(codes(h, "badge.zero_skipped").map(\.level), [.debug])
        h.center.deliver([])
        h.send(.didBecomeActive)
        XCTAssertEqual(h.application.iconBadges, [0])
    }

    /// A tap that brings the count to 0 reads Notification Center itself before it writes iOS 15's 0.
    func test_iOS15_aTapThatLeaves0_waitsWhileAnotherSDKsNotificationIsDelivered() throws {
        let h = harness()
        h.center.supportsBadgeCount = false
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("a"), Self.moengage])
        start(h, autoClearBadge: false)
        XCTAssertEqual(h.application.iconBadges, [1])
        XCTAssertTrue(codes(h, "badge.zero_skipped").isEmpty)
        _ = h.runtime.router.didReceive(identifier: "a", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: Self.notification("a").userInfo)
        h.settle()
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(h.application.iconBadges, [1], "a 0 would also remove the other SDK's notification")
        XCTAssertEqual(codes(h, "badge.zero_skipped").map(\.level), [.debug])
        XCTAssertEqual(store.add(identifier: "b", at: h.clock.now()), .added)
        h.center.deliver([Self.notification("b", "msg_cd")])
        _ = h.runtime.router.didReceive(identifier: "b", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: Self.notification("b", "msg_cd").userInfo)
        h.settle()
        XCTAssertEqual(h.application.iconBadges, [1, 0], "only SallaPush's notifications are delivered")
    }

    // MARK: - clearAll()

    func test_clearAll_removesOnlySallaPush() {
        let center = FakeNotificationCenter()
        center.deliver([
            DeliveredNotification(identifier: "native", userInfo: ["sp_v": "1", "sp_id": "msg_ab"]),
            DeliveredNotification(identifier: "onesignal", userInfo: ["custom": ["i": "x"]]),
            DeliveredNotification(identifier: "compat", userInfo: ["custom": ["i": "x", "a": ["push_ref": "msg_cd"]]]),
            DeliveredNotification(identifier: "moengage", userInfo: ["moengage": ["cid": "1"]]),
            DeliveredNotification(identifier: "local", userInfo: ["sp_v": "1", "sp_local": "1"]),
        ])
        let handed = Locked<[String]>([])
        DeliveredNotificationCleaner.clearSallaPushNotifications(using: center) { removed, delivered in
            handed.set(removed + ["of \(delivered.count)"])
        }
        XCTAssertEqual(center.removed, [["native", "compat", "local"]])
        XCTAssertEqual(handed.current, ["native", "compat", "local", "of 5"])
    }

    func test_clearAll_resetsTheCount_andSetsTheIconTo0() throws {
        let h = harness()
        h.installAsShared()
        start(h, autoClearBadge: false)
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now()), .added)
        h.center.deliver([Self.notification("a")])
        SallaPush.Notifications.clearAll()
        h.settle()
        XCTAssertEqual(h.center.removed.last, ["a"])
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(h.center.badgeCounts.last, 0)
    }

    func test_clearAll_withAutoUpdateBadgeOff_neverTouchesTheIcon() {
        let h = harness()
        h.installAsShared()
        start(h, autoClearBadge: false, autoUpdateBadge: false)
        h.center.deliver([Self.notification("a")])
        let counts = h.center.badgeCounts
        SallaPush.Notifications.clearAll()
        h.settle()
        XCTAssertEqual(h.center.removed.last, ["a"])
        XCTAssertEqual(h.center.badgeCounts, counts)
    }

    func test_clearAll_onIOS15_keepsTheIcon_whileAnotherSDKsNotificationIsDelivered() throws {
        let h = harness()
        h.installAsShared()
        h.center.supportsBadgeCount = false
        start(h)
        let icons = h.application.iconBadges
        h.center.deliver([Self.notification("native"), Self.moengage])
        SallaPush.Notifications.clearAll()
        h.settle()
        XCTAssertEqual(h.center.removed, [["native"]])
        XCTAssertEqual(h.application.iconBadges, icons, "a 0 would also remove the other SDK's notification")
        XCTAssertEqual(codes(h, "badge.zero_skipped").map(\.level), [.debug])
        h.center.deliver([Self.notification("native")])
        SallaPush.Notifications.clearAll()
        h.settle()
        XCTAssertEqual(h.application.iconBadges, icons + [0])
    }

    // MARK: - Consent

    /// The files an earlier launch left: the settings and two marks.
    private func earlierLaunchCounted(_ h: Harness) throws {
        let store = try store()
        XCTAssertTrue(store.writeSettings(BadgeSettings(autoUpdateBadge: true)))
        XCTAssertEqual(store.add(identifier: "a", at: h.clock.now()), .added)
        XCTAssertEqual(store.add(identifier: "b", at: h.clock.now()), .added)
    }

    func test_consentWaitedForAtInitialize_removesTheFiles_andSetsTheIconTo0Once() throws {
        let h = harness()
        try earlierLaunchCounted(h)
        start(h, consent: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        XCTAssertEqual(h.center.badgeCounts, [0])
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertEqual(h.center.badgeCounts, [0], "once")
    }

    func test_consentWithdrawn_removesTheFiles_andSetsTheIconTo0Once() throws {
        let h = harness()
        h.runtime.setConsentGiven(true)
        start(h, autoClearBadge: false, consent: true)
        XCTAssertNotNil(try store().readSettings())
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now()), .added)
        let counts = h.center.badgeCounts.count
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        XCTAssertEqual(Array(h.center.badgeCounts.dropFirst(counts)), [0])
        h.send(.didBecomeActive)
        XCTAssertEqual(Array(h.center.badgeCounts.dropFirst(counts)), [0], "no clearing while consent is withheld")
        h.runtime.setConsentGiven(true)
        h.settle()
        XCTAssertEqual(try store().readSettings(), BadgeSettings(autoUpdateBadge: true), "counting starts again")
    }

    /// On iOS 15 a withdrawal's 0 reads Notification Center itself, as `clearAll()`'s does.
    func test_iOS15_consentWithdrawn_setsTheIconTo0_onlyWhenNoOtherSDKsNotificationIsDelivered() throws {
        let h = harness()
        h.center.supportsBadgeCount = false
        h.runtime.setConsentGiven(true)
        start(h, autoClearBadge: false, consent: true)
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now()), .added)
        h.center.deliver([Self.notification("a"), Self.moengage])
        let icons = h.application.iconBadges
        let skipped = codes(h, "badge.zero_skipped").count
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        XCTAssertEqual(h.application.iconBadges, icons, "a 0 would also remove the other SDK's notification")
        XCTAssertEqual(codes(h, "badge.zero_skipped").count, skipped + 1)
        h.runtime.setConsentGiven(true)
        h.settle()
        h.center.deliver([Self.notification("a")])
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertEqual(h.application.iconBadges, icons + [0], "only SallaPush's notifications are delivered")
    }

    /// A correction waits for Notification Center's answer; one that a withdrawal and a new consent overtook changes
    /// nothing when the answer comes: counting starts again from 0.
    func test_aCorrectionOvertakenByAWithdrawalAndANewConsent_changesNothing() throws {
        let h = harness()
        h.runtime.setConsentGiven(true)
        start(h, autoClearBadge: false, consent: true)
        let engine = try XCTUnwrap(h.engine)
        let store = try store()
        h.center.deliver([Self.notification("a")])
        let answers = DispatchQueue(label: "test.delivered.answers")
        answers.suspend()
        h.center.callbackQueue.set(answers)
        h.lifecycle.send(.didBecomeActive)
        engine.queue.sync {}
        h.runtime.badge.queue.sync {}
        h.center.callbackQueue.set(nil)
        h.runtime.setConsentGiven(false)
        h.settle()
        h.runtime.setConsentGiven(true)
        h.settle()
        XCTAssertNotNil(store.readSettings(), "counting starts again")
        let counts = h.center.badgeCounts
        answers.resume()
        answers.sync {}
        h.settle()
        XCTAssertEqual(store.count(), 0, "the overtaken correction counts nothing")
        XCTAssertEqual(h.center.badgeCounts, counts)
    }

    func test_consentPaused_removesTheFiles_andStopsCounting() throws {
        let h = harness()
        start(h)
        XCTAssertNotNil(try store().readSettings())
        h.runtime.setConsentRequired(true)
        h.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        let counts = h.center.badgeCounts
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now()), .added)
        h.send(.didBecomeActive)
        _ = h.runtime.router.willPresent(userInfo: Self.notification("a").userInfo, identifier: "a")
        h.settle()
        XCTAssertEqual(try store().count(), 1, "neither counted nor cleared while consent is withheld")
        XCTAssertEqual(h.center.badgeCounts, counts)
    }

    /// `consent.json` can't be read before the first unlock, and such a file is never taken as "never given": the
    /// files stay, and nothing touches the icon, until the file is read and says consent isn't given.
    func test_anUnreadableConsentFile_keepsTheFiles_untilItIsReadAsNotGiven() throws {
        let h = harness()
        XCTAssertTrue(ConsentStore(files: FileStore(root: h.root)).save(false))
        try earlierLaunchCounted(h)
        h.protectedFiles.set(["consent.json"])
        start(h, consent: true)
        XCTAssertEqual(try store().count(), 2)
        XCTAssertNotNil(try store().readSettings())
        XCTAssertTrue(h.center.badgeCounts.isEmpty)
        XCTAssertTrue(h.application.iconBadges.isEmpty)
        h.protectedFiles.set([])
        h.send(.protectedDataAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        XCTAssertEqual(h.center.badgeCounts, [0])
    }

    // MARK: - Engines

    func test_anEngineTheAppSwitchedAwayFrom_neverChangesTheBadge() throws {
        let h = harness()
        start(h, autoClearBadge: false)
        let old = try XCTUnwrap(h.engine)
        h.initialize("st_43_ios") { $0.appGroupIdentifier = Self.group }
        XCTAssertTrue(old !== h.engine)
        old.queue.sync { old.configureBadge() }
        h.settle()
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now()), .added)
        let resets = h.center.badgeResets
        h.send(.didBecomeActive)
        XCTAssertEqual(try store().count(), 0, "the new engine's autoClearBadge applies")
        XCTAssertEqual(h.center.badgeResets, resets + 1)
    }
}

// MARK: - iOS 15's 0 waits for Notification Center

extension BadgeTests {
    /// On iOS 15, a tap left the count at 0, and Notification Center hasn't answered the read its 0 waits for yet:
    /// resuming the returned queue answers it.
    private func tapThatLeaves0WaitingForNotificationCenter() -> (Harness, DispatchQueue) {
        let h = harness()
        h.center.supportsBadgeCount = false
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("a")])
        start(h, autoClearBadge: false)
        XCTAssertEqual(h.application.iconBadges, [1])
        let answers = DispatchQueue(label: "test.delivered.answers")
        answers.suspend()
        h.center.callbackQueue.set(answers)
        _ = h.runtime.router.didReceive(identifier: "a", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: Self.notification("a").userInfo)
        h.runtime.badge.queue.sync {}
        h.center.callbackQueue.set(nil)
        return (h, answers)
    }

    func test_iOS15_aTapThatLeaves0_keepsTheIcon_whenANotificationIsCountedMeanwhile() throws {
        let store = try store()
        let (h, answers) = tapThatLeaves0WaitingForNotificationCenter()
        XCTAssertEqual(store.add(identifier: "b", at: h.clock.now()), .added, "the extension counts a new notification")
        answers.resume()
        answers.sync {}
        h.settle()
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(h.application.iconBadges, [1], "a 0 would also remove the new notification")
    }

    func test_iOS15_aTapThatLeaves0_writesNothing_onceNewSettingsOvertookIt() {
        let (h, answers) = tapThatLeaves0WaitingForNotificationCenter()
        h.initialize("st_43_ios") { configuration in
            configuration.appGroupIdentifier = Self.group
            configuration.autoClearBadge = false
            configuration.autoUpdateBadge = false
        }
        answers.resume()
        answers.sync {}
        h.settle()
        XCTAssertEqual(h.application.iconBadges, [1], "SallaPush no longer sets the badge")
    }

    /// A withdrawal's 0 on iOS 15 waits for Notification Center's answer; consent withheld again meanwhile doesn't drop
    /// it.
    func test_iOS15_aWithdrawalsZero_staysDue_whenConsentIsWithheldAgainMeanwhile() throws {
        let h = harness()
        h.center.supportsBadgeCount = false
        XCTAssertEqual(try store().add(identifier: "a", at: h.clock.now() - 3_600), .added)
        h.center.deliver([Self.notification("a")])
        h.runtime.setConsentGiven(true)
        start(h, autoClearBadge: false, consent: true)
        XCTAssertEqual(h.application.iconBadges, [1])
        let engine = try XCTUnwrap(h.engine)
        let answers = DispatchQueue(label: "test.delivered.answers")
        answers.suspend()
        h.center.callbackQueue.set(answers)
        for _ in 0..<2 {
            h.runtime.setConsentGiven(false)
            h.runtime.controlQueue.sync {}
            engine.queue.sync {}
            h.runtime.badge.queue.sync {}
        }
        h.center.callbackQueue.set(nil)
        answers.resume()
        answers.sync {}
        h.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().folder.path))
        XCTAssertEqual(h.application.iconBadges, [1, 0])
    }
}
