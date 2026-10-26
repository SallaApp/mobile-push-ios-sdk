import Foundation
import Security
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

final class PerformanceTests: XCTestCase {
    /// With the control queue blocked, `initialize` can only have done caller-thread work, and it did no I/O.
    func test_initialize_doesNoIO() {
        let h = Harness()
        let gate = DispatchSemaphore(value: 0)
        h.runtime.controlQueue.async { gate.wait() }
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        XCTAssertEqual(h.keychainAccess.readCount, 0)
        XCTAssertEqual(h.keychainAccess.writeCount, 0)
        XCTAssertEqual(h.bundle.readsOnMain, 0)
        XCTAssertEqual(h.center.readCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.path))
        XCTAssertTrue(h.application.calls.isEmpty)
        gate.signal()
        h.settle()
        XCTAssertEqual(h.keychainAccess.readsOnMain, 0)
        XCTAssertEqual(h.center.readsOnMain, 0)
        XCTAssertEqual(h.bundle.readsOnMain, 0)
        XCTAssertNotNil(h.engine)
    }

    func test_publicCalls_neverTouchStorageOnTheCallerThread() {
        let h = Harness()
        h.registered()
        h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.runtime.addTags(["a": "1"])
        h.runtime.logout()
        _ = h.runtime.snapshot
        h.settle()
        XCTAssertEqual(h.keychainAccess.readsOnMain, 0)
        XCTAssertEqual(h.center.readsOnMain, 0)
    }

    func test_steadyStateLaunch_sendsNothing() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let count = h.server.requests.count
        let next = h.relaunch()
        next.initialize()
        next.login("customer.token.a")
        next.sendToken()
        next.send(.willEnterForeground)
        next.send(.didBecomeActive)
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, count)
        let guest = Harness()
        guest.registered()
        let guestCount = guest.server.requests.count
        let guestNext = guest.relaunch()
        guestNext.initialize()
        guestNext.logout()
        guestNext.sendToken()
        guestNext.advance(30)
        XCTAssertEqual(guestNext.server.requests.count, guestCount)
    }

    /// A guest with tags, at a steady-state cold start with the launch logout(), sends nothing and keeps
    /// its tags.
    func test_steadyStateLaunch_guestWithTags_sendsNothing_andKeepsTags() throws {
        let h = Harness()
        h.registered()
        h.logout()
        h.submit(.addTags(["add_to_cart": "1790000000000"]))
        h.advance(12)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["add_to_cart": "1790000000000"])
        let before = h.server.requests.count
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.sendToken()
        next.send(.willEnterForeground)
        next.send(.didBecomeActive)
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, before, "sent: \(next.server.templates.suffix(3))")
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["add_to_cart": "1790000000000"])
        XCTAssertEqual(next.snapshot.tags, ["add_to_cart": "1790000000000"])
        let skipped = try XCTUnwrap(next.logs.all.first { $0.code == "logout.skipped" })
        XCTAssertEqual(skipped.level, .debug)
        XCTAssertEqual(skipped.category, "identity")
    }
}

final class TokenTests: XCTestCase {
    func test_tokenHex_isLowercaseHex() throws {
        let token = try XCTUnwrap(PushToken(deviceToken: Data([0x0A, 0xFF, 0x00, 0x7B, 0xC4] + Array(repeating: 0xAB, count: 27))))
        XCTAssertTrue(token.hex.hasPrefix("0aff007bc4"))
        XCTAssertEqual(token.hex, token.hex.lowercased())
    }

    /// The same token from the app delegate and from another SDK sends nothing more.
    func test_sameTokenTwice_noop() {
        let h = Harness()
        h.registered()
        h.sendToken()
        h.sendToken()
        h.advance(30)
        XCTAssertEqual(h.server.templates, ["register"])
        XCTAssertEqual(h.logs.count("token.received"), 1)
    }

