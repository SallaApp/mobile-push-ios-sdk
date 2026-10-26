import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class FacadeTests: XCTestCase {
    func test_tokenBeforeInitialize_replayed() {
        let h = Harness()
        h.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
        XCTAssertTrue(h.server.requests.isEmpty)
        h.initialize()
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    func test_everyCallBeforeInitialize_isReplayedInOrder() throws {
        let h = Harness()
        h.runtime.logout()
        h.runtime.addTags(["Cart": "1"])
        h.runtime.submit(.setLanguage("en"))
        h.runtime.submit(.optOut)
        h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
        h.settle()
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertFalse(h.runtime.isInitialized)
        h.initialize()
        XCTAssertTrue(h.runtime.isInitialized)
        XCTAssertEqual(h.runtime.appId, "st_42_ios")
        h.advance(12)
        XCTAssertEqual(h.server.templates, ["register", "link", "tags"])
        let register = try XCTUnwrap(h.server.requests("register").first?.json)
        XCTAssertEqual(register["language"] as? String, "en")
        XCTAssertEqual(register["opted_in"] as? Bool, false)
        XCTAssertEqual(h.server.requests("link").first?.json["external_id"] as? String, "cust_a")
        XCTAssertEqual(h.server.requests("tags").first?.json["add"] as? [String: String], ["cart": "1"])
    }

    func test_bufferOverflow_keepsIdentityCalls() throws {
        let h = Harness()
        h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.runtime.logout()
        h.runtime.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        for index in 0..<150 {
            h.runtime.addTags(["k\(index)": "v"])
        }
        h.settle()
        XCTAssertFalse(h.logs.contains("init.buffer_full"), "reported when the buffer is replayed, with the totals")
        h.registered()
        let report = try XCTUnwrap(h.logs.all.first { $0.code == "init.buffer_full" })
        XCTAssertEqual(h.logs.count("init.buffer_full"), 1)
        XCTAssertEqual(report.message, "Too many calls before SallaPush started; 52 tag/language/opt-in calls were dropped "
                       + "(login/logout calls are kept).")
        XCTAssertEqual(report.metadata["count"], "52")
        h.advance(12)
        XCTAssertEqual(h.server.requests("link").map { $0.json["external_id"] as? String }, ["cust_b"])
        let sentTags = h.server.requests("tags").first?.json["add"] as? [String: String] ?? [:]
        XCTAssertLessThanOrEqual(sentTags.count, 100)
        XCTAssertNotNil(sentTags["k149"], "the newest tag calls are kept")
        XCTAssertNil(sentTags["k0"], "the oldest are dropped")
    }

    /// An overflow of buffered notification events says so, with the count.
    func test_bufferOverflow_ofEventsOnly_reportsTheEvents() throws {
        let h = Harness()
        for index in 0..<60 {
            h.runtime.submit(.events([EventRecord(messageId: "msg_\(String(index + 1, radix: 16))", type: .received,
                                                  at: h.clock.now(), actionId: nil)]))
        }
        h.initialize()
        let entry = try XCTUnwrap(h.logs.all.first { $0.code == "init.buffer_full" })
        XCTAssertEqual(entry.message, "Too many calls before SallaPush started; 10 notification events were dropped "
                       + "(login/logout calls are kept).")
        XCTAssertEqual(entry.metadata["count"], "10")
    }

    func test_bufferOverflow_ofOneCall_isReportedInTheSingular() throws {
        let h = Harness()
        h.runtime.reportDropped(PreInitBuffer.Dropped(calls: 1, events: 0))
        let entry = try XCTUnwrap(h.logs.all.last { $0.code == "init.buffer_full" })
        XCTAssertEqual(entry.message, "Too many calls before SallaPush started; 1 tag/language/opt-in call was dropped "
                       + "(login/logout calls are kept).")
        XCTAssertEqual(entry.metadata["count"], "1")
        h.runtime.reportDropped(PreInitBuffer.Dropped(calls: 0, events: 1))
        XCTAssertEqual(h.logs.all.last { $0.code == "init.buffer_full" }?.message,
                       "Too many calls before SallaPush started; 1 notification event was dropped (login/logout calls are kept).")
        h.runtime.reportDropped(PreInitBuffer.Dropped(calls: 1, events: 1))
        XCTAssertEqual(h.logs.all.last { $0.code == "init.buffer_full" }?.message,
                       "Too many calls before SallaPush started; 1 tag/language/opt-in call and 1 notification event were "
                       + "dropped (login/logout calls are kept).")
    }

    /// Objective-C and bridge callers can put any integer in an `NS_ENUM`; nothing traps.
    func test_outOfRangeObjCEnumValues_neverTrap() throws {
        let h = Harness()
        h.installAsShared()
        h.registered { configuration in
            configuration.apnsEnvironment = unsafeBitCast(3, to: SallaPushAPNsEnvironment.self)
            configuration.logLevel = unsafeBitCast(9, to: SallaPushLogLevel.self)
        }
        XCTAssertNotNil(h.engine)
        XCTAssertEqual(h.server.requests("register").first?.json["apns_env"] as? String, "sandbox", ".automatic is used")
        XCTAssertEqual(h.logs.logger.consoleLevel, .warn, "the invalid level is ignored")
        SallaPush.Debug.logLevel = unsafeBitCast(-4, to: SallaPushLogLevel.self)
        SallaPush.Debug.setLogLevel(unsafeBitCast(42, to: SallaPushLogLevel.self))
        XCTAssertEqual(SallaPush.Debug.logLevel, .warn)
        SallaPush.Debug.setLogHandler(level: unsafeBitCast(7, to: SallaPushLogLevel.self)) { _ in }
        h.settle()
        let warnings = h.logs.all.filter { $0.code == "api.invalid_argument" }.map(\.message)
        XCTAssertEqual(warnings.count, 5, "\(warnings)")
        XCTAssertEqual(unsafeBitCast(9, to: SallaPushLogLevel.self).name, "invalid(9)")
        XCTAssertEqual(unsafeBitCast(9, to: SallaPushLogLevel.self).validated, nil)
        SallaPush.Debug.setLogHandler(nil)
    }

    /// The SDK registers for remote notifications after a grant only when initialize asked for it.
    func test_requestPermission_registersAfterAGrant_onlyWhenInitializeAskedForIt() {
        let before = Harness()
        before.center.status = .notDetermined
        before.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        before.settle()
        XCTAssertEqual(before.center.authorizationRequests, [false])
        XCTAssertFalse(before.application.calls.contains("registerForRemoteNotifications"), "not before initialize")

        let quiet = Harness()
        quiet.center.status = .notDetermined
        quiet.initialize { $0.registerForRemoteNotificationsOnInit = false }
        quiet.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        quiet.settle()
        XCTAssertFalse(quiet.application.calls.contains("registerForRemoteNotifications"), "the app registers itself")

        let configured = Harness()
        configured.center.status = .notDetermined
        configured.initialize()
        let atStart = configured.application.calls.filter { $0 == "registerForRemoteNotifications" }.count
        configured.runtime.requestPermission(fallbackToSettings: false, provisional: false, completion: nil)
        configured.settle()
        XCTAssertEqual(configured.application.calls.filter { $0 == "registerForRemoteNotifications" }.count, atStart + 1)
    }

    /// As on Android (`FacadeTest.test_invalidAppId_staysDisabled_laterCallsAreNoOps`), an invalid first app id leaves
    /// SallaPush idle for the process, and every later call is a logged no-op, a valid initialize included: one WARN
    /// `api.invalid_argument` says so, and nothing is sent or stored. The calls made before are never applied, so the
    /// getters stop showing them.
    func test_invalidAppId_staysIdle() {
        let h = Harness()
        h.runtime.login(externalId: "cust_early", identityToken: FakeServer.token(for: "cust_early"))
        h.runtime.addTags(["cart": "1"])
        XCTAssertTrue(h.snapshot.isLoggedIn)
        h.initialize("St.42")
        XCTAssertFalse(h.runtime.isInitialized)
        XCTAssertEqual(h.logs.all.last { $0.code == "init.invalid_app_id" }?.message,
                       "App id \"St.42\" is invalid (expected 1-64 chars A-Z, a-z, 0-9, _, -); SallaPush stays disabled.")
        XCTAssertFalse(h.snapshot.isLoggedIn, "the calls kept before are dropped")
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
        h.advance(5)
        XCTAssertTrue(h.server.requests.isEmpty)
        h.initialize("st_42_ios")
        h.sendToken()
        h.advance(10)
        XCTAssertTrue(h.server.requests.isEmpty, "a later valid initialize does not start SallaPush")
        XCTAssertFalse(h.runtime.isInitialized)
        XCTAssertNil(h.runtime.appId)
        XCTAssertNil(h.engine)
        XCTAssertEqual(h.logs.count("init.invalid_app_id"), 1)
        XCTAssertEqual(h.logs.all.filter { $0.code == "api.invalid_argument" }.map(\.message),
                       ["A SallaPush call was ignored: SallaPush is disabled for this process because initialize received "
                           + "an invalid app id."])
        XCTAssertTrue(h.keychainAccess.allValues.isEmpty)
    }

    /// A valid `initialize` is the first call after the invalid one: it is the call the warning names, and the
    /// configuration it passed is not checked aloud, since nothing uses it.
    func test_invalidAppId_thenAValidInitialize_saysTheInitializeWasIgnored() {
        let h = Harness()
        h.initialize("St.42")
        h.initialize("st_42_ios") { $0.apnsEnvironment = unsafeBitCast(3, to: SallaPushAPNsEnvironment.self) }
        XCTAssertNil(h.engine)
        XCTAssertEqual(h.logs.all.filter { $0.code == "api.invalid_argument" }.map(\.message),
                       ["initialize was ignored: SallaPush is disabled for this process because initialize received an "
                           + "invalid app id."])
        h.initialize("Bad App")
        XCTAssertEqual(h.logs.count("init.invalid_app_id"), 1, "said once: every later call is a no-op")
        XCTAssertEqual(h.logs.count("api.invalid_argument"), 1)
    }

    /// An invalid app id after a valid one says the SDK keeps running for the valid app, not that
    /// it stays disabled; the engine is untouched.
    func test_invalidAppId_afterAValidOne_saysTheSDKKeepsRunning() throws {
        let h = Harness()
        h.registered()
        let engine = try XCTUnwrap(h.engine)
        h.initialize("Bad App")
        XCTAssertEqual(h.logs.all.last { $0.code == "init.invalid_app_id" }?.message,
                       "App id \"Bad App\" is invalid (expected 1-64 chars A-Z, a-z, 0-9, _, -); this initialize was ignored; "
                       + "SallaPush keeps running for app st_42_ios.")
        XCTAssertTrue(h.engine === engine)
        XCTAssertEqual(h.runtime.appId, "st_42_ios")
        XCTAssertTrue(h.runtime.isInitialized)
    }

    func test_secondInitialize_sameAppId_isANoOp() throws {
        let h = Harness()
        h.registered()
        let engine = h.engine
        let level = h.logs.logger.consoleLevel
        let registrations = h.application.calls.filter { $0 == "registerForRemoteNotifications" }.count
        // Another configuration with the same app id and API host changes nothing at all.
        h.initialize { configuration in
            configuration.openLaunchURLs = true
            configuration.logLevel = .verbose
            configuration.requiresUserConsent = true
            configuration.registerForRemoteNotificationsOnInit = false
            configuration.appGroupIdentifier = "group.other"
        }
        h.advance(2)
        XCTAssertTrue(h.engine === engine)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertFalse(h.runtime.openLaunchURLs)
        XCTAssertEqual(h.logs.logger.consoleLevel, level)
        XCTAssertEqual(h.application.calls.filter { $0 == "registerForRemoteNotifications" }.count, registrations)
        h.submit(.setLanguage("fr"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").count, 1, "consent was not raised: the engine still sends")
        let entry = try XCTUnwrap(h.logs.all.last { $0.code == "init.started" })
        XCTAssertTrue(entry.message.contains("changes nothing"), entry.message)
        XCTAssertEqual(entry.level, .info)
    }

    /// `init.app_id_changed` names what changed: the app id, the API host, or both, and never a URL.
    func test_appIdOrHostChange_namesWhatChanged() {
        let h = Harness()
        let dev = URL(string: "https://push.example.com")
        h.initialize()
        h.initialize { $0.apiBaseURL = dev }
        h.initialize("st_43_ios") { $0.apiBaseURL = dev }
        h.initialize("st_44_ios")
        XCTAssertEqual(h.logs.all.filter { $0.code == "init.app_id_changed" }.map(\.message), [
            "Re-initialized with app st_42_ios on another API host; the previous host finishes its pending logout first.",
            "Re-initialized with app st_43_ios (was st_42_ios); the previous app finishes its pending logout first.",
            "Re-initialized with app st_44_ios on another API host (was st_43_ios); the previous app finishes its pending "
                + "logout first.",
        ])
    }

    func test_secondInitialize_otherAppId_appliesItsOptions() {
        let h = Harness()
        h.registered()
        XCTAssertFalse(h.runtime.openLaunchURLs)
        h.initialize("st_43_ios") { $0.openLaunchURLs = true }
        XCTAssertTrue(h.runtime.openLaunchURLs)
    }

    func test_secondInitialize_otherAppId_drainsTheOldEngine() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.runtime.logout()
        h.initialize("st_43_ios")
        XCTAssertTrue(h.logs.contains("init.app_id_changed"))
        h.sendToken()
        h.advance(3)
        let unlink = try XCTUnwrap(h.server.requests("unlink").first)
        XCTAssertEqual(unlink.path.contains("/devices/"), true)
        XCTAssertEqual(h.server.requests("register").map(\.path), ["/apps/st_42_ios/devices", "/apps/st_43_ios/devices"])
        h.advance(61)
        XCTAssertEqual(h.runtime.drainingEngines.count, 0, "the old engine stopped")
        XCTAssertEqual(h.runtime.appId, "st_43_ios")
    }

    /// `logout()` only enqueues; the logout reaches disk while another request still hangs.
    func test_logout_returnsWithoutNetwork() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("update") { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        let engine = try XCTUnwrap(h.engine)
        // The engine queue is blocked: a logout() that waited for it, or for the network, could not return until the
        // gate opens. The 5 s bound only turns such a hang into a failure.
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        let returned = DispatchSemaphore(value: 0)
        let runtime = h.runtime
        DispatchQueue.global().async {
            runtime.logout()
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success, "logout() waited for the engine")
        XCTAssertTrue(h.server.requests("unlink").isEmpty)
        gate.signal()
        engine.queue.sync {}
        let kinds = h.identityOps().compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["logout"], "the logout reached disk while a request hangs")
        h.server.releaseHeld()
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
    }

    func test_noDelegate_isReportedTwoSecondsAfterTheFirstActivation_neverAtInitialize() {
        let h = Harness()
        h.center.hasDelegateValue = false
        h.application.state = .inactive
        h.initialize()
        h.advance(10)
        XCTAssertFalse(h.logs.contains("init.no_delegate"))
        h.send(.didBecomeActive)
        h.advance(1)
        XCTAssertFalse(h.logs.contains("init.no_delegate"))
        h.advance(1.5)
        XCTAssertEqual(h.logs.count("init.no_delegate"), 1)

        let withDelegate = Harness()
        withDelegate.initialize()
        withDelegate.send(.didBecomeActive)
        withDelegate.advance(5)
        XCTAssertFalse(withDelegate.logs.contains("init.no_delegate"))
    }

    func test_startUpErrors_reachAHandlerSetRightAfterInitialize() {
        let h = Harness(logCapture: LogCapture(keepsEarlyEntries: true))
        h.installAsShared()
        h.runtime.initialize(appId: "Bad Id", configuration: SallaPushConfiguration())
        h.settle()
        XCTAssertTrue(h.logs.contains("init.invalid_app_id"), "logged before any handler exists")
        let received = Locked<[String]>([])
        SallaPush.Debug.setLogHandler { entry in received.withLock { $0.append(entry.code) } }
        h.logs.handlerQueue.sync {}
        XCTAssertEqual(received.current, ["init.invalid_app_id"])
    }

    func test_initialize_doesNotSetDelegate() {
        // The platform clients have no delegate setter and check-gates.sh bans assigning one in Sources; initialize
        // also makes no other change to the app's notification setup.
        let h = Harness()
        h.initialize()
        XCTAssertTrue(Set(h.application.calls).isSubset(of: ["applicationState", "registerForRemoteNotifications"]))
        XCTAssertTrue(h.center.authorizationRequests.isEmpty)
        XCTAssertTrue(h.center.added.isEmpty)
        XCTAssertTrue(h.center.removed.isEmpty)
    }

    func test_initialize_registersForRemoteNotifications_onlyWhenConfigured() {
        let h = Harness()
        h.initialize()
        XCTAssertTrue(h.application.calls.contains("registerForRemoteNotifications"))
        let quiet = Harness()
        quiet.initialize { $0.registerForRemoteNotificationsOnInit = false }
        XCTAssertFalse(quiet.application.calls.contains("registerForRemoteNotifications"))
    }

    func test_configuration_isCopied() {
        let configuration = SallaPushConfiguration()
        configuration.logLevel = .verbose
        configuration.appVersion = "1.2.3"
        let copy = configuration.copy() as? SallaPushConfiguration
        configuration.appVersion = "9.9.9"
        XCTAssertEqual(copy?.appVersion, "1.2.3")
        XCTAssertEqual(copy?.logLevel, .verbose)
        XCTAssertEqual(copy?.logLevelIsExplicit, true)
        XCTAssertFalse(SallaPushConfiguration().logLevelIsExplicit)
        XCTAssertEqual(SallaPushConfiguration().logLevel, .warn)
        XCTAssertTrue(SallaPushConfiguration().autoClearBadge)
        XCTAssertTrue(SallaPushConfiguration().autoUpdateBadge)
        configuration.autoClearBadge = false
        configuration.autoUpdateBadge = false
        let badgeCopy = configuration.copy() as? SallaPushConfiguration
        XCTAssertEqual(badgeCopy?.autoClearBadge, false)
        XCTAssertEqual(badgeCopy?.autoUpdateBadge, false)
    }

    /// The test-only server URL has no Objective-C accessor either.
    func test_serverURL_isNotInTheObjectiveCAPI() {
        let configuration = SallaPushConfiguration()
        XCTAssertFalse(configuration.responds(to: NSSelectorFromString("apiBaseURL")))
        XCTAssertFalse(configuration.responds(to: NSSelectorFromString("setApiBaseURL:")))
    }

    /// The server URL is built in: the Info.plist key that set it in 1.0.x is ignored.
    func test_infoPlistAPIBaseURL_isIgnored() {
        let h = Harness()
        h.bundle.set("SallaPushAPIBaseURL", "https://push.example.com")
        h.registered()
        XCTAssertEqual(h.server.requests.first?.host, "api.salla.dev")
        XCTAssertFalse(h.server.requests.contains { $0.host == "push.example.com" })
    }
}

/// Every getter reflects each public call as soon as it returns (`optOut(); toggle.isOn = optedIn`), also while the
/// engine is busy, before `initialize` and while consent is pending.
final class ReadYourWritesTests: XCTestCase {
    func test_gettersReflectEachCall_whileTheEngineQueueIsBlocked() throws {
        let h = Harness()
        h.installAsShared()
        h.registered()
        XCTAssertTrue(SallaPush.User.pushSubscription.optedIn)
        let engine = try XCTUnwrap(h.engine)
        let gate = DispatchSemaphore(value: 0)
        engine.queue.async { gate.wait() }
        SallaPush.User.pushSubscription.optOut()
        XCTAssertFalse(SallaPush.User.pushSubscription.optedIn)
        SallaPush.User.addTag(key: " ADD_TO_CART ", value: "1")
        SallaPush.User.addTags(["plan": "gold", "bad key": "x", "note": String(repeating: "و", count: 300)])
        XCTAssertEqual(SallaPush.User.getTags()["add_to_cart"], "1", "normalised like the engine does")
        XCTAssertEqual(SallaPush.User.getTags()["plan"], "gold")
        XCTAssertNil(SallaPush.User.getTags()["bad key"])
        XCTAssertEqual(SallaPush.User.getTags()["note"]?.utf16.count, 255)
        SallaPush.User.removeTag("PLAN")
        XCTAssertNil(SallaPush.User.getTags()["plan"])
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.externalId, "cust_a")
        SallaPush.User.pushSubscription.optIn()
        XCTAssertTrue(SallaPush.User.pushSubscription.optedIn)
        gate.signal()
        h.advance(12)
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.externalId, "cust_a")
        XCTAssertEqual(SallaPush.User.getTags(), ["add_to_cart": "1", "note": String(repeating: "و", count: 255)])
        let blocked = DispatchSemaphore(value: 0)
        engine.queue.async { blocked.wait() }
        SallaPush.logout()
        XCTAssertFalse(SallaPush.User.isLoggedIn)
        XCTAssertNil(SallaPush.User.externalId)
        XCTAssertEqual(SallaPush.User.getTags(), [:], "a signed-in customer's logout clears the tags")
        blocked.signal()
        h.advance(3)
        XCTAssertFalse(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.getTags(), [:])
    }

    func test_gettersReflectEachCall_beforeInitialize() {
        let h = Harness()
        h.installAsShared()
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        SallaPush.User.addTag(key: "vip", value: "1")
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.getTags(), ["vip": "1"])
        SallaPush.logout()
        XCTAssertFalse(SallaPush.User.isLoggedIn)
        SallaPush.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        h.settle()
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        h.registered()
        h.advance(12)
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(h.server.requests("link").map { $0.json["external_id"] as? String }, ["cust_b"])
        XCTAssertEqual(SallaPush.User.externalId, "cust_b")
    }

    func test_gettersReflectEachCall_whileConsentIsPending_andNothingIsWritten() {
        let h = Harness()
        h.installAsShared()
        h.initialize { $0.requiresUserConsent = true }
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        SallaPush.User.addTag(key: "vip", value: "1")
        h.advance(60)
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.getTags(), ["vip": "1"])
        XCTAssertTrue(h.server.requests.isEmpty)
        let written = FileManager.default.enumerator(atPath: h.root.path)?.allObjects.compactMap { $0 as? String } ?? []
        XCTAssertTrue(written.filter { $0.hasSuffix(".json") }.isEmpty, "memory only: \(written)")
    }

    /// No blocking at all; 200 rounds of calls each read right after it returns.
    func test_gettersAreNeverStaleRightAfterACall() {
        let h = Harness()
        h.installAsShared()
        h.registered()
        var stale = 0
        for index in 0..<200 {
            SallaPush.User.pushSubscription.optOut()
            if SallaPush.User.pushSubscription.optedIn { stale += 1 }
            SallaPush.User.addTag(key: "k\(index % 50)", value: "v\(index)")
            if SallaPush.User.getTags()["k\(index % 50)"] != "v\(index)" { stale += 1 }
            if index.isMultiple(of: 2) {
                SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
                if !SallaPush.User.isLoggedIn || SallaPush.User.externalId != "cust_a" { stale += 1 }
            } else {
                SallaPush.logout()
                if SallaPush.User.isLoggedIn || SallaPush.User.externalId != nil { stale += 1 }
            }
            SallaPush.User.pushSubscription.optIn()
            if !SallaPush.User.pushSubscription.optedIn { stale += 1 }
        }
        XCTAssertEqual(stale, 0)
        h.settle()
    }
}
