import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// SallaPush never crashes on bad input: Objective-C, React Native and Flutter callers can pass nil
/// for every object parameter Swift declares nonnull, and Swift then holds a null reference. Each case passes one,
/// built by bit pattern exactly as the Objective-C thunk hands it over, through a public entry point: nothing crashes,
/// the documented default comes back, and WARN `api.invalid_argument` names the call.
final class NilArgumentTests: XCTestCase {
    private func null<Value>(_ type: Value.Type) -> Value {
        unsafeBitCast(0 as Int, to: type)
    }

    private func shared() -> Harness {
        let h = Harness()
        h.installAsShared()
        h.registered()
        return h
    }

    private func warned(_ h: Harness, _ prefix: String) -> Bool {
        h.logs.all.contains { $0.code == "api.invalid_argument" && $0.level == .warn && $0.message.hasPrefix(prefix) }
    }

    /// Calls the Objective-C method `selector` of `SallaPush.User` with `argument` as it is, as Objective-C does.
    private func callObjC(_ selector: String, with argument: Any?) {
        let user = SallaPush.User
        let method = NSSelectorFromString(selector)
        guard user.responds(to: method) else { return XCTFail("SallaPush.User has no Objective-C method \(selector)") }
        _ = user.perform(method, with: argument)
    }

    func test_observerRegistrations_withNil_areIgnored() {
        let h = shared()
        SallaPush.User.addObserver(null(SallaPushUserObserver.self))
        SallaPush.User.removeObserver(null(SallaPushUserObserver.self))
        SallaPush.User.pushSubscription.addObserver(null(SallaPushSubscriptionObserver.self))
        SallaPush.User.pushSubscription.removeObserver(null(SallaPushSubscriptionObserver.self))
        SallaPush.Notifications.addPermissionObserver(null(SallaPushPermissionObserver.self))
        SallaPush.Notifications.removePermissionObserver(null(SallaPushPermissionObserver.self))
        h.settle()
        for call in ["User.addObserver", "User.removeObserver", "pushSubscription.addObserver",
                     "pushSubscription.removeObserver", "addPermissionObserver", "removePermissionObserver"] {
            XCTAssertTrue(warned(h, "\(call) ignored: the observer is nil."), call)
        }
        // The registries still work.
        let calls = Locked(0)
        let observation = SallaPush.User.addObserver { _ in calls.withLock { $0 += 1 } }
        SallaPush.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
        h.advance(3)
        XCTAssertGreaterThan(calls.current, 0)
        observation.cancel()
    }

    func test_listenerRegistrations_withNil_areIgnored() {
        let h = shared()
        SallaPush.Notifications.addClickListener(null(SallaPushClickListener.self))
        SallaPush.Notifications.removeClickListener(null(SallaPushClickListener.self))
        SallaPush.Notifications.addForegroundLifecycleListener(null(SallaPushForegroundLifecycleListener.self))
        SallaPush.Notifications.removeForegroundLifecycleListener(null(SallaPushForegroundLifecycleListener.self))
        for call in ["addClickListener", "removeClickListener", "addForegroundLifecycleListener",
                     "removeForegroundLifecycleListener"] {
            XCTAssertTrue(warned(h, "\(call) ignored: the listener is nil."), call)
        }
        // A tap is still delivered (and kept for a later listener, not lost on the nil one).
        let clicks = Locked(0)
        _ = h.runtime.router.didReceive(identifier: "r", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: ["sp_v": "1", "sp_id": "msg_ab", "aps": ["alert": "x"]])
        let observation = SallaPush.Notifications.addClickListener { _ in clicks.withLock { $0 += 1 } }
        h.settle()
        XCTAssertEqual(clicks.current, 1)
        observation.cancel()
    }

    func test_forwarding_withNilSystemObjects_returnsNotSallaPush() {
        let h = shared()
        SallaPush.Notifications.didFailToRegisterForRemoteNotifications(error: null((any Error).self))
        XCTAssertNil(SallaPush.Notifications.willPresent(null(UNNotification.self)))
        var options: UNNotificationPresentationOptions = [.sound]
        XCTAssertFalse(objcWillPresent(null(UNNotification.self), &options))
        XCTAssertEqual(options, [.sound], "the pointer is untouched")
        XCTAssertFalse(SallaPush.Notifications.didReceive(null(UNNotificationResponse.self)))
        h.settle()
        XCTAssertTrue(warned(h, "didFailToRegisterForRemoteNotifications ignored: the error is nil."))
        XCTAssertTrue(warned(h, "willPresent ignored: the notification is nil."))
        XCTAssertTrue(warned(h, "didReceive ignored: the response is nil."))
        XCTAssertFalse(h.logs.contains("token.registration_failed"))
    }