    func test_invalidToken_isIgnored_withAWarning() {
        let h = Harness()
        Runtime.install(h.runtime)
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: Data())
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: Data(repeating: 1, count: 8))
        h.initialize()
        h.advance(5)
        XCTAssertEqual(h.logs.count("token.invalid"), 2)
        XCTAssertTrue(h.server.requests.isEmpty)
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: Harness.token(4))
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").first?.json["push_token"] as? String, Harness.tokenHex(4))
    }

    func test_registrationFailure_isLoggedWithTheReason() {
        let h = Harness()
        Runtime.install(h.runtime)
        h.initialize()
        SallaPush.Notifications.didFailToRegisterForRemoteNotifications(
            error: NSError(domain: "APNs", code: 3_000, userInfo: [NSLocalizedDescriptionKey: "no valid aps-environment"]))
        h.settle()
        let entry = h.logs.all.first { $0.code == "token.registration_failed" }
        XCTAssertEqual(entry?.message.contains("APNs 3000"), true)
    }

    func test_tokenMissing_warnsAfter30sInTheForeground() {
        let h = Harness()
        h.initialize()
        h.advance(29)
        XCTAssertFalse(h.logs.contains("token.missing"))
        h.advance(2)
        XCTAssertEqual(h.logs.count("token.missing"), 1)
        let withToken = Harness()
        withToken.initialize()
        withToken.sendToken()
        withToken.advance(60)
        XCTAssertFalse(withToken.logs.contains("token.missing"))
    }
}

final class ObserverTests: XCTestCase {
    final class SubscriptionSpy: NSObject, SallaPushSubscriptionObserver, SallaPushPermissionObserver, SallaPushUserObserver,
                                 @unchecked Sendable {
        let changes = Locked<[SallaPushSubscriptionChangedState]>([])
        let permissions = Locked<[Bool]>([])
        let users = Locked<[SallaPushUserChangedState]>([])
        let failures = Locked<[SallaPushLoginFailure]>([])

        func onPushSubscriptionDidChange(state: SallaPushSubscriptionChangedState) {
            changes.withLock { $0.append(state) }
        }

        func onNotificationPermissionDidChange(_ permission: Bool) {
            permissions.withLock { $0.append(permission) }
        }

        func onUserStateDidChange(state: SallaPushUserChangedState) {
            users.withLock { $0.append(state) }
        }

        func onLoginFailure(_ failure: SallaPushLoginFailure) {
            failures.withLock { $0.append(failure) }
        }
    }

    func test_subscriptionObserver_replaysOnce_whenRegistered() {
        let h = Harness()
        Runtime.install(h.runtime)
        let early = SubscriptionSpy()
        SallaPush.User.pushSubscription.addObserver(early)
        h.settle()
        XCTAssertTrue(early.changes.current.isEmpty, "no replay before registration")
        h.registered()
        XCTAssertNotNil(early.changes.current.last?.current.id)
        let late = SubscriptionSpy()
        SallaPush.User.pushSubscription.addObserver(late)
        XCTAssertTrue(late.changes.current.isEmpty, "the replay arrives after add returns")
        h.settle()
        XCTAssertEqual(late.changes.current.count, 1)
        XCTAssertEqual(late.changes.current.first?.previous.id, late.changes.current.first?.current.id)
        let replays = Locked(0)
        let observation = SallaPush.User.pushSubscription.addObserver { _ in replays.withLock { $0 += 1 } }
        h.settle()
        XCTAssertEqual(replays.current, 1)
        observation.cancel()
        SallaPush.User.pushSubscription.removeObserver(late)
    }

