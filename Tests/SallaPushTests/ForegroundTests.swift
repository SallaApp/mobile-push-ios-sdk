import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

final class ForegroundTests: XCTestCase {
    private let native: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Order", "body": "Shipped"], "sound": "default", "badge": 1, "thread-id": "orders"],
        "sp_v": "1", "sp_id": "msg_ab12", "sp_url": "https://s.salla.sa/o/987", "orderId": "987",
    ]

    final class Listener: NSObject, SallaPushForegroundLifecycleListener, SallaPushClickListener, @unchecked Sendable {
        let prevent: Bool
        let displays = Locked(0)
        let clicks = Locked<[SallaPushClickEvent]>([])
        var lastEvent: SallaPushWillDisplayEvent?

        init(prevent: Bool) {
            self.prevent = prevent
        }

        func onWillDisplay(event: SallaPushWillDisplayEvent) {
            displays.withLock { $0 += 1 }
            lastEvent = event
            if prevent { event.preventDefault() }
        }

        func onClick(event: SallaPushClickEvent) {
            clicks.withLock { $0.append(event) }
        }
    }

    func test_foreign_isNil() {
        let h = Harness()
        XCTAssertNil(h.runtime.router.willPresent(userInfo: ["aps": ["alert": "other"], "moengage": [:]]))
        XCTAssertTrue(h.logs.contains("notif.foreign"))
        XCTAssertFalse(h.runtime.router.didReceive(identifier: "x", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                   userInfo: ["custom": ["i": "only-onesignal"]]))
        XCTAssertFalse(h.runtime.router.didReceiveRemoteNotification(userInfo: ["aps": ["content-available": 1]]))
    }

    func test_listenerPrevents_returnsEmpty_andDisplayShowsALocalCopyOnce() throws {
        let h = Harness()
        let listener = Listener(prevent: true)
        h.runtime.router.addForegroundListener(listener)
        let options = h.runtime.router.willPresent(userInfo: native)
        XCTAssertEqual(options, [])
        XCTAssertEqual(listener.displays.current, 1)
        let event = try XCTUnwrap(listener.lastEvent)
        XCTAssertTrue(event.isPrevented)
        h.runtime.router.display(event.notification)
        h.runtime.router.display(event.notification)
        let added = h.center.added
        XCTAssertEqual(added.count, 1)
        let copy = try XCTUnwrap(added.first)
        XCTAssertEqual(copy.identifier, "sallapush.local.msg_ab12")
        XCTAssertEqual(copy.title, "Order")
        XCTAssertEqual(copy.body, "Shipped")
        XCTAssertEqual(copy.sound, "default")
        XCTAssertEqual(copy.threadId, "orders")
        XCTAssertEqual(copy.userInfo["sp_local"] as? String, "1")
        // The local copy skips the listeners and gets the default options.
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: copy.userInfo), [.banner, .list, .sound, .badge])
        XCTAssertEqual(listener.displays.current, 1)
    }

    /// After preventDefault(), display() is the notification's display, and a tap on the copy its
    /// open, as on Android: `displayed` and `opened` are recorded (once each, by the persisted dedupe), never a second
    /// `received`; the click is delivered. A copy dismissed records `dismissed` and no click.
    func test_displayedCopy_recordsDisplayedAndOpened_neverASecondReceived() throws {
        let h = Harness()
        h.registered()
        let listener = Listener(prevent: true)
        h.runtime.router.addForegroundListener(listener)
        h.runtime.router.addClickListener(listener)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [])
        h.runtime.router.display(try XCTUnwrap(listener.lastEvent).notification)
        let copy = try XCTUnwrap(h.center.added.first)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: copy.userInfo), [.banner, .list, .sound])
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: copy.userInfo), [.banner, .list, .sound])
        XCTAssertTrue(h.runtime.router.didReceive(identifier: copy.identifier, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                  userInfo: copy.userInfo))
        h.settle()
        h.advance(6)
        XCTAssertEqual(listener.clicks.current.count, 1)
        XCTAssertEqual(listener.displays.current, 1, "the copy skips the listeners")
        let sent = h.server.requests("events").flatMap { $0.json["events"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["received", "displayed", "opened"])
        XCTAssertEqual(Set(sent.compactMap { $0["notification_id"] as? String }), ["msg_ab12"])

        let dismissed = Harness()
        dismissed.registered()
        let preventing = Listener(prevent: true)
        dismissed.runtime.router.addForegroundListener(preventing)
        dismissed.runtime.router.addClickListener(preventing)
        _ = dismissed.runtime.router.willPresent(userInfo: native)
        dismissed.runtime.router.display(try XCTUnwrap(preventing.lastEvent).notification)
        let dismissedCopy = try XCTUnwrap(dismissed.center.added.first)
        _ = dismissed.runtime.router.didReceive(identifier: dismissedCopy.identifier,
                                                actionIdentifier: UNNotificationDismissActionIdentifier,
                                                userInfo: dismissedCopy.userInfo)
        dismissed.settle()
        dismissed.advance(6)
        XCTAssertTrue(preventing.clicks.current.isEmpty)
        let types = dismissed.server.requests("events").flatMap { $0.json["events"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String }
        XCTAssertEqual(types, ["received", "dismissed"])
    }

    /// Every `display()` that shows nothing says why.
    func test_display_withoutPrevent_orAfter10Minutes_orTwice_doesNothing_andSaysWhy() throws {
        let h = Harness()
        let listener = Listener(prevent: false)
        h.runtime.router.addForegroundListener(listener)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [.banner, .list, .sound, .badge])
        let shown = try XCTUnwrap(listener.lastEvent)
        h.runtime.router.display(shown.notification)
        XCTAssertTrue(h.center.added.isEmpty)
        XCTAssertTrue(lastDisplayFailure(h).contains("preventDefault()"), lastDisplayFailure(h))

        let preventing = Listener(prevent: true)
        h.runtime.router.removeForegroundListener(listener)
        h.runtime.router.addForegroundListener(preventing)
        _ = h.runtime.router.willPresent(userInfo: native)
        let prevented = try XCTUnwrap(preventing.lastEvent)
        h.runtime.router.display(prevented.notification)
        XCTAssertEqual(h.center.added.count, 1)
        h.runtime.router.display(prevented.notification)
        XCTAssertEqual(h.center.added.count, 1)
        XCTAssertTrue(lastDisplayFailure(h).contains("already called"), lastDisplayFailure(h))

        _ = h.runtime.router.willPresent(userInfo: native)
        let late = try XCTUnwrap(preventing.lastEvent)
        h.clock.set(h.clock.now() + 601)
        h.runtime.router.display(late.notification)
        XCTAssertEqual(h.center.added.count, 1)
        XCTAssertTrue(lastDisplayFailure(h).contains("10 minutes"), lastDisplayFailure(h))
        XCTAssertTrue(h.logs.all.filter { $0.code == "notif.display_failed" }.allSatisfy { $0.level == .warn })
    }

    private func lastDisplayFailure(_ h: Harness) -> String {
        h.logs.all.last { $0.code == "notif.display_failed" }?.message ?? "none"
    }

    /// Whether the listeners prevented a notification is fixed when `willPresent` returns. A listener that keeps the
    /// event and calls `preventDefault()` later leaves it shown once: `display()` posts no second copy, and says why,
    /// as on the Android SDK.
    func test_aListenerThatPreventsAfterItsTime_leavesTheNotificationShownOnce_andDisplaySaysWhy() throws {
        let h = Harness()
        h.registered()
        let listener = Listener(prevent: false)
        h.runtime.router.addForegroundListener(listener)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [.banner, .list, .sound])
        let event = try XCTUnwrap(listener.lastEvent)
        event.preventDefault()
        XCTAssertTrue(event.isPrevented, "the flag records the call")
        h.runtime.router.display(event.notification)
        h.runtime.router.display(event.notification)
        h.settle()
        XCTAssertTrue(h.center.added.isEmpty, "the notification is never shown twice")
        XCTAssertEqual(lastDisplayFailure(h),
                       "Could not show the notification (it was prevented too late: willPresent had already answered to "
                           + "show it; call event.preventDefault() before the listener returns).")
        XCTAssertEqual(h.logs.count("notif.display_failed"), 2)
    }

    /// While the listeners run, `display()` right after `preventDefault()` posts the copy, as on the Android SDK; the
    /// default display is prevented, and a later `display()` posts nothing more.
    func test_display_fromInsideTheListener_rightAfterPreventDefault_showsItOnce() throws {
        let h = Harness()
        let router = h.runtime.router
        let seen = Locked<SallaPushWillDisplayEvent?>(nil)
        let observation = router.addForegroundHandler { event in
            event.preventDefault()
            router.display(event.notification)
            seen.set(event)
        }
        XCTAssertEqual(router.willPresent(userInfo: native), [])
        XCTAssertEqual(h.center.added.count, 1)
        let event = try XCTUnwrap(seen.current)
        router.display(event.notification)
        XCTAssertEqual(h.center.added.count, 1)
        XCTAssertTrue(lastDisplayFailure(h).contains("already called"), lastDisplayFailure(h))
        observation.cancel()
    }

    /// A prevented notification is received but not displayed: `displayed` is recorded only
    /// when the options show it.
    func test_preventedNotification_recordsReceived_butNotDisplayed() {
        let h = Harness()
        h.registered()
        let listener = Listener(prevent: true)
        h.runtime.router.addForegroundListener(listener)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [])
        h.settle()
        h.advance(6)
        let types = h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        }
        XCTAssertEqual(types, ["received"])
    }

    func test_displayFailure_isLogged() throws {
        let h = Harness()
        h.center.addError = "denied"
        let listener = Listener(prevent: true)
        h.runtime.router.addForegroundListener(listener)
        _ = h.runtime.router.willPresent(userInfo: native)
        h.runtime.router.display(try XCTUnwrap(listener.lastEvent).notification)
        XCTAssertTrue(h.logs.contains("notif.display_failed"))
    }

    func test_closureListener_canPrevent() {
        let h = Harness()
        let observation = h.runtime.router.addForegroundHandler { event in event.preventDefault() }
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [])
        observation.cancel()
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [.banner, .list, .sound, .badge])
    }

    func test_optedOut_presentsNothing() {
        let h = Harness()
        h.registered()
        h.submit(.optOut)
        let listener = Listener(prevent: false)
        h.runtime.router.addForegroundListener(listener)
        XCTAssertEqual(h.runtime.router.willPresent(userInfo: native), [])
        XCTAssertEqual(listener.displays.current, 0)
        h.settle()
        h.advance(6)
        let types = h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        }
        XCTAssertEqual(types, ["received"])
        XCTAssertEqual(h.logs.all.filter { $0.code == "notif.suppressed" }.map(\.level), [.debug])
        XCTAssertEqual(h.logs.count("subscription.opted_out"), 1, "only for the optOut() call itself")
    }

    func test_objcTwin_writesThePointerOnlyForSallaPush() {
        var options: UNNotificationPresentationOptions = [.sound]
        XCTAssertTrue(SallaPushNotifications.write([.banner, .list], into: &options))
        XCTAssertEqual(options, [.banner, .list])
        XCTAssertFalse(SallaPushNotifications.write(nil, into: &options))
        XCTAssertEqual(options, [.banner, .list])
        XCTAssertTrue(SallaPushNotifications.write([], into: nil))
    }

    func test_launchURL_isOpened_whenAsked_httpsOnly() {
        let h = Harness()
        h.initialize { $0.openLaunchURLs = true }
        _ = h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: native)
        var insecure = native
        insecure["sp_url"] = "http://s.salla.sa/o/1"
        _ = h.runtime.router.didReceive(identifier: "r2", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: insecure)
        XCTAssertEqual(h.application.openedURLs.map(\.absoluteString), ["https://s.salla.sa/o/987"])
    }
}

