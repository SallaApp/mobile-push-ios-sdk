import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class EngineLifecycleTests: XCTestCase {
    func test_stopWithPendingRetryTimer_createsNoTask() throws {
        let h = Harness()
        h.registered()
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.submit(.setLanguage("en"))
        h.advance(2)
        let engine = try XCTUnwrap(h.engine)
        engine.queue.sync { engine.stop() }
        let before = h.server.requests.count
        h.advance(3_600)
        XCTAssertEqual(h.server.requests.count, before)
        XCTAssertTrue(h.transports.current.allSatisfy { $0.isInvalidated })
        XCTAssertEqual(h.transports.current.map { $0.sendsAfterInvalidate.current }.reduce(0, +), 0)
        XCTAssertEqual(h.lifecycle.observerCount, 0, "lifecycle observers are removed")
    }

    func test_appIdSwitchDuringInFlightRequest_noCrash_newEngineIndependent() {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.initialize("st_43_ios")
        h.sendToken()
        h.advance(2)
        h.server.releaseHeld()
        h.advance(61)
        XCTAssertEqual(h.server.requests("register").map(\.path).last, "/apps/st_43_ios/devices")
        XCTAssertEqual(h.runtime.drainingEngines.count, 0)
        h.submit(.setLanguage("fr"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("update").last?.json["language"] as? String, "fr")
    }

    func test_backgroundTaskEndedOnStop() throws {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.send(.didEnterBackground)
        XCTAssertEqual(h.application.begunTasks.count, 1)
        let engine = try XCTUnwrap(h.engine)
        engine.queue.sync { engine.stop() }
        XCTAssertEqual(h.application.endedTasks, h.application.begunTasks)
    }

    func test_backgroundTask_endsWhenIdle_andExpiryPersists() throws {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        h.send(.didEnterBackground)
        h.settle()
        XCTAssertEqual(h.server.requests("tags").count, 1, "tags flush at once in the background")
        XCTAssertEqual(h.application.endedTasks, h.application.begunTasks, "the task ends once idle")

        h.server.script("update") { _ in .hold }
        h.submit(.setLanguage("en"))
        h.send(.didEnterBackground)
        h.advance(2)
        let task = try XCTUnwrap(h.application.begunTasks.last)
        h.application.expire(task)
        h.settle()
        XCTAssertTrue(h.logs.contains("lifecycle.background_expired"))
        XCTAssertEqual(h.application.endedTasks.filter { $0 == task }.count, 1, "ended exactly once")
    }

    func test_appIdSwitch_drainsOldEnginesLogout() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.runtime.logout()
        h.initialize("st_43_ios")
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        XCTAssertTrue(h.server.requests("tags").isEmpty)
    }

    func test_drainOnlyEngine_finishesAnotherAppsLogout_atTheNextLaunch() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let attempts = h.server.requests("unlink").count
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize("st_43_ios")
        next.advance(2)
        XCTAssertTrue(next.logs.contains("init.drain_started"))
        XCTAssertEqual(next.server.requests("unlink").count, attempts + 1)
        XCTAssertNil(next.server.allDevices.first { $0.appId == "st_42_ios" }?.externalId)
        XCTAssertTrue(next.identityOps(appId: "st_42_ios").isEmpty)
        XCTAssertTrue(next.server.requests.filter { $0.path.contains("st_42_ios") }.count == 1, "a drain engine never registers")
    }

    func test_hostSwitch_neverSendsOtherHostsCredentials() throws {
        let h = Harness()
        h.registered()
        let first = try XCTUnwrap(h.server.allDevices.first)
        h.initialize { $0.apiBaseURL = URL(string: "https://push.example.com") }
        h.sendToken()
        h.advance(3)
        let devRequests = h.server.requests.filter { $0.host == "push.example.com" }
        XCTAssertEqual(devRequests.first?.template, "register")
        XCTAssertFalse(devRequests.contains { $0.headers["authorization"] == "Device " + first.secret })
        XCTAssertNotNil(h.keychainAccess.value(account: "device_credentials.st_42_ios.\(APIBase.production.hostTag)"))
        let devTag = try XCTUnwrap(APIBase.validated(URL(string: "https://push.example.com"))).hostTag
        XCTAssertNotNil(h.keychainAccess.value(account: "device_credentials.st_42_ios.\(devTag)"))
    }

    func test_appIdSwitch_usesSeparateState() {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        h.advance(11)
        h.initialize("st_43_ios")
        h.sendToken()
        h.advance(2)
        XCTAssertTrue(h.snapshot.tags.isEmpty)
        XCTAssertFalse(h.file("state.json", appId: "st_43_ios").isEmpty)
        XCTAssertNotEqual(h.snapshot.deviceId, h.server.allDevices.first { $0.appId == "st_42_ios" }?.id)
    }

    /// A → B → A within the 60 s drain window, with A's logout on the wire. One engine per folder:
    /// the draining A engine applies its logout's answer and stops before the new A engine loads the same files, so
    /// the logout and the new login stay ordered and identity.json keeps the login.
    func test_appIdSwitchBack_withinTheDrainWindow_keepsOneEnginePerFolder() throws {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink") { _ in .hold }
        h.runtime.logout()
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.initialize("st_43_ios")
        h.initialize("st_42_ios")
        h.server.script("link") { _ in .hold }
        h.runtime.login(externalId: "cust_b", identityToken: "customer.token.b")
        h.settle()
        let running = h.engines.filter { engine in
            engine.config.appId == "st_42_ios" && engine.queue.sync { engine.phase } == .running
        }
        XCTAssertEqual(running.count, 1, "the new engine waits for the draining one")
        XCTAssertTrue(h.server.requests("link").count == 1, "no login before the logout's answer")
        h.server.releaseHeld()
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1, "the new login is on the wire")
        XCTAssertEqual(h.identityOps().compactMap { $0["kind"] as? String }, ["login"], "identity.json keeps the login")
        XCTAssertEqual(h.server.templates.suffix(2), ["unlink", "link"])
        XCTAssertEqual(h.server.requests("unlink").count, 1, "the answer on the wire was applied, never sent again")
        h.server.releaseHeld()
        h.advance(3)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(h.server.device(deviceId)?.externalId, "cust_b")
        let main = try XCTUnwrap(h.engine)
        XCTAssertEqual(main.queue.sync { main.identity.serverLink }, .linked)
        XCTAssertEqual(h.snapshot.externalId, "cust_b")
        XCTAssertEqual(h.engines.filter { $0.config.appId == "st_42_ios" }.count, 1)
    }

    /// Re-initializing to an app id whose drain-only engine (from the scan at launch) is finishing a
    /// logout hands that folder over too.
    func test_reinitializeToAFolderADrainOnlyEngineIsFinishing_handsItOver() throws {
        let h = Harness()
        h.server.customers = { token in .linked(token == "customer.token.a" ? "cust_a" : "cust_b") }
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let attempts = h.server.requests("unlink").count
        let next = h.relaunch()
        next.server.clearScripts()
        next.server.script("unlink") { _ in .hold }
        next.initialize("st_43_ios")
        // The retry wait persisted by the last session still applies.
        next.advance(5)
        XCTAssertEqual(next.server.heldCount, 1, "the drain-only engine's logout is on the wire")
        next.initialize("st_42_ios")
        next.login("customer.token.b")
        let running = next.engines.filter { engine in
            engine.config.appId == "st_42_ios" && engine.queue.sync { engine.phase } == .running
        }
        XCTAssertEqual(running.count, 1)
        next.server.releaseHeld()
        next.advance(3)
        XCTAssertEqual(next.server.templates.suffix(2), ["unlink", "link"])
        XCTAssertEqual(next.server.requests("unlink").count, attempts + 1, "the logout on the wire is never sent again")
        XCTAssertEqual(next.server.device(next.deviceId)?.externalId, "cust_b")
        XCTAssertEqual(next.engines.filter { $0.config.appId == "st_42_ios" }.count, 1)
    }

    /// At most three drain-only engines start per launch.
    func test_drainOnlyEngines_atMostThreePerLaunch() throws {
        let h = Harness()
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        for appId in ["st_1_ios", "st_2_ios", "st_3_ios", "st_4_ios"] {
            h.registered(appId)
            h.login("customer.token.a")
            h.advance(2)
            h.logout()
            h.advance(3)
        }
        for appId in ["st_1_ios", "st_2_ios", "st_3_ios", "st_4_ios"] {
            XCTAssertEqual(h.identityOps(appId: appId).compactMap { $0["kind"] as? String }, ["logout"], appId)
        }
        let next = h.relaunch()
        next.server.clearScripts()
        next.server.script("unlink", times: nil) { _ in .hold }
        next.initialize("st_5_ios")
        next.advance(1)
        XCTAssertEqual(next.runtime.drainingEngines.count, 3)
        XCTAssertEqual(next.logs.count("init.drain_started"), 3)
    }

    /// While registration is dormant (routes closed), a hundred calls and foreground cycles arm no
    /// new wake-up for the same deadline; each re-arm would leave a cancelled item alive in libdispatch for a day.
    func test_dormant_manyCalls_armOneWakePerDeadline() {
        let h = Harness()
        h.server.script("register", times: nil) { _ in FakeServer.error(404, "not_found") }
        h.registered()
        XCTAssertEqual(h.server.requests("register").count, 1)
        let before = h.scheduler.scheduledCount
        for index in 0..<100 {
            h.runtime.submit(.setLanguage(index.isMultiple(of: 2) ? "ar" : "en"))
            h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
        }
        for _ in 0..<20 {
            h.lifecycle.send(.willEnterForeground)
            h.lifecycle.send(.didBecomeActive)
            h.lifecycle.send(.didEnterBackground)
        }
        h.settle()
        XCTAssertLessThanOrEqual(h.scheduler.scheduledCount - before, 1, "only the first activation's delegate check")
        h.runtime.addTags(["a": "1"])
        h.settle()
        let afterTags = h.scheduler.scheduledCount
        for index in 0..<100 { h.runtime.addTags(["k\(index % 10)": "\(index)"]) }
        h.settle()
        XCTAssertEqual(h.scheduler.scheduledCount, afterTags, "the tags debounce wake is armed once")
        h.advance(86_400)
        XCTAssertEqual(h.server.requests("register").count, 2, "the dormant wake still fires")
    }

    func test_manyReschedules_andStopStartCycles_neverTrap() {
        let h = Harness()
        h.initialize()
        for cycle in 0..<20 {
            guard let engine = h.engine else { return XCTFail("no engine") }
            engine.queue.sync {
                for index in 0..<500 {
                    engine.schedule(.pump, after: Double(index % 7)) { _ in }
                    engine.schedule(.tokenMissing, after: -Double(index)) { _ in }
                }
            }
            h.advance(1)
            h.initialize(cycle.isMultiple(of: 2) ? "st_43_ios" : "st_42_ios")
        }
        h.advance(120)
        XCTAssertEqual(h.runtime.drainingEngines.count, 0)
    }
}