    /// A change published between `addObserver` and the replay's delivery is never followed by an older
    /// state: the replay carries the state at delivery.
    func test_subscriptionReplay_carriesTheStateAtDelivery() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        let spy = SubscriptionSpy()
        SallaPush.User.pushSubscription.addObserver(spy)
        let replays = Locked<[SallaPushSubscriptionChangedState]>([])
        let observation = SallaPush.User.pushSubscription.addObserver { state in replays.withLock { $0.append(state) } }
        // Main has not run yet: the replays are queued. A new token is published before they are delivered.
        let engine = try XCTUnwrap(h.engine)
        h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex(7))))
        engine.queue.sync {}
        XCTAssertTrue(spy.changes.current.isEmpty)
        h.settle()
        let replay = try XCTUnwrap(spy.changes.current.first)
        XCTAssertEqual(replay.current.token, Harness.tokenHex(7), "the replay carries the current state")
        XCTAssertEqual(replay.previous.token, replay.current.token)
        XCTAssertEqual(spy.changes.current.last?.current.token, Harness.tokenHex(7))
        XCTAssertEqual(replays.current.first?.current.token, Harness.tokenHex(7))
        observation.cancel()
        SallaPush.User.pushSubscription.removeObserver(spy)
    }

    func test_permissionObserver_firesOnChange_withoutReplay() {
        let h = Harness()
        Runtime.install(h.runtime)
        let spy = SubscriptionSpy()
        SallaPush.Notifications.addPermissionObserver(spy)
        h.registered()
        XCTAssertTrue(spy.permissions.current.isEmpty)
        h.center.status = .denied
        h.send(.didBecomeActive)
        XCTAssertEqual(spy.permissions.current, [false])
        XCTAssertFalse(SallaPush.Notifications.permission)
        XCTAssertEqual(SallaPush.Notifications.permissionStatus, .denied)
        XCTAssertFalse(SallaPush.Notifications.canRequestPermission)
        SallaPush.Notifications.removePermissionObserver(spy)
    }

    func test_userObserver_andLoginFailure_protocolForms() {
        let h = Harness()
        Runtime.install(h.runtime)
        h.server.customers = { _ in .rejected }
        let spy = SubscriptionSpy()
        SallaPush.User.addObserver(spy)
        h.registered()
        SallaPush.login(externalId: "cust_a", identityToken: "stale.token")
        h.advance(2)
        XCTAssertEqual(spy.failures.current, [.tokenRejected])
        XCTAssertEqual(spy.users.current.first?.current.isLoggedIn, true)
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        SallaPush.User.removeObserver(spy)
        SallaPush.logout()
        h.settle()
        XCTAssertEqual(spy.users.current.count, 1)
    }

    /// At a steady-state cold start, restoring what the last launch left is no change.
    /// Observers added before `initialize`: the user observer hears nothing, the subscription observer gets one replay
    /// (`previous == current`); a real change afterwards is still reported.
    func test_coldStart_restoresSilently_andReplaysOnceForSubscriptionObservers() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let requests = h.server.requests.count
        let next = h.relaunch()
        next.installAsShared()
        let users = Locked<[SallaPushUserChangedState]>([])
        let subscriptions = Locked<[SallaPushSubscriptionChangedState]>([])
        let userObservation = SallaPush.User.addObserver { change in users.withLock { $0.append(change) } }
        let subscriptionObservation = SallaPush.User.pushSubscription.addObserver { change in
            subscriptions.withLock { $0.append(change) }
        }
        next.initialize()
        SallaPush.login(externalId: next.server.customer(of: "customer.token.a"), identityToken: "customer.token.a")
        next.sendToken()
        next.advance(5)
        XCTAssertEqual(next.server.requests.count, requests, "a steady-state launch")
        XCTAssertTrue(users.current.isEmpty, "\(users.current.map { "\($0.previous.isLoggedIn) -> \($0.current.isLoggedIn)" })")
        XCTAssertEqual(subscriptions.current.count, 1)
        let replay = try XCTUnwrap(subscriptions.current.first)
        XCTAssertNotNil(replay.current.id)
        XCTAssertEqual(replay.previous.id, replay.current.id)
        XCTAssertEqual(replay.previous.optedIn, replay.current.optedIn)
        SallaPush.logout()
        next.advance(3)
        XCTAssertEqual(users.current.count, 1)
        XCTAssertEqual(users.current.first?.previous.isLoggedIn, true)
        XCTAssertEqual(users.current.first?.current.isLoggedIn, false)
        userObservation.cancel()
        subscriptionObservation.cancel()
    }

    func test_observation_cancelsOnDeinit() {
        let h = Harness()
        let calls = Locked(0)
        var observation: SallaPushObservation? = h.runtime.observers.addUserHandler { _ in calls.withLock { $0 += 1 } }
        XCTAssertNotNil(observation)
        observation = nil
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        XCTAssertEqual(calls.current, 0)
    }
}

