import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// Consent at the edges of the engine's life: consent calls that land before the engine loaded its files, a
/// withdrawal made while no engine runs, and a `consent.json` that cannot be read yet.
extension ConsentTests {
    /// The JSON files written under the SDK's root.
    private func writtenFiles(_ h: Harness) -> [String] {
        let names = FileManager.default.enumerator(atPath: h.root.path)?.allObjects.compactMap { $0 as? String } ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Initializes with system callbacks answered the way the system answers them (UIKit on main), and runs `body`
    /// while the engine still waits for its application-state answer: every call in it lands before the files loaded.
    @discardableResult
    private func whileTheEngineLoads(_ h: Harness, _ body: () -> Void) throws -> Engine {
        h.useAsynchronousSystemCallbacks()
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        h.runtime.controlQueue.sync {}
        let engine = try XCTUnwrap(h.engine)
        engine.queue.sync {}
        body()
        h.runtime.controlQueue.sync {}
        engine.queue.sync {}
        XCTAssertEqual(engine.queue.sync { engine.phase }, .loading, "the application-state answer is still on its way")
        return engine
    }

    // MARK: - Consent calls before the files are loaded

    /// The withdrawal lands before the files are loaded. It runs on them once they are: the server is opted out and
    /// unlinked, the last session's pending logout stays on disk, the registration and the token are kept,
    /// and no start-up work runs. Consent given again settles that logout (the withdrawal's unlink was answered, so the
    /// device is known to be unlinked) and sends `opted_in` again.
    func test_withdrawalDuringLoad_runsOnTheLoadedFiles_andKeepsThePendingLogout() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.advance(3)
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(2)
        XCTAssertEqual(h.identityOps().compactMap { $0["kind"] as? String }, ["logout"])
        let next = h.relaunch()
        next.server.clearScripts()
        let callsBefore = next.application.calls.count
        let requestsBefore = next.server.requests.count
        next.runtime.setConsentRequired(true)
        try whileTheEngineLoads(next) { next.runtime.setConsentGiven(false) }
        next.settle()
        next.advance(30)
        let sent = Array(next.server.requests.dropFirst(requestsBefore))
        XCTAssertEqual(sent.map(\.template), ["update", "unlink"], "the device held no tags")
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["opted_in": false] as NSDictionary)
        XCTAssertEqual(next.server.device(deviceId)?.optedIn, false)
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        XCTAssertEqual(next.logs.all.last { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; opted out and unlinked on the server. SallaPush is now idle.")
        XCTAssertEqual(next.identityOps().compactMap { $0["kind"] as? String }, ["logout"], "the pending logout stays on disk")
        let state = next.file("state.json")
        XCTAssertEqual(state["last_device_id"] as? String, deviceId)
        XCTAssertEqual((state["push"] as? [String: Any])?["token"] as? String, Harness.tokenHex())
        XCTAssertEqual((state["registration"] as? [String: Any])?["status"] as? String, "registered")
        XCTAssertEqual(next.file("identity.json")["desired"] as? String, "guest", "the loaded identity, minimised")
        XCTAssertEqual(Array(next.application.calls.dropFirst(callsBefore)), ["applicationState"], "no start-up work")

        next.runtime.setConsentGiven(true)
        next.advance(5)
        XCTAssertEqual(Array(next.server.requests.dropFirst(requestsBefore + 2)).map(\.template), ["update"])
        XCTAssertEqual(next.server.requests.last?.json["opted_in"] as? Bool, true)
        XCTAssertEqual(next.server.device(deviceId)?.optedIn, true)
        XCTAssertTrue(next.identityOps().isEmpty)
        XCTAssertEqual(Array(next.application.calls.dropFirst(callsBefore)).filter { $0 == "registerForRemoteNotifications" },
                       ["registerForRemoteNotifications"], "the start-up work ran once consent was back")
    }

    /// Consent becomes required while the engine loads, after the app forwarded its token and logged in.
    /// The pause is applied to the loaded files before any start-up work: no registerForRemoteNotifications, no timers,
    /// no request and no file. The calls wait for consent (the getters show them), then go in call order.
    func test_pauseDuringLoad_skipsTheStartupWork_andKeepsTheCallsUntilConsent() throws {
        let h = Harness()
        h.center.hasDelegateValue = false
        let engine = try whileTheEngineLoads(h) {
            h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
            h.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
            h.runtime.setConsentRequired(true)
        }
        h.settle()
        h.send(.didBecomeActive)
        h.advance(60)
        XCTAssertEqual(engine.queue.sync { engine.consentMode }, .paused)
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertFalse(h.application.calls.contains("registerForRemoteNotifications"))
        XCTAssertFalse(h.logs.contains("token.missing"), "no token is expected while SallaPush does not register")
        XCTAssertFalse(h.logs.contains("init.no_delegate"))
        XCTAssertTrue(writtenFiles(h).isEmpty, "\(writtenFiles(h))")
        XCTAssertTrue(h.snapshot.isLoggedIn, "the getters reflect the calls kept for consent")

        h.runtime.setConsentGiven(true)
        h.advance(5)
        XCTAssertEqual(h.server.templates, ["register", "link"], "the kept calls, in call order")
        XCTAssertTrue(h.snapshot.isLoggedIn)
        XCTAssertEqual(h.snapshot.externalId, "cust_a")
        XCTAssertEqual(h.application.calls.filter { $0 == "registerForRemoteNotifications" }.count, 1)
        XCTAssertEqual(h.logs.count("init.no_delegate"), 1, "the delegate check ran once consent was back")
    }

    /// Consent given again before the load ends: the pause is dropped, and the load ends like any other.
    func test_pauseAndConsentDuringLoad_cancelOut() throws {
        let h = Harness()
        try whileTheEngineLoads(h) {
            h.runtime.submit(.pushToken(PushToken(hex: Harness.tokenHex())))
            h.runtime.setConsentRequired(true)
            h.runtime.setConsentGiven(true)
        }
        h.settle()
        h.advance(3)
        XCTAssertEqual(h.server.templates, ["register"])
        XCTAssertEqual(h.application.calls.filter { $0 == "registerForRemoteNotifications" }.count, 1)
    }

    /// Timers never act while consent is withheld: the missing-token and missing-delegate checks armed before a pause are
    /// cancelled (no wake-ups), do nothing until consent comes back, and run then.
    func test_pauseWhileRunning_stopsTheTimers_andConsentBringsThemBack() throws {
        let h = Harness()
        h.center.hasDelegateValue = false
        h.initialize()
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.advance(1)
        let engine = try XCTUnwrap(h.engine)
        let consentBound: Set<Engine.TimerPurpose> = [.tokenMissing, .delegateCheck]
        XCTAssertEqual(engine.queue.sync { Set(engine.timers.keys) }.intersection(consentBound), consentBound)
        h.runtime.setConsentRequired(true)
        h.settle()
        XCTAssertTrue(engine.queue.sync { Set(engine.timers.keys) }.isDisjoint(with: consentBound), "cancelled")
        h.advance(60)
        XCTAssertFalse(h.logs.contains("token.missing"))
        XCTAssertFalse(h.logs.contains("init.no_delegate"))
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(h.logs.count("init.no_delegate"), 1)
        h.advance(30)
        XCTAssertEqual(h.logs.count("token.missing"), 1)
    }

    /// A call that reaches an engine that cannot take it (handed here to a paused engine directly, which the runtime's
    /// routing never does) is never dropped: it goes back to the runtime's buffer and is handled once consent is given.
    func test_aCallReachingAPausedEngine_isKept_andHandledWithConsent() throws {
        let h = Harness()
        h.registered()
        h.runtime.setConsentRequired(true)
        h.settle()
        let engine = try XCTUnwrap(h.engine)
        XCTAssertEqual(engine.queue.sync { engine.consentMode }, .paused)
        let sequence = h.runtime.state.withLock { state -> Int in
            state.callSequence += 1
            return state.callSequence
        }
        engine.submit(.login(externalId: "cust_a", token: SecretString(FakeServer.token(for: "cust_a"))), sequence: sequence)
        h.settle()
        XCTAssertTrue(h.runtime.state.withLock { $0.buffer.callSequences }.contains(sequence), "kept in the buffer")
        XCTAssertTrue(h.server.requests("link").isEmpty)
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(h.server.requests("link").count, 1)
    }

    // MARK: - A withdrawal while no engine runs

    /// Launch 1: consent required and given, registered, a customer linked and a tag on the server.
    private func consentedLinkedDeviceWithATag() throws -> (harness: Harness, deviceId: String) {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        h.login("customer.token.a")
        h.submit(.addTags(["a": "1"]))
        h.advance(15)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertNotNil(h.server.device(deviceId)?.externalId)
        XCTAssertEqual(h.server.device(deviceId)?.tags, ["a": "1"])
        return (h, deviceId)
    }

    /// Consent withdrawn at a later launch, with the consent calls before `initialize` (the documented order) or
    /// in any other order of setConsentRequired (R), setConsentGiven(false) (G) and initialize (I): the withdrawal
    /// runs once consent is required and the app id is known, also when no engine ran: the server is opted out,
    /// its tags cleared and unlinked, the minimised state is written, and SallaPush is idle afterwards.
    func test_withdrawalWithoutARunningEngine_isCarriedOut_inEveryOrder() throws {
        for order in ["RGI", "GRI", "GIR", "IGR", "IRG", "RIG"] {
            let (h, deviceId) = try consentedLinkedDeviceWithATag()
            let next = h.relaunch()
            let before = next.server.requests.count
            for step in order {
                switch step {
                case "R": next.runtime.setConsentRequired(true)
                case "G": next.runtime.setConsentGiven(false)
                default: next.initialize()
                }
                next.settle()
            }
            next.advance(30)
            let sent = Array(next.server.requests.dropFirst(before))
            XCTAssertEqual(sent.map(\.template), ["update", "tags", "unlink"], order)
            XCTAssertEqual(sent.first?.json["opted_in"] as? Bool, false, order)
            XCTAssertEqual(sent.dropFirst().first?.json as NSDictionary?, ["remove": ["a"]] as NSDictionary, order)
            XCTAssertEqual(next.server.device(deviceId)?.optedIn, false, order)
            XCTAssertNil(next.server.device(deviceId)?.externalId, order)
            XCTAssertEqual(next.server.device(deviceId)?.tags, [:], order)
            XCTAssertEqual(next.logs.all.filter { $0.code == "consent.revoked" }.map(\.message),
                           ["Consent withdrawn; opted out and unlinked on the server; its tags were cleared. SallaPush is "
                                + "now idle."], order)
            XCTAssertEqual(next.file("identity.json")["server_link"] as? String, "unknown", "\(order): minimised on disk")
            XCTAssertEqual(next.file("state.json")["last_device_id"] as? String, deviceId, "\(order): the row is kept")
            next.submit(.setLanguage("fr"))
            next.runtime.login(externalId: "cust_a", identityToken: FakeServer.token(for: "cust_a"))
            next.advance(60)
            XCTAssertEqual(next.server.requests.count, before + 3, "\(order): idle afterwards")
        }
    }

    /// The withdrawal of a configuration that requires consent, before `initialize`, is carried out too.
    func test_withdrawalBeforeInitialize_withConsentRequiredByTheConfiguration_isCarriedOut() throws {
        let (h, deviceId) = try consentedLinkedDeviceWithATag()
        let next = h.relaunch()
        let before = next.server.requests.count
        next.runtime.setConsentGiven(false)
        next.initialize { $0.requiresUserConsent = true }
        next.advance(30)
        XCTAssertEqual(Array(next.server.requests.dropFirst(before)).map(\.template), ["update", "tags", "unlink"])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        XCTAssertTrue(next.logs.contains("consent.revoked"))
    }

    /// A withdrawal taken back before `initialize` is no withdrawal: SallaPush starts as usual and sends nothing extra.
    func test_withdrawalTakenBackBeforeInitialize_sendsNothing() throws {
        let (h, deviceId) = try consentedLinkedDeviceWithATag()
        let next = h.relaunch()
        let before = next.server.requests.count
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.runtime.setConsentGiven(true)
        next.initialize()
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, before)
        XCTAssertNotNil(next.server.device(deviceId)?.externalId)
        XCTAssertFalse(next.logs.contains("consent.revoked"))
    }

