import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// Run under Thread Sanitizer (`swift test --sanitize=thread`, `xcodebuild test -enableThreadSanitizer YES`).
/// System callbacks arrive on other threads, as on a device: the notification center's on its own queue, UIKit's on
/// main.
final class ConcurrencyStressTests: XCTestCase {
    func test_mixedPublicCalls_fromEightThreads_withObserversAndASecondInitialize() {
        let h = Harness()
        Runtime.install(h.runtime)
        h.useAsynchronousSystemCallbacks()
        h.registered()
        let compat: [AnyHashable: Any] = ["aps": ["alert": "x"], "custom": ["i": "i", "a": ["push_ref": "msg_ab"]]]
        let observations = Locked<[SallaPushObservation]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<1_000 {
                if thread == 3 && index == 500 {
                    h.runtime.initialize(appId: "st_43_ios", configuration: SallaPushConfiguration())
                }
                switch (thread + index) % 16 {
                case 0: SallaPush.User.addTag(key: "k\(index % 20)", value: "\(index)")
                case 1: SallaPush.User.removeTag("k\(index % 20)")
                case 2: _ = SallaPush.User.getTags()
                case 3: SallaPush.User.setLanguage(index.isMultiple(of: 2) ? "ar" : "en")
                case 4: SallaPush.login(externalId: "cust_\(index % 3)", identityToken: FakeServer.token(for: "cust_\(index % 3)"))
                case 5: SallaPush.logout()
                case 6: _ = (SallaPush.User.pushSubscription.id, SallaPush.User.pushSubscription.optedIn,
                             SallaPush.User.isLoggedIn, SallaPush.User.externalId)
                case 7:
                    let observation = SallaPush.User.addObserver { _ in }
                    if index.isMultiple(of: 2) { observation.cancel() } else { observations.withLock { $0.append(observation) } }
                case 8: SallaPush.Debug.logLevel = index.isMultiple(of: 2) ? .verbose : .warn
                case 9: _ = SallaPush.Debug.logLevel
                case 10: SallaPush.login(externalId: " ", identityToken: "")
                case 11: _ = SallaPush.Notifications.parse(compat)
                case 12: _ = SallaPush.Notifications.isSallaPushNotification(compat)
                case 13:
                    if index.isMultiple(of: 10) {
                        SallaPush.User.pushSubscription.optIn()
                    } else {
                        SallaPush.Notifications.refreshPermission()
                    }
                case 14:
                    let observation = SallaPush.User.pushSubscription.addObserver { _ in }
                    observation.cancel()
                default:
                    _ = h.runtime.router.didReceive(identifier: "r\(index)", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                    userInfo: compat)
                }
            }
        }
        h.settle()
        h.advance(120)
        observations.withLock { $0.removeAll() }
        XCTAssertEqual(h.runtime.appId, "st_43_ios")
        XCTAssertNotNil(h.engine)
    }

    /// Consent required, given and withdrawn from several threads while calls are made, getters read and the
    /// app id switches, starting before the engines loaded their files. Afterwards, with consent given, no call is lost:
    /// the last login stands, and the getters' anticipation is settled.
    func test_consentToggles_racingCallsGettersAndSwitches_fromEightThreads() {
        let h = Harness()
        Runtime.install(h.runtime)
        h.useAsynchronousSystemCallbacks()
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<400 {
                switch (thread * 5 + index) % 12 {
                case 0: SallaPush.setConsentRequired(index.isMultiple(of: 3))
                case 1: SallaPush.setConsentGiven(!index.isMultiple(of: 4))
                case 2:
                    if index.isMultiple(of: 50) {
                        let appId = ["st_42_ios", "st_43_ios"][(thread + index / 50) % 2]
                        h.runtime.initialize(appId: appId, configuration: SallaPushConfiguration())
                    }
                case 3: SallaPush.User.addTag(key: "k\(index % 30)", value: "\(index)")
                case 4: SallaPush.User.removeTag("k\(index % 30)")
                case 5: SallaPush.login(externalId: "cust_\(index % 3)", identityToken: FakeServer.token(for: "cust_\(index % 3)"))
                case 6: SallaPush.logout()
                case 7: _ = (SallaPush.User.getTags(), SallaPush.User.isLoggedIn, SallaPush.User.pushSubscription.optedIn)
                case 8: h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex(UInt8(index % 3 + 1)))))
                case 9: SallaPush.User.pushSubscription.optOut()
                case 10: SallaPush.User.pushSubscription.optIn()
                default: h.lifecycle.send(index.isMultiple(of: 2) ? .didBecomeActive : .willEnterForeground)
                }
            }
        }
        h.settle()
        SallaPush.setConsentRequired(true)
        SallaPush.setConsentGiven(true)
        SallaPush.login(externalId: "cust_final", identityToken: FakeServer.token(for: "cust_final"))
        h.advance(180)
        XCTAssertNotNil(h.engine)
        XCTAssertTrue(SallaPush.User.isLoggedIn)
        XCTAssertEqual(SallaPush.User.externalId, "cust_final")
        XCTAssertEqual(h.runtime.view.withLock { $0.pendingCount }, 0, "every call was handled or dropped by the buffer")
        XCTAssertEqual(h.runtime.state.withLock { $0.engineAccepts }, true)
    }
}