/// The permission getters read the system status right after `initialize`, also while consent is pending,
/// never report an unknown status as "can still prompt", and are current inside the request completion.
final class PermissionGetterTests: XCTestCase {
    func test_getters_whileConsentIsPending_readTheSystemStatus() {
        let h = Harness()
        h.installAsShared()
        h.center.status = .denied
        h.runtime.setConsentRequired(true)
        h.initialize()
        h.advance(5)
        XCTAssertNil(h.engine, "consent is pending")
        XCTAssertEqual(SallaPush.Notifications.permissionStatus, .denied)
        XCTAssertFalse(SallaPush.Notifications.canRequestPermission)
        XCTAssertFalse(SallaPush.Notifications.permission)
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertEqual(h.keychainAccess.readCount, 0, "a read of the status, nothing stored")
    }

    func test_canRequestPermission_isFalse_untilTheStatusIsKnown() {
        let h = Harness()
        h.installAsShared()
        h.center.status = .notDetermined
        XCTAssertFalse(SallaPush.Notifications.canRequestPermission, "unknown before initialize")
        XCTAssertFalse(SallaPush.Notifications.permission)
        h.initialize()
        XCTAssertTrue(SallaPush.Notifications.canRequestPermission)
    }

    /// The read `initialize` starts for the getters is an XPC round trip that can answer after the
    /// engine's own, later read. The older answer never replaces the newer one, and nobody is told of a change.
    func test_aSlowInitializeRead_neverReplacesTheEnginesNewerRead() throws {
        let h = Harness()
        h.center.status = .denied
        h.keychainAccess.forcedReadStatus = errSecInteractionNotAllowed
        let slow = DispatchQueue(label: "test.slow.initialize.read")
        slow.suspend()
        h.center.callbackQueue.set(slow)
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        h.runtime.controlQueue.sync {}
        h.center.callbackQueue.set(nil)
        h.settle()
        XCTAssertEqual(h.center.readCount, 1, "the initialize read is on its way")
        XCTAssertNil(h.runtime.snapshot.permission, "and has not answered")
        h.center.status = .authorized
        h.keychainAccess.forcedReadStatus = nil
        h.send(.protectedDataAvailable)
        XCTAssertEqual(h.runtime.snapshot.permission, .authorized)
        let grants = Locked<[Bool]>([])
        let observation = h.runtime.observers.addPermissionHandler { granted in grants.withLock { $0.append(granted) } }
        slow.resume()
        slow.sync {}
        h.settle()
        XCTAssertEqual(h.runtime.snapshot.permission, .authorized, "the older .denied answer is ignored")
        XCTAssertTrue(grants.current.isEmpty)
        observation.cancel()
    }

    /// What a completion saw.
    private struct Seen {
        let granted: Bool
        let permission: Bool
        let status: UNAuthorizationStatus
        let canRequest: Bool
    }

    func test_gettersInsideTheRequestCompletion_areCurrent() {
        for asynchronous in [false, true] {
            let h = Harness()
            h.installAsShared()
            if asynchronous { h.useAsynchronousSystemCallbacks() }
            h.center.status = .notDetermined
            h.initialize()
            let seen = Locked<Seen?>(nil)
            SallaPush.Notifications.requestPermission(fallbackToSettings: false) { granted in
                seen.set(Seen(granted: granted, permission: SallaPush.Notifications.permission,
                              status: SallaPush.Notifications.permissionStatus,
                              canRequest: SallaPush.Notifications.canRequestPermission))
            }
            h.settle()
            XCTAssertEqual(seen.current?.granted, true)
            XCTAssertEqual(seen.current?.permission, true, "asynchronous: \(asynchronous)")
            XCTAssertEqual(seen.current?.status, .authorized)
            XCTAssertEqual(seen.current?.canRequest, false)
        }
    }

    func test_fallbackToSettings_whenDenied_opensSettings_andReportsDenied() {
        let h = Harness()
        h.installAsShared()
        h.center.status = .denied
        h.initialize()
        let result = Locked<Bool?>(nil)
        SallaPush.Notifications.requestPermission(fallbackToSettings: true) { granted in result.set(granted) }
        h.settle()
        XCTAssertEqual(result.current, false)
        XCTAssertTrue(h.application.calls.contains("openNotificationSettings"))
        XCTAssertTrue(h.center.authorizationRequests.isEmpty)
        XCTAssertEqual(SallaPush.Notifications.permissionStatus, .denied)
    }