final class ClickTests: XCTestCase {
    private let payload: [AnyHashable: Any] = ["sp_v": "1", "sp_id": "msg_cd34", "sp_url": "salla://p/1", "aps": ["alert": "x"]]

    /// The SDK never opens a launch URL unless `openLaunchURLs` is set; the URL goes to the click listeners.
    func test_launchURL_notOpened() {
        let h = Harness()
        let urls = Locked<[String?]>([])
        let observation = h.runtime.router.addClickHandler { event in urls.withLock { $0.append(event.result.url) } }
        h.initialize()
        let https: [AnyHashable: Any] = ["sp_v": "1", "sp_id": "msg_ab12", "sp_url": "https://s.salla.sa/o/987", "aps": ["alert": "x"]]
        _ = h.runtime.router.didReceive(identifier: "r", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: https)
        h.settle()
        XCTAssertTrue(h.application.openedURLs.isEmpty)
        XCTAssertEqual(urls.current, ["https://s.salla.sa/o/987"])
        observation.cancel()
    }

    func test_doubleForward_oneClick() {
        let h = Harness()
        let listener = ForegroundTests.Listener(prevent: false)
        h.runtime.router.addClickListener(listener)
        _ = h.runtime.router.didReceive(identifier: "req", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
        _ = h.runtime.router.didReceive(identifier: "req", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
        h.settle()
        XCTAssertEqual(listener.clicks.current.count, 1)
        XCTAssertEqual(listener.clicks.current.first?.result.url, "salla://p/1")
        XCTAssertNil(listener.clicks.current.first?.result.actionId)
        XCTAssertTrue(h.logs.contains("notif.click_delivered"))
    }

    /// The click dedupe remembers the last 50 taps, so a tap forwarded twice is one
    /// click even with 30 other taps in between; the 51st older one is forgotten.
    func test_repeatedTap_afterOtherTaps_isDeduplicated() {
        let h = Harness()
        let listener = ForegroundTests.Listener(prevent: false)
        h.runtime.router.addClickListener(listener)
        let tap = { (identifier: String) in
            _ = h.runtime.router.didReceive(identifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                            userInfo: self.payload)
        }
        tap("first")
        for index in 0..<30 { tap("other-\(index)") }
        tap("first")
        h.settle()
        XCTAssertEqual(listener.clicks.current.count, 31)
        for index in 30..<60 { tap("other-\(index)") }
        tap("first")
        h.settle()
        XCTAssertEqual(listener.clicks.current.count, 62, "after 50 newer taps the first is forgotten")
    }

    func test_coldStartClick_isKept_andDeliveredOnceToTheFirstListener() {
        let h = Harness()
        _ = h.runtime.router.didReceive(identifier: "req", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
        XCTAssertTrue(h.logs.contains("notif.click_queued"))
        let first = ForegroundTests.Listener(prevent: false)
        h.runtime.router.addClickListener(first)
        h.settle()
        XCTAssertEqual(first.clicks.current.count, 1)
        let second = ForegroundTests.Listener(prevent: false)
        h.runtime.router.addClickListener(second)
        h.settle()
        XCTAssertEqual(second.clicks.current.count, 0)
    }

    func test_queuedClicks_expireAfterFiveMinutes_andAreBounded() {
        let h = Harness()
        for index in 0..<15 {
            _ = h.runtime.router.didReceive(identifier: "req\(index)", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                            userInfo: payload)
        }
        let delivered = Locked(0)
        let observation = h.runtime.router.addClickHandler { _ in delivered.withLock { $0 += 1 } }
        h.settle()
        XCTAssertEqual(delivered.current, 10)
        observation.cancel()

        let late = Harness()
        _ = late.runtime.router.didReceive(identifier: "req", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
        late.clock.set(late.clock.now() + 301)
        let lateCount = Locked(0)
        let lateObservation = late.runtime.router.addClickHandler { _ in lateCount.withLock { $0 += 1 } }
        late.settle()
        XCTAssertEqual(lateCount.current, 0)
        lateObservation.cancel()
    }
}

final class ForegroundThreadingTests: XCTestCase {
    func test_offMainForwarding_doesNotTrap_warnsOnce_usesDefaults() {
        let h = Harness()
        let listener = ForegroundTests.Listener(prevent: true)
        h.runtime.router.addForegroundListener(listener)
        let payload: [AnyHashable: Any] = ["sp_v": "1", "sp_id": "msg_ef", "aps": ["alert": "x"]]
        let results = Locked<[UNNotificationPresentationOptions?]>([])
        let done = expectation(description: "background")
        let router = h.runtime.router
        DispatchQueue.global().async {
            results.withLock { $0.append(router.willPresent(userInfo: payload)) }
            results.withLock { $0.append(router.willPresent(userInfo: payload)) }
            _ = router.didReceive(identifier: "bg", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(results.current, [[.banner, .list, .sound, .badge], [.banner, .list, .sound, .badge]])
        XCTAssertEqual(listener.displays.current, 0)
        XCTAssertEqual(h.logs.count("notif.off_main_thread"), 1)
    }
}

/// The opt-in delegate class forwards to SallaPush, presents other SDKs'
/// notifications with the default options, and calls each completion exactly once. Real `UNNotification` and
/// `UNNotificationResponse` objects drive it (`SystemObjects`).
final class NotificationCenterDelegateTests: XCTestCase {
    // The delegate never reads the center, and a test process cannot get one (`UNUserNotificationCenter.current()`
    // needs an app bundle), so a null reference stands in for it.
    private let center = unsafeBitCast(0 as Int, to: UNUserNotificationCenter.self)
    private let native: [AnyHashable: Any] = ["sp_v": "1", "sp_id": "msg_ab12", "sp_url": "https://s.salla.sa/o/1",
                                              "aps": ["alert": "x"]]
    private let foreign: [AnyHashable: Any] = ["aps": ["alert": "x"], "custom": ["i": "onesignal-only"]]

    private func present(_ delegate: SallaPushNotificationCenterDelegate, _ userInfo: [AnyHashable: Any]) throws
        -> [UNNotificationPresentationOptions] {
        let notification = try XCTUnwrap(SystemObjects.notification(userInfo: userInfo))
        let calls = Locked<[UNNotificationPresentationOptions]>([])
        delegate.userNotificationCenter(center, willPresent: notification) { options in calls.withLock { $0.append(options) } }
        return calls.current
    }

    func test_willPresent_foreignGetsTheDefaultOptions_andEachCompletionRunsOnce() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        let delegate = SallaPushNotificationCenterDelegate()
        XCTAssertEqual(try present(delegate, foreign), [[.banner, .list, .sound, .badge]])
        XCTAssertEqual(try present(delegate, native), [[.banner, .list, .sound]], "autoClearBadge leaves out the badge")
        h.submit(.optOut)
        XCTAssertEqual(try present(delegate, native), [[]], "SallaPush decides for its own: opted out shows nothing")
        h.settle()
        h.advance(6)
        let types = h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        }
        XCTAssertEqual(Set(types), ["received", "displayed"])
    }

    func test_didReceive_forwards_andTheCompletionRunsOnce() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        let urls = Locked<[String?]>([])
        let observation = SallaPush.Notifications.addClickListener { event in urls.withLock { $0.append(event.result.url) } }
        let delegate = SallaPushNotificationCenterDelegate()
        for userInfo in [native, foreign] {
            let response = try XCTUnwrap(SystemObjects.response(userInfo: userInfo))
            let calls = Locked(0)
            delegate.userNotificationCenter(center, didReceive: response) { calls.withLock { $0 += 1 } }
            XCTAssertEqual(calls.current, 1)
        }
        h.settle()
        h.advance(6)
        XCTAssertEqual(urls.current, ["https://s.salla.sa/o/1"])
        let types = h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        }
        XCTAssertEqual(types, ["opened"])
        observation.cancel()
    }

    /// The public forwarding forms with real system objects.
    func test_publicForwarding_withRealSystemObjects() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        let notification = try XCTUnwrap(SystemObjects.notification(userInfo: native))
        XCTAssertEqual(SallaPush.Notifications.willPresent(notification), [.banner, .list, .sound])
        var options: UNNotificationPresentationOptions = []
        XCTAssertTrue(objcWillPresent(notification, &options))
        XCTAssertEqual(options, [.banner, .list, .sound])
        let other = try XCTUnwrap(SystemObjects.notification(userInfo: foreign))
        XCTAssertNil(SallaPush.Notifications.willPresent(other))
        let response = try XCTUnwrap(SystemObjects.response(actionIdentifier: UNNotificationDismissActionIdentifier,
                                                            userInfo: native))
        XCTAssertTrue(SallaPush.Notifications.didReceive(response))
        h.settle()
        h.advance(6)
        let types = Set(h.server.requests("events").flatMap { request in
            (request.json["events"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        })
        XCTAssertEqual(types, ["received", "displayed", "dismissed"])
    }
}
