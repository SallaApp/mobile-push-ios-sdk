import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// Runs `body` on its own thread; false when it did not return within `seconds` (a deadlock).
private func finishes(within seconds: Double, _ body: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        body()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success
}

/// An app closure or object released by SallaPush never runs its deinit inside an SDK lock. Each case
/// would deadlock on the non-recursive locks if it did; a deadlock fails the case instead of hanging the suite.
final class ReentrancyTests: XCTestCase {
    /// An app object that owns another observation of the same registry, as a view model or router does. Its deinit
    /// sets `released`, which proves a case really reached the release path.
    final class Owner: @unchecked Sendable {
        let observation = Locked<SallaPushObservation?>(nil)
        private let released: Locked<Bool>

        init(released: Locked<Bool>) {
            self.released = released
        }

        deinit {
            released.set(true)
        }
    }

    /// An observer whose deinit removes itself, the common Objective-C pattern.
    final class SelfRemovingObserver: NSObject, SallaPushUserObserver, SallaPushClickListener, @unchecked Sendable {
        func onUserStateDidChange(state: SallaPushUserChangedState) {}
        func onClick(event: SallaPushClickEvent) {}

        deinit {
            SallaPush.User.removeObserver(self)
            SallaPush.Notifications.removeClickListener(self)
        }
    }

    private let compat: [AnyHashable: Any] = ["aps": ["alert": "x"], "custom": ["i": "i", "a": ["push_ref": "msg_ab"]]]

    // The closure of each observation below is the only owner of its `Owner`, so removing that closure releases the
    // owner and, through its deinit, cancels the observation it holds.

    /// A subscription observation that owns a user observation (both in the observer hub).
    private func subscriptionObservation(released: Locked<Bool>) -> SallaPushObservation {
        let owner = Owner(released: released)
        owner.observation.set(SallaPush.User.addObserver { _ in })
        return SallaPush.User.pushSubscription.addObserver { _ in _ = owner }
    }

    /// A user observation that owns a login failure observation (both in the observer hub).
    private func userObservation(released: Locked<Bool>) -> SallaPushObservation {
        let owner = Owner(released: released)
        owner.observation.set(SallaPush.User.addLoginFailureHandler { _ in })
        return SallaPush.User.addObserver { _ in _ = owner }
    }

    /// A click observation that owns a foreground observation (both in the notification router).
    private func clickObservation(released: Locked<Bool>) -> SallaPushObservation {
        let owner = Owner(released: released)
        owner.observation.set(SallaPush.Notifications.addForegroundLifecycleListener { _ in })
        return SallaPush.Notifications.addClickListener { _ in _ = owner }
    }

    func test_cancellingAnObservation_thatOwnsAnotherOfTheSameRegistry_returns() {
        let h = Harness()
        h.installAsShared()
        let released = Locked(false)
        let subscription = UncheckedSendable(subscriptionObservation(released: released))
        XCTAssertFalse(released.current)
        XCTAssertTrue(finishes(within: 5) { subscription.value.cancel() }, "ObserverHub's lock was re-entered")
        XCTAssertTrue(released.current, "the cancel released the app object")
    }

    func test_cancellingAClickObservation_thatOwnsAForegroundObservation_returns() {
        let h = Harness()
        h.installAsShared()
        let released = Locked(false)
        let click = UncheckedSendable(clickObservation(released: released))
        XCTAssertFalse(released.current)
        XCTAssertTrue(finishes(within: 5) { click.value.cancel() }, "the router's lock was re-entered")
        XCTAssertTrue(released.current, "the cancel released the app object")
    }

    func test_releasingObservations_throughDeinit_returns_andForwardingStillWorks() {
        let h = Harness()
        h.installAsShared()
        let clickReleased = Locked(false)
        let userReleased = Locked(false)
        let holder = Locked<SallaPushObservation?>(clickObservation(released: clickReleased))
        let userHolder = Locked<SallaPushObservation?>(userObservation(released: userReleased))
        XCTAssertTrue(finishes(within: 5) {
            withExtendedLifetime(holder.exchange(nil)) {}
            withExtendedLifetime(userHolder.exchange(nil)) {}
        }, "a deinit re-entered an SDK lock")
        XCTAssertTrue(clickReleased.current && userReleased.current, "both app objects were released")
        let router = h.runtime.router
        let payload = UncheckedSendable(compat)
        XCTAssertTrue(finishes(within: 5) {
            _ = router.didReceive(identifier: "after", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                  userInfo: payload.value)
        }, "forwarding hangs after the release")
    }