    /// An engine publish carrying its older permission read (here for a tag queued before
    /// the grant) never replaces the grant: one callback, and the getters stay granted.
    func test_aGrant_isNeverReplacedByAnOlderEngineRead() throws {
        let h = Harness()
        h.installAsShared()
        h.center.status = .notDetermined
        h.registered()
        XCTAssertEqual(h.snapshot.permission, .notDetermined)
        let grants = Locked<[Bool]>([])
        let observation = SallaPush.Notifications.addPermissionObserver { granted in grants.withLock { $0.append(granted) } }
        let optedIn = Locked<[Bool]>([])
        let subscription = SallaPush.User.pushSubscription.addObserver { change in
            optedIn.withLock { $0.append(change.current.optedIn) }
        }
        h.settle()
        optedIn.set([])
        let engine = try XCTUnwrap(h.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        h.runtime.addTags(["add_to_cart": "1"])
        h.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        XCTAssertEqual(h.runtime.snapshot.permission, .authorized)
        gate.signal()
        h.settle()
        h.advance(12)
        XCTAssertEqual(grants.current, [true])
        XCTAssertEqual(optedIn.current, [true])
        XCTAssertEqual(h.snapshot.permission, .authorized)
        XCTAssertEqual(h.server.requests("update").last?.json["opted_in"] as? Bool, true)
        observation.cancel()
        subscription.cancel()
    }

    /// System callbacks on their own queue, the engine's own read answering a few
    /// milliseconds after the request's, and an app completion that calls SallaPush. Exactly one permission callback,
    /// one subscription callback, and a granted getter throughout.
    func test_requestPermission_withADelayedEngineRead_notifiesOnce_andTheGetterStaysGranted() throws {
        let h = Harness()
        h.installAsShared()
        h.center.status = .notDetermined
        h.registered()
        let callbacks = DispatchQueue(label: "test.system.callbacks.slow")
        h.useAsynchronousSystemCallbacks(on: callbacks)
        let grants = Locked<[Bool]>([])
        let observation = SallaPush.Notifications.addPermissionObserver { granted in grants.withLock { $0.append(granted) } }
        let optedIn = Locked<[Bool]>([])
        let subscription = SallaPush.User.pushSubscription.addObserver { change in
            optedIn.withLock { $0.append(change.current.optedIn) }
        }
        h.settle()
        optedIn.set([])
        let engine = try XCTUnwrap(h.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        let inCompletion = Locked<Bool?>(nil)
        SallaPush.Notifications.requestPermission(fallbackToSettings: false) { _ in
            inCompletion.set(SallaPush.Notifications.permission)
            SallaPush.User.addTag(key: "push_prompted", value: "1")
        }
        // The status read, the prompt and the read after it.
        callbacks.sync {}
        callbacks.sync {}
        callbacks.sync {}
        h.runtime.controlQueue.sync {}
        // getNotificationSettings is an XPC round trip: the engine's own read answers later.
        callbacks.suspend()
        gate.signal()
        engine.queue.sync {}
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        engine.queue.sync {}
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        let between = SallaPush.Notifications.permission
        callbacks.resume()
        h.settle()
        XCTAssertEqual(inCompletion.current, true)
        XCTAssertTrue(between)
        XCTAssertEqual(grants.current, [true])
        XCTAssertEqual(optedIn.current, [true])
        XCTAssertTrue(SallaPush.Notifications.permission)
        observation.cancel()
        subscription.cancel()
    }

    func test_permissionObservers_hearAGrantFromTheRequest_once() {
        let h = Harness()
        h.installAsShared()
        h.center.status = .denied
        h.registered()
        let grants = Locked<[Bool]>([])
        let observation = SallaPush.Notifications.addPermissionObserver { granted in grants.withLock { $0.append(granted) } }
        h.center.grantOnRequest = true
        h.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        h.settle()
        h.advance(2)
        XCTAssertEqual(grants.current, [true])
        observation.cancel()
    }
}