    /// A device that never registered has nothing on the server: the withdrawal sends nothing, mints no installation id
    /// and says so.
    func test_withdrawalWithoutAnEngine_ofAnUnregisteredDevice_sendsNothing() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.initialize()
        let next = h.relaunch()
        let writes = next.keychainAccess.writeCount
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.initialize()
        next.advance(30)
        XCTAssertTrue(next.server.requests.isEmpty)
        XCTAssertEqual(next.keychainAccess.writeCount, writes)
        XCTAssertEqual(next.logs.all.last { $0.code == "consent.revoked" }?.message,
                       "Consent withdrawn; this device was not registered, so the server holds nothing to minimise. "
                           + "SallaPush is now idle.")
    }

    /// Consent given after a withdrawal carried out without a running engine resumes the engine that carried it out:
    /// `opted_in` is sent again and the customer is linked again by the app's login.
    func test_consentGivenAfterAWithdrawalWithoutAnEngine_resumesAndRelinks() throws {
        let (h, deviceId) = try consentedLinkedDeviceWithATag()
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.initialize()
        next.advance(30)
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        next.runtime.login(externalId: next.server.customer(of: "customer.token.a"), identityToken: "customer.token.a")
        next.runtime.setConsentGiven(true)
        next.advance(5)
        XCTAssertEqual(next.server.device(deviceId)?.optedIn, true)
        XCTAssertNotNil(next.server.device(deviceId)?.externalId)
        XCTAssertEqual(next.server.requests("register").count, 1, "the same row")
    }

    // MARK: - A consent.json that cannot be read yet

    /// consent.json is protected at `initialize` (a launch before the first unlock): its answer is unknown, never "not
    /// given". SallaPush waits, reads it again at the unlock, then starts and sends the launch login, with no new
    /// setConsentGiven(true).
    func test_protectedConsentFile_isReadAgainAtTheUnlock_andTheLaunchLoginGoesOut() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let next = h.relaunch()
        next.logs.clear()
        let before = next.server.requests.count
        next.protectedFiles.set(["consent.json"])
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.runtime.login(externalId: "cust_b", identityToken: FakeServer.token(for: "cust_b"))
        next.advance(30)
        XCTAssertNil(next.engine, "SallaPush waits: the answer is unknown")
        XCTAssertEqual(next.server.requests.count, before)
        XCTAssertEqual(next.logs.all.filter { $0.code == "storage.keychain_locked" }.map(\.message),
                       ["SallaPush consent (consent.json) is unavailable until first unlock; waiting."])
        next.protectedFiles.set([])
        next.send(.protectedDataAvailable)
        next.advance(5)
        XCTAssertNotNil(next.engine)
        XCTAssertEqual(Array(next.server.requests.dropFirst(before)).map(\.template), ["link"])
        XCTAssertFalse(next.logs.contains("consent.given"), "no new setConsentGiven was needed")
    }

    /// A read failure other than protection (here a file without read permission) is waited out the same way, logged as
    /// a storage failure, and the next foreground reads the file again.
    func test_unreadableConsentFile_isReadAgainAtTheNextForeground() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let next = h.relaunch()
        let path = next.root.appendingPathComponent("consent.json").path
        XCTAssertEqual(chmod(path, 0o000), 0)
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.advance(10)
        XCTAssertNil(next.engine)
        let failure = try XCTUnwrap(next.logs.all.first { $0.code == "storage.failed" })
        XCTAssertTrue(failure.message.hasPrefix("Could not read SallaPush consent (consent.json: "), failure.message)
        XCTAssertEqual(chmod(path, 0o644), 0)
        next.send(.willEnterForeground)
        next.advance(2)
        XCTAssertNotNil(next.engine)
    }

    /// The next consent call or `initialize` reads the file again too.
    func test_unreadableConsentFile_isReadAgainAtTheNextConsentCall() {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let next = h.relaunch()
        next.protectedFiles.set(["consent.json"])
        next.runtime.setConsentRequired(true)
        next.initialize()
        XCTAssertNil(next.engine)
        next.protectedFiles.set([])
        next.runtime.setConsentRequired(true)
        next.advance(2)
        XCTAssertNotNil(next.engine)
    }

    /// The app withdraws consent while the file cannot be read, and the file still says "given": once it can be read,
    /// that is a withdrawal, carried out; and the app's answer is written after the read, never before it.
    func test_withdrawalWhileTheConsentFileIsUnreadable_isCarriedOutOnceItCanBeRead() throws {
        let (h, deviceId) = try consentedLinkedDeviceWithATag()
        let next = h.relaunch()
        let before = next.server.requests.count
        next.protectedFiles.set(["consent.json"])
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.initialize()
        next.advance(10)
        XCTAssertEqual(next.server.requests.count, before)
        next.protectedFiles.set([])
        next.send(.protectedDataAvailable)
        next.advance(30)
        XCTAssertEqual(Array(next.server.requests.dropFirst(before)).map(\.template), ["update", "tags", "unlink"])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        let data = try Data(contentsOf: next.root.appendingPathComponent("consent.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["given"] as? Bool, false, "written once the file was read")
    }

    /// The app gives consent and withdraws it again while the file cannot be read: the withdrawal runs at once (consent
    /// was given in this process), and reading the file later, which still says "given", starts no second one.
    func test_consentGivenThenWithdrawn_whileTheConsentFileIsUnreadable_withdrawsOnce() throws {
        let (h, deviceId) = try consentedLinkedDeviceWithATag()
        let next = h.relaunch()
        next.logs.clear()
        let before = next.server.requests.count
        next.protectedFiles.set(["consent.json"])
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(true)
        next.initialize()
        next.advance(3)
        next.runtime.setConsentGiven(false)
        next.advance(30)
        XCTAssertEqual(Array(next.server.requests.dropFirst(before)).map(\.template), ["update", "tags", "unlink"])
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        next.protectedFiles.set([])
        next.send(.protectedDataAvailable)
        next.advance(30)
        XCTAssertEqual(next.server.requests.count, before + 3, "no second withdrawal")
        XCTAssertEqual(next.logs.count("consent.revoked"), 1)
    }

    /// The app gives consent while the file (which says "not given") cannot be read: its answer stands at once, and is
    /// written once the file was read, never before.
    func test_consentGivenWhileTheConsentFileIsUnreadable_startsAtOnce_andIsWrittenAfterTheRead() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(false)
        h.initialize()
        let next = h.relaunch()
        let url = next.root.appendingPathComponent("consent.json")
        func stored() throws -> Bool? {
            let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
            return object?["given"] as? Bool
        }
        XCTAssertEqual(try stored(), false)
        next.protectedFiles.set(["consent.json"])
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(true)
        next.registered()
        XCTAssertEqual(next.server.requests("register").count, 1, "the app's answer stands at once")
        XCTAssertEqual(try stored(), false, "not written before the file was read")
        next.protectedFiles.set([])
        next.send(.willEnterForeground)
        next.settle()
        XCTAssertEqual(try stored(), true)
        XCTAssertEqual(next.server.requests("register").count, 1)
    }

    /// A corrupt consent.json counts as "not given" (logged); the app's next answer replaces it.
    func test_corruptConsentFile_countsAsNotGiven_andIsLogged() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let next = h.relaunch()
        try Data("{ not json".utf8).write(to: next.root.appendingPathComponent("consent.json"))
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.advance(5)
        XCTAssertNil(next.engine)
        XCTAssertTrue(next.logs.all.contains { $0.code == "storage.state_reset" && $0.message.contains("consent.json") })
        next.runtime.setConsentGiven(true)
        next.advance(2)
        XCTAssertNotNil(next.engine)
    }
}