    func test_selfRemovingObservers_areReleasedWithoutDeadlock_andPruned() {
        let h = Harness()
        h.installAsShared()
        let holder = Locked<SelfRemovingObserver?>(SelfRemovingObserver())
        if let observer = holder.current {
            SallaPush.User.addObserver(observer)
            SallaPush.Notifications.addClickListener(observer)
        }
        let router = h.runtime.router
        let payload = UncheckedSendable(compat)
        XCTAssertTrue(finishes(within: 5) {
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    withExtendedLifetime(holder.exchange(nil)) {}
                } else {
                    for index in 0..<200 {
                        _ = router.didReceive(identifier: "r\(index)", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                              userInfo: payload.value)
                    }
                }
            }
        })
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
    }

    func test_replacingTheLogHandler_releasesTheOldOneOutsideTheLock() {
        final class LogsOnDeinit: @unchecked Sendable {
            deinit {
                SallaPush.User.addTag(key: "", value: "x")
            }
        }
        let h = Harness()
        h.installAsShared()
        do {
            let owner = LogsOnDeinit()
            SallaPush.Debug.setLogHandler { _ in _ = owner }
        }
        XCTAssertTrue(finishes(within: 5) { SallaPush.Debug.setLogHandler(nil) }, "the logger's lock was re-entered")
        XCTAssertTrue(h.logs.contains("api.invalid_argument"), "the deinit ran and logged")
    }
}

/// The real system answers on its own threads (the notification center on a private queue, UIKit on
/// main). These cases deliver every system callback that way, so Thread Sanitizer sees the real cross-thread paths
/// (`swift test --sanitize=thread`, `xcodebuild test -enableThreadSanitizer YES`).
final class SystemThreadingTests: XCTestCase {
    func test_optInWhileStopping_hasNoDataRace() {
        for _ in 0..<40 {
            let h = Harness()
            h.useAsynchronousSystemCallbacks()
            h.center.status = .notDetermined
            h.initialize()
            guard let engine = h.engine else { return XCTFail("no engine") }
            h.runtime.submit(.optIn)
            engine.queue.async { engine.stop() }
            h.settle()
        }
    }

    func test_permissionReadsAndPrompts_racingAnAppIdSwitch() {
        let h = Harness()
        h.useAsynchronousSystemCallbacks()
        h.center.status = .notDetermined
        h.registered()
        let runtime = h.runtime
        DispatchQueue.concurrentPerform(iterations: 4) { lane in
            for index in 0..<50 {
                switch (lane + index) % 4 {
                case 0: runtime.submit(.optIn)
                case 1: runtime.submit(.refreshPermission)
                case 2: runtime.requestPermission(fallbackToSettings: index.isMultiple(of: 2), provisional: false, completion: nil)
                default:
                    if index == 25 { runtime.initialize(appId: "st_43_ios", configuration: SallaPushConfiguration()) }
                }
            }
        }
        h.settle()
        h.advance(120)
        XCTAssertEqual(h.runtime.appId, "st_43_ios")
        XCTAssertEqual(h.snapshot.permission, .authorized)
    }

    func test_backgroundTaskExpiry_onMain_racingStop() throws {
        for round in 0..<20 {
            let h = Harness()
            h.useAsynchronousSystemCallbacks()
            h.registered()
            h.server.script("update") { _ in .hold }
            h.submit(.setLanguage("en"))
            h.send(.didEnterBackground)
            h.advance(2)
            let engine = try XCTUnwrap(h.engine)
            let task = try XCTUnwrap(h.application.begunTasks.last, "round \(round)")
            h.application.expire(task)
            engine.queue.async { engine.stop() }
            h.settle()
            XCTAssertTrue(h.application.endedTasks.contains(task), "round \(round)")
        }
    }

    /// A whole session with system callbacks on other threads behaves exactly as with synchronous fakes.
    func test_fullSession_withSystemCallbacksOnOtherThreads() throws {
        let h = Harness()
        h.installAsShared()
        h.useAsynchronousSystemCallbacks()
        h.center.status = .notDetermined
        h.center.hasDelegateValue = false
        h.initialize()
        SallaPush.User.pushSubscription.optIn()
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.center.authorizationRequests, [false])
        XCTAssertEqual(h.server.requests("register").count, 1)
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        SallaPush.User.addTag(key: "plan", value: "gold")
        _ = h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: ["sp_v": "1", "sp_id": "msg_ab", "aps": ["alert": "x"]])
        h.advance(12)
        XCTAssertEqual(SallaPush.User.externalId, "cust_a")
        XCTAssertEqual(h.server.device(h.deviceId)?.externalId, "cust_a")
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["plan": "gold"])
        XCTAssertEqual(h.server.requests("events").count, 1)
        h.send(.didBecomeActive)
        h.advance(3)
        XCTAssertEqual(h.logs.count("init.no_delegate"), 1)
        let granted = Locked<Bool?>(nil)
        SallaPush.Notifications.requestPermission(fallbackToSettings: false) { value in granted.set(value) }
        h.settle()
        XCTAssertEqual(granted.current, true)
        h.send(.didEnterBackground)
        h.settle()
        XCTAssertEqual(h.application.endedTasks, h.application.begunTasks)
        SallaPush.logout()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertNil(SallaPush.User.externalId)
    }
}