/// Background work runs inside a background task, and a background launch sends only identity
/// operations and events.
final class LifecycleTests: XCTestCase {
    func test_background_flushWrappedInTask() {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .received, at: h.clock.now(), actionId: nil)]))
        XCTAssertTrue(h.server.requests("tags").isEmpty, "waiting for the debounce")
        h.send(.didEnterBackground)
        h.settle()
        XCTAssertEqual(h.application.begunTasks.count, 1)
        XCTAssertTrue(h.application.calls.contains("beginBackgroundTask:SallaPush.flush"))
        XCTAssertEqual(h.server.requests("tags").count, 1, "flushed at once")
        XCTAssertEqual(h.server.requests("events").count, 1, "flushed at once")
        XCTAssertEqual(h.application.endedTasks, h.application.begunTasks, "ended once idle")
    }

    func test_backgroundLaunch_sendsNoUpdate() {
        let h = Harness()
        h.registered()
        let before = h.server.requests.count
        let next = h.relaunch()
        next.clock.set(next.clock.now() + 90_000)
        next.application.state = .background
        next.initialize()
        next.sendToken()
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, before, "no heartbeat in a background launch, although it is due")
        next.application.state = .active
        next.send(.willEnterForeground)
        next.advance(3)
        XCTAssertEqual(next.server.requests("update").count, 1, "the heartbeat goes at the first foreground")
    }

    func test_backgroundLaunch_sendsNoTags() {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        let next = h.relaunch()
        next.application.state = .background
        next.initialize()
        next.advance(60)
        XCTAssertTrue(next.server.requests("tags").isEmpty, "a persisted tag change waits for the first foreground")
        next.application.state = .active
        next.send(.willEnterForeground)
        next.advance(12)
        XCTAssertEqual(next.server.requests("tags").count, 1)
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["a": "1"])
    }

    /// A background launch reads no extension inbox until its first foreground.
    func test_backgroundLaunch_ingestsNoInbox_untilTheFirstForeground() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let h = Harness()
        h.appGroupContainer.set(container)
        h.registered { $0.appGroupIdentifier = "group.salla.test" }
        let inbox = Inbox(folder: Inbox.folder(inContainer: container))
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_cafe", at: h.clock.now()), .written)
        let next = h.relaunch()
        next.application.state = .background
        next.initialize { $0.appGroupIdentifier = "group.salla.test" }
        next.advance(30)
        // No foreground transition reads it, and the read itself refuses a background launch, whatever calls it.
        let engine = try XCTUnwrap(next.engine)
        engine.queue.sync { engine.ingestInbox(now: next.clock.now()) }
        XCTAssertFalse(next.logs.contains("inbox.ingested"))
        XCTAssertTrue(next.server.requests("events").isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: inbox.folder.path))?.count, 1)
        next.application.state = .active
        next.send(.willEnterForeground)
        next.advance(6)
        XCTAssertTrue(next.logs.contains("inbox.ingested"))
        XCTAssertEqual(next.server.requests("events").count, 1)
    }

    /// The activation arrives while the engine loads, before its application-state read
    /// answers (here with the older `.inactive`). It is applied once the load ends: the badge is cleared and the
    /// delegate check runs at this launch.
    func test_activationDuringLoad_isAppliedWhenTheLoadEnds() throws {
        let h = Harness()
        h.registered()
        let next = h.relaunch()
        next.useAsynchronousSystemCallbacks()
        next.application.state = .inactive
        next.center.hasDelegateValue = false
        let badgesBefore = next.center.badgeResets
        next.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        next.runtime.controlQueue.sync {}
        let engine = try XCTUnwrap(next.engine)
        engine.queue.sync {}
        XCTAssertEqual(engine.queue.sync { engine.phase }, .loading, "the state read is still on its way")
        next.application.state = .active
        next.lifecycle.send(.didBecomeActive)
        engine.queue.sync {}
        next.settle()
        next.advance(5)
        XCTAssertGreaterThan(next.center.badgeResets, badgesBefore)
        XCTAssertEqual(engine.queue.sync { engine.appState }, .active)
        XCTAssertEqual(next.logs.count("init.no_delegate"), 1, "the delegate check ran")
    }

    /// A background launch that comes to the foreground while the engine loads is no
    /// background launch: the due heartbeat and the pending tag go at once, not at the next foreground.
    func test_foregroundDuringABackgroundLaunchsLoad_endsTheBackgroundLaunch() throws {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["a": "1"]))
        let before = h.server.requests.count
        let next = h.relaunch()
        next.useAsynchronousSystemCallbacks()
        next.application.state = .background
        next.clock.set(next.clock.now() + 90_000)
        next.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        next.runtime.controlQueue.sync {}
        let engine = try XCTUnwrap(next.engine)
        engine.queue.sync {}
        next.application.state = .active
        next.lifecycle.send(.willEnterForeground)
        next.lifecycle.send(.didBecomeActive)
        engine.queue.sync {}
        next.settle()
        next.advance(30)
        XCTAssertFalse(engine.queue.sync { engine.isBackgroundLaunch })
        XCTAssertEqual(next.server.requests.count - before, 2, "\(next.server.templates.suffix(3))")
        XCTAssertEqual(next.server.requests("update").count, 1, "the heartbeat")
        XCTAssertEqual(next.server.device(next.deviceId)?.tags, ["a": "1"])
    }

    func test_backgroundLaunch_stillSendsIdentityOpsAndEvents() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let next = h.relaunch()
        next.application.state = .background
        next.initialize()
        next.logout()
        next.submit(.events([EventRecord(messageId: "msg_cd", type: .received, at: next.clock.now(), actionId: nil)]))
        next.advance(10)
        XCTAssertEqual(next.server.requests("unlink").count, 1)
        XCTAssertEqual(next.server.requests("events").count, 1)
        XCTAssertTrue(next.server.requests("update").isEmpty)
    }
}
