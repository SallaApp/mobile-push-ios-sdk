import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// Consent and the engines that finish other app ids' logouts: consent
/// covers their requests too, they resume when consent comes back, and a withdrawal under way when the app switches
/// away is carried on.
extension ConsentTests {
    /// Consent covers other app ids' requests too: when consent becomes required and is not given, the engines finishing
    /// other app ids' logouts stop, sending and writing nothing more (a retry that was due is never sent); a later launch
    /// with consent finishes them.
    func test_consentWithheld_stopsTheEnginesFinishingOtherAppsLogouts() {
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
        next.server.script("unlink", times: 1) { _ in FakeServer.error(503, "server_error") }
        next.initialize("st_43_ios")
        next.advance(2.5)
        XCTAssertEqual(next.server.requests("unlink").count, attempts + 1, "the drain-only engine tried, and waits to retry")
        XCTAssertEqual(next.runtime.drainingEngines.count, 1)
        next.runtime.setConsentRequired(true)
        next.settle()
        XCTAssertEqual(next.runtime.drainingEngines.count, 0, "stopped")
        next.advance(120)
        XCTAssertEqual(next.server.requests("unlink").count, attempts + 1, "its retry is never sent")
        XCTAssertEqual(next.identityOps(appId: "st_42_ios").compactMap { $0["kind"] as? String }, ["logout"])

        let later = next.relaunch()
        later.server.clearScripts()
        later.initialize("st_43_ios")
        later.advance(5)
        XCTAssertTrue(later.identityOps(appId: "st_42_ios").isEmpty, "finished at a launch with consent")
        XCTAssertNil(later.server.allDevices.first { $0.appId == "st_42_ios" }?.externalId)
    }

    /// Consent withheld and given back before the engine finishing another app id's logout had stopped: the resumption
    /// cannot restart it while it holds its folder, so it starts again once it stopped, and the logout finishes in this
    /// process.
    func test_consentGivenBackBeforeADrainEngineStopped_restartsItOnceItStopped() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let next = h.relaunch()
        next.server.clearScripts()
        next.server.script("unlink", times: 1) { _ in FakeServer.error(503, "server_error") }
        next.initialize("st_43_ios")
        next.advance(2.5)
        let drain = try XCTUnwrap(next.runtime.drainingEngines.first)
        let held = DispatchSemaphore(value: 0)
        drain.queue.async { held.wait() }
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(true)
        next.runtime.controlQueue.sync {}
        XCTAssertTrue(next.runtime.drainingEngines.first === drain, "still stopping when consent came back")
        held.signal()
        next.advance(5)
        XCTAssertFalse(next.runtime.drainingEngines.contains { $0 === drain })
        XCTAssertTrue(next.identityOps(appId: "st_42_ios").isEmpty, "finished in this process")
        XCTAssertNil(next.server.allDevices.first { $0.appId == "st_42_ios" }?.externalId)
    }

    /// A switch to another app id while consent is withheld leaves the previous app's pending logout with its engine,
    /// paused and sending nothing; consent given within its 60 s drain window sends that logout in this process, and
    /// nothing else (no update, no login) for the previous app.
    func test_switchWhileConsentIsWithheld_thenConsent_finishesThePreviousAppsLogout() {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        XCTAssertEqual(h.identityOps().compactMap { $0["kind"] as? String }, ["logout"])
        h.runtime.setConsentRequired(true)
        h.settle()
        h.server.clearScripts()
        let attempts = h.server.requests("unlink").count
        h.initialize("st_43_ios")
        h.advance(5)
        XCTAssertEqual(h.server.requests("unlink").count, attempts, "nothing is sent while consent is withheld")
        XCTAssertEqual(h.runtime.drainingEngines.count, 1)
        let updates = h.server.requests("update").count
        h.runtime.setConsentGiven(true)
        h.advance(30)
        XCTAssertEqual(h.server.requests("unlink").count, attempts + 1)
        XCTAssertTrue(h.identityOps().isEmpty, "the previous app's logout went out in this process")
        XCTAssertNil(h.server.allDevices.first { $0.appId == "st_42_ios" }?.externalId)
        XCTAssertEqual(h.server.requests("update").count, updates, "the previous app sends nothing else")
        XCTAssertTrue((h.file("state.json")["ops"] as? [[String: Any]] ?? []).isEmpty, "nor queues anything else")
        XCTAssertTrue(h.runtime.drainingEngines.isEmpty, "done, it stopped")
    }

    /// A switch to another app id while the withdrawal waits to retry its opt-out: the previous app's engine carries the
    /// withdrawal on within its drain window (it used to stop at once, leaving the server opted in and linked), then
    /// stops.
    func test_switchWhileAWithdrawalWaitsToRetry_carriesTheWithdrawalOn() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertNotNil(h.server.device(deviceId)?.externalId)
        h.server.script("update", times: 1) { _ in FakeServer.error(503, "server_error") }
        h.runtime.setConsentGiven(false)
        h.settle()
        XCTAssertEqual(h.server.templates.last, "update", "the opt-out failed and waits to retry")
        XCTAssertFalse(h.logs.contains("consent.revoked"))
        h.initialize("st_43_ios")
        h.advance(30)
        XCTAssertEqual(h.server.device(deviceId)?.optedIn, false)
        XCTAssertNil(h.server.device(deviceId)?.externalId)
        XCTAssertEqual(h.logs.all.first { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out and unlinked on the server. SallaPush is now idle.")
        XCTAssertTrue(h.runtime.drainingEngines.isEmpty, "then it stopped")
    }

    /// Consent given again while an engine switched away from still carries out its withdrawal: the withdrawal ends,
    /// and that engine only finishes its pending logouts. It queues nothing for the previous app (no update, no login
    /// with the token in memory): the previous app's next `initialize` does that.
    func test_consentGivenWhileASwitchedAwayEngineWithdraws_queuesNothingForThePreviousApp() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        h.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        h.runtime.setConsentGiven(false)
        h.settle()
        h.initialize("st_43_ios")
        h.advance(2)
        XCTAssertEqual(h.runtime.drainingEngines.count, 1, "still withdrawing")
        h.server.clearScripts()
        h.runtime.setConsentGiven(true)
        h.advance(5)
        XCTAssertTrue(h.runtime.drainingEngines.isEmpty, "it stopped: nothing was pending for the previous app")
        XCTAssertTrue(h.identityOps().isEmpty, "no login queued for the previous app")
        XCTAssertTrue((h.file("state.json")["ops"] as? [[String: Any]] ?? []).isEmpty, "no update queued for it")
    }
}