    func test_initialize_withANilConfiguration_usesTheDefault() {
        let h = Harness()
        h.runtime.initialize(appId: "st_42_ios", configuration: null(SallaPushConfiguration.self))
        h.settle()
        h.sendToken()
        h.advance(2)
        XCTAssertTrue(h.runtime.isInitialized)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertTrue(warned(h, "initialize: the configuration is nil; the default configuration is used."))
        XCTAssertTrue(h.application.calls.contains("registerForRemoteNotifications"), "the default configuration")
    }

    /// Bridge code can also put objects of another class in the collections of `addTags:` and `removeTags:`, such as an
    /// `NSNumber` or `NSNull` from a React Native `NSDictionary`, and Swift's bridging to `[String: String]` and
    /// `[String]` traps on them. A call skips them with one WARN `api.invalid_argument` that counts them, its string
    /// members still apply, and nil stays an empty call.
    func test_objcAddTags_withMembersThatAreNotStrings_addsTheStringTags() {
        let h = shared()
        let tags = NSDictionary(objects: [NSNumber(value: 1), "x" as NSString, "y" as NSString],
                                forKeys: ["a" as NSString, "b" as NSString, NSNumber(value: 2)])
        callObjC("addTags:", with: tags)
        callObjC("addTags:", with: NSDictionary(object: NSNull(), forKey: "c" as NSString))
        XCTAssertEqual(SallaPush.User.getTags(), ["b": "x"])
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").map { $0.json as NSDictionary },
                       [["add": ["b": "x"]]] as [NSDictionary])
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["b": "x"])
        let warnings = h.logs.all.filter { $0.code == "api.invalid_argument" }
        XCTAssertEqual(warnings.map(\.message), [
            "addTags: 2 tags were skipped; a tag's key and value must be strings.",
            "addTags: 1 tag was skipped; a tag's key and value must be strings.",
        ])
        XCTAssertTrue(warnings.allSatisfy { $0.level == .warn })
        XCTAssertEqual(warnings.map { $0.metadata["count"] }, ["2", "1"])
        callObjC("addTags:", with: nil)
        h.advance(11)
        XCTAssertEqual(h.logs.count("api.invalid_argument"), 2, "nil is an empty call: ignored without a log line")
        XCTAssertEqual(h.server.requests("tags").count, 1)
    }

    func test_objcRemoveTags_withMembersThatAreNotStrings_removesTheStringKeys() {
        let h = shared()
        SallaPush.User.addTags(["a": "1", "b": "x"])
        h.advance(11)
        callObjC("removeTags:", with: NSArray(array: [NSNumber(value: 1), NSNull(), "b" as NSString]))
        callObjC("removeTags:", with: NSArray(array: [NSNumber(value: 3)]))
        XCTAssertEqual(SallaPush.User.getTags(), ["a": "1"])
        h.advance(11)
        XCTAssertEqual(h.server.requests("tags").last?.json as NSDictionary?, ["remove": ["b"]] as NSDictionary)
        XCTAssertEqual(h.server.device(h.deviceId)?.tags, ["a": "1"])
        let warnings = h.logs.all.filter { $0.code == "api.invalid_argument" }
        XCTAssertEqual(warnings.map(\.message), [
            "removeTags: 2 keys were skipped; a tag key must be a string.",
            "removeTags: 1 key was skipped; a tag key must be a string.",
        ])
        XCTAssertTrue(warnings.allSatisfy { $0.level == .warn })
        XCTAssertEqual(warnings.map { $0.metadata["count"] }, ["2", "1"])
        callObjC("removeTags:", with: nil)
        h.advance(11)
        XCTAssertEqual(h.logs.count("api.invalid_argument"), 2, "nil is an empty call: ignored without a log line")
        XCTAssertEqual(h.server.requests("tags").count, 2)
    }
}
