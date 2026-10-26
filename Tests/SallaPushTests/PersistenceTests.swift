import Foundation
import Security
@testable import SallaPush
@testable import SallaPushCore
import XCTest

final class PersistenceTests: XCTestCase {
    private func pendingLogout() -> Harness {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        return h
    }

    func test_pendingLogout_survivesRelaunch() {
        let h = pendingLogout()
        let attempts = h.server.requests("unlink").count
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(2)
        XCTAssertEqual(next.server.requests("unlink").count, attempts + 1)
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
        XCTAssertTrue(next.identityOps().isEmpty)
    }

    func test_corruptStateFile_keepsPendingLogout() throws {
        let h = pendingLogout()
        let stateURL = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/state.json")
        try Data("{ not json".utf8).write(to: stateURL)
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(2)
        XCTAssertTrue(next.logs.contains("storage.state_reset"))
        let corruptCopy = stateURL.deletingLastPathComponent().appendingPathComponent("state.corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptCopy.path))
        XCTAssertNil(next.server.device(next.deviceId)?.externalId, "the logout still went out")
    }

    /// A corrupt identity.json restarts the identity unknown, as after a reinstall: the launch logout unlinks the device.
    func test_corruptIdentityFile_restartsUnknown_andTheLaunchLogoutUnlinks() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let identityURL = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/identity.json")
        try Data("[]".utf8).write(to: identityURL)
        let next = h.relaunch()
        next.initialize()
        next.logout()
        next.advance(12)
        XCTAssertTrue(next.logs.contains("storage.state_reset"))
        XCTAssertEqual(next.server.requests("unlink").count, 1)
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
    }

    func test_protectedDataUnavailable_waits_neverAFreshInstall() throws {
        let h = Harness()
        h.registered()
        let deviceId = h.deviceId
        let next = h.relaunch()
        next.keychainAccess.forcedReadStatus = errSecInteractionNotAllowed
        next.initialize()
        next.sendToken(3)
        next.advance(30)
        XCTAssertEqual(next.server.requests("register").count, 1)
        XCTAssertTrue(next.logs.contains("storage.keychain_locked"))
        next.keychainAccess.forcedReadStatus = nil
        next.send(.protectedDataAvailable)
        next.advance(2)
        XCTAssertEqual(next.server.requests("register").count, 1, "the same device continues")
        XCTAssertEqual(next.deviceId, deviceId)
        XCTAssertEqual(next.server.requests("update").last?.json["push_token"] as? String, Harness.tokenHex(3))
    }

    /// One spurious errSecInteractionNotAllowed never strands the engine: the app's activation retries.
    func test_spuriousInteractionNotAllowed_recoversOnTheNextActivation() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        let next = h.relaunch()
        next.keychainAccess.forcedReadStatus = errSecInteractionNotAllowed
        next.application.state = .background
        next.initialize()
        let engine = try XCTUnwrap(next.engine)
        XCTAssertEqual(engine.queue.sync { engine.phase }, .waitingForProtectedData)
        next.keychainAccess.forcedReadStatus = nil
        next.application.state = .active
        next.send(.willEnterForeground)
        next.send(.didBecomeActive)
        next.logout()
        next.advance(5)
        XCTAssertEqual(engine.queue.sync { engine.phase }, .running)
        XCTAssertEqual(next.server.requests("unlink").count, 1, "the pending work went out in the same session")
    }

    /// The engine's own buffer, for calls made while it waits for protected data, reports one
    /// dropped call in the singular, like the runtime's.
    func test_callsWhileWaitingForProtectedData_overflowByOne_isReportedInTheSingular() throws {
        let h = Harness()
        h.registered()
        let next = h.relaunch()
        next.keychainAccess.forcedReadStatus = errSecInteractionNotAllowed
        next.initialize()
        for index in 0...PreInitBuffer.maximumCalls {
            next.runtime.addTags(["k\(index)": "v"])
        }
        next.settle()
        XCTAssertFalse(next.logs.contains("init.buffer_full"), "reported when the calls are replayed")
        next.keychainAccess.forcedReadStatus = nil
        next.send(.protectedDataAvailable)
        let entry = try XCTUnwrap(next.logs.all.last { $0.code == "init.buffer_full" })
        XCTAssertEqual(entry.message, "Too many calls before SallaPush started; 1 tag/language/opt-in call was dropped "
                       + "(login/logout calls are kept).")
        XCTAssertEqual(entry.metadata["count"], "1")
        XCTAssertNil(next.snapshot.tags["k0"], "the oldest call is the one dropped")
        XCTAssertEqual(next.snapshot.tags["k100"], "v")
    }

    /// A failed identity.json write is logged once, the logout still goes out, and the next change
    /// writes the file again.
    func test_failedIdentityWrite_isLoggedOnce_andTheLogoutStillGoesOut() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.failingWrites.set(["identity.json"])
        h.logout()
        h.advance(2)
        h.submit(.setLanguage("en"))
        h.advance(2)
        XCTAssertEqual(h.server.requests("unlink").count, 1)
        let failures = h.logs.all.filter { $0.code == "storage.failed" }
        XCTAssertEqual(failures.count, 1, "once per file and launch")
        XCTAssertTrue(failures.first?.message.contains("identity.json") ?? false)
        XCTAssertEqual(h.file("identity.json")["desired"] as? String, "customer", "the old file is still on disk")
        h.failingWrites.set([])
        h.submit(.setLanguage("fr"))
        h.advance(2)
        XCTAssertEqual(h.file("identity.json")["desired"] as? String, "guest", "written again with the next change")
    }

    /// A corrupt or tampered file with out-of-range integers never traps; it is set aside.
    func test_outOfRangeIntegers_inTheFiles_neverTrap_andResetTheFile() throws {
        let cases: [(file: String, mutate: (inout [String: Any]) -> Void)] = [
            ("identity.json", { $0["ops"] = [Self.op(id: Int.max)] }),
            ("identity.json", { $0["ops"] = [Self.op(id: -5)] }),
            ("state.json", { $0["ops"] = [["id": Int.max, "kind": "update", "attempts": 0, "next_at": 0.0] as [String: Any]] }),
            ("state.json", { $0["tags"] = ["mirror": [String: String](),
                                           "pending_add": ["a": ["v": "1", "epoch": Int.max] as [String: Any]],
                                           "pending_remove": [String: Int]()] as [String: Any] }),
            ("state.json", { $0["tags"] = ["mirror": [String: String](), "pending_add": [String: Any](),
                                           "pending_remove": ["a": Int.min]] as [String: Any] }),
        ]
        for (index, testCase) in cases.enumerated() {
            let h = Harness()
            h.registered()
            try rewrite(h, testCase.file, testCase.mutate)
            let next = h.relaunch()
            next.initialize()
            next.submit(.addTags(["after": "1"]))
            next.login("customer.token.b")
            next.advance(12)
            let engine = try XCTUnwrap(next.engine, "case \(index)")
            XCTAssertEqual(engine.queue.sync { engine.phase }, .running, "case \(index)")
            XCTAssertTrue(next.logs.contains("storage.state_reset"), "case \(index)")
            let corrupt = next.root.appendingPathComponent("st_42_ios/\(next.hostTag)/"
                                                           + testCase.file.replacingOccurrences(of: ".json", with: ".corrupt.json"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path), "case \(index)")
            XCTAssertEqual(next.server.requests("link").count, 1, "case \(index): the engine works on")
        }
    }

    /// A file nested thousands of levels deep, or written in UTF-16, is set aside as corrupt on the
    /// engine queue (a 512 KB stack) and never reaches the recursive parser; the pending logout in the other file still
    /// goes out.
    func test_deepOrNonUTF8Files_areCorrupt_neverParsed() throws {
        let h = pendingLogout()
        let folder = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)")
        let deep = "{\"v\":1,\"x\":" + String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000) + "}"
        try Data(deep.utf8).write(to: folder.appendingPathComponent("state.json"))
        try (#"{"v":1}"#.data(using: .utf16LittleEndian) ?? Data([0])).write(to: folder.appendingPathComponent("events.json"))
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(2)
        XCTAssertTrue(next.logs.contains("storage.state_reset"))
        for name in ["state.corrupt.json", "events.corrupt.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }
        XCTAssertNil(next.server.device(next.deviceId)?.externalId, "the logout still went out")
        let engine = try XCTUnwrap(next.engine)
        XCTAssertEqual(engine.queue.sync { engine.phase }, .running)
    }

    /// The decoders bound every persisted integer: counters must lie in `0...2^53`, tag epochs in `-2^53...2^53` (a
    /// negative epoch is a "previous customer" mark of an earlier version, dropped when read), attempt counts are
    /// clamped.
    func test_persistedIntegers_areBoundedWhenDecoded() throws {
        func identityOp(_ fields: String) throws -> IdentityOp {
            try JSONDecoder().decode(IdentityOp.self, from: Data(("{\"kind\":\"logout\"," + fields + "}").utf8))
        }
        XCTAssertEqual(try identityOp(#""id":9007199254740992,"attempts":3"#).id, 1 << 53)
        XCTAssertThrowsError(try identityOp(#""id":9007199254740993"#))
        XCTAssertThrowsError(try identityOp(#""id":-1"#))
        XCTAssertEqual(try identityOp(#""id":1,"attempts":9223372036854775807"#).retry.attempts, PersistedInteger.maximumAttempts)
        XCTAssertEqual(try identityOp(#""id":1,"attempts":-3"#).retry.attempts, 0)
        let stateOp = #"{"id":9223372036854775807,"kind":"update"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(StateOp.self, from: Data(stateOp.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(PendingTagAdd.self, from: Data(#"{"v":"1","epoch":-2}"#.utf8)).epoch, -2)
        XCTAssertThrowsError(try JSONDecoder().decode(PendingTagAdd.self, from: Data(#"{"v":"1","epoch":-9007199254740993}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(PendingTagAdd.self, from: Data(#"{"v":"1","epoch":9007199254740993}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(TagState.self, from: Data(#"{"pending_remove":{"a":-9007199254740993}}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(TagState.self, from: Data(#"{"pending_remove":{"a":-1}}"#.utf8)).pendingRemove, [:])
        XCTAssertEqual(try JSONDecoder().decode(TagState.self, from: Data(#"{"pending_remove":{"a":7}}"#.utf8)).pendingRemove, ["a": 7])
        var retry = RetryState()
        retry.attempts = PersistedInteger.maximumAttempts
        retry.recordAttempt()
        XCTAssertEqual(retry.attempts, PersistedInteger.maximumAttempts, "counting saturates")
        XCTAssertEqual(Int.max.saturatingIncrement, Int.max)
    }

    func test_hugeAttemptCounts_areClamped_andNeverTrap() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        try rewrite(h, "identity.json") { identity in
            var ops = identity["ops"] as? [[String: Any]] ?? []
            for index in ops.indices { ops[index]["attempts"] = Int.max }
            identity["ops"] = ops
        }
        let before = h.server.requests("unlink").count
        let next = h.relaunch()
        next.initialize()
        next.advance(30)
        XCTAssertFalse(next.logs.contains("storage.state_reset"), "a clamped count is not corruption")
        let attempts = next.identityOps().first?["attempts"] as? Int ?? 0
        XCTAssertEqual(attempts, PersistedInteger.maximumAttempts, "clamped, and counting saturates")
        XCTAssertEqual(next.server.requests("unlink").count, before + 1, "the logout is still retried")
    }

    /// A clock moved back by years never leaves an operation waiting for years (as on Android, a day at most).
    func test_waitsBeyondADay_areCut_whenTheClockMovedBack() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let tenYears = h.clock.now() + 10 * 365 * 86_400
        try rewrite(h, "identity.json") { identity in
            var ops = identity["ops"] as? [[String: Any]] ?? []
            // No failure recorded: only the cut of the impossible wait can make it ready.
            for index in ops.indices {
                ops[index]["next_at"] = tenYears
                ops[index]["last_failure"] = NSNull()
            }
            identity["ops"] = ops
        }
        let next = h.relaunch()
        next.server.clearScripts()
        next.initialize()
        next.advance(5)
        XCTAssertTrue(next.identityOps().isEmpty, "the logout went out at once")
        XCTAssertNil(next.server.device(next.deviceId)?.externalId)
    }

    /// Persisted identifiers go back to the server, so invalid ones are dropped at load with one ERROR. A
    /// `last_device_id` that is not a UUID would keep the registration at `400` for good; an external id push-service
    /// never links would make every login a `400`.
    func test_invalidPersistedIdentifiers_areDropped_andNeverSent() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.keychainAccess.removeAll(matching: "device_credentials.st_42_ios.\(h.hostTag)")
        try rewrite(h, "state.json") { state in
            state["last_device_id"] = "not-a-uuid"
            var push = state["push"] as? [String: Any] ?? [:]
            push["token"] = "ZZ-not-hex"
            state["push"] = push
        }
        try rewrite(h, "identity.json") { identity in
            identity["desired_external_id"] = String(repeating: "x", count: 129)
            identity["server_link"] = "none"
            identity["linked_external_id"] = "cust_x"
        }
        let next = h.relaunch()
        next.initialize()
        let reset = try XCTUnwrap(next.logs.all.first { $0.code == "storage.state_reset" })
        XCTAssertEqual(reset.message, "SallaPush state held invalid values (last_device_id, push.token, desired_external_id, "
                       + "linked_external_id); they were reset.")
        XCTAssertEqual(reset.level, .error)
        next.sendToken()
        next.advance(2)
        let register = try XCTUnwrap(next.server.requests("register").last)
        XCTAssertNil(register.json["previous_device_id"], "an invalid id is never sent")
        XCTAssertEqual(register.json["push_token"] as? String, Harness.tokenHex())
        XCTAssertNil(next.snapshot.externalId)
        next.login("customer.token.b")
        next.advance(2)
        XCTAssertEqual(next.server.requests("link").count, 2)
        XCTAssertEqual(next.server.requests("link").last?.json["external_id"] as? String,
                       next.server.customer(of: "customer.token.b"))
        XCTAssertEqual(next.file("state.json")["last_device_id"] as? String, next.deviceId)
    }

    /// An external id kept while no customer is asserted could not have been written by SallaPush: it is dropped at
    /// load with one ERROR, so it never turns a guest's first login into an account switch that drops the guest's tags.
    func test_aSavedExternalIdWithoutAnAssertedCustomer_isDroppedAtLoad() throws {
        let h = Harness()
        h.registered()
        h.submit(.addTags(["lang": "ar"]))
        h.advance(11)
        try rewrite(h, "identity.json") { identity in
            identity["desired"] = "guest"
            identity["desired_external_id"] = "cust_b"
        }
        let next = h.relaunch()
        next.initialize()
        let reset = try XCTUnwrap(next.logs.all.first { $0.code == "storage.state_reset" })
        XCTAssertEqual(reset.message, "SallaPush state held invalid values (desired_external_id); they were reset.")
        next.login(customer: "cust_a")
        next.advance(15)
        XCTAssertEqual(next.snapshot.externalId, "cust_a")
        XCTAssertEqual(next.snapshot.tags, ["lang": "ar"], "the guest's tags stay")
        XCTAssertFalse(next.logs.contains("login.switched"))
    }

    // MARK: - State an earlier version saved

    /// push-service has no dead-token answer: an earlier version's state that marked one loads as registered with its
    /// credentials, sends its fields once, and its tags go.
    func test_aTokenDeadStateOfBeta1_loadsAsRegistered() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        try rewrite(h, "state.json") { state in
            var registration = state["registration"] as? [String: Any] ?? [:]
            registration["status"] = "token_dead"
            state["registration"] = registration
        }
        let next = h.relaunch()
        next.initialize()
        next.submit(.addTags(["a": "1"]))
        next.advance(12)
        XCTAssertEqual((next.file("state.json")["registration"] as? [String: Any])?["status"] as? String, "registered")
        XCTAssertEqual(next.deviceId, deviceId, "the credentials are kept")
        XCTAssertEqual(next.server.requests("register").count, 1)
        XCTAssertEqual(next.server.requests("update").count, 1, "one full update")
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["a": "1"])
        XCTAssertFalse(next.logs.contains("storage.state_reset"))
    }

    /// A registration waiting 24 h on an answer push-service no longer gives (`app_mismatch`, `platform_mismatch`,
    /// `app_disabled`) registers at the next launch; a wait on one it still gives (`unknown_app`) stays.
    func test_aDormancyOfBeta1_forAnAnswerPushServiceNoLongerGives_endsAtLoad() throws {
        for (reason, endsAtLoad) in [("app_mismatch", true), ("platform_mismatch", true), ("app_disabled", true),
                                     ("unknown_app", false)] {
            let h = Harness()
            h.server.script("register") { _ in FakeServer.error(404, "unknown_app") }
            h.registered()
            XCTAssertEqual(h.server.requests("register").count, 1, reason)
            try rewrite(h, "state.json") { state in
                var registration = state["registration"] as? [String: Any] ?? [:]
                registration["dormant_reason"] = reason
                state["registration"] = registration
            }
            let next = h.relaunch()
            next.initialize()
            next.advance(5)
            XCTAssertEqual(next.server.requests("register").count, endsAtLoad ? 2 : 1, reason)
            XCTAssertEqual(next.deviceId != nil, endsAtLoad, reason)
            XCTAssertFalse(next.logs.contains("storage.state_reset"), reason)
        }
    }

    private static func op(id: Int) -> [String: Any] {
        ["id": id, "kind": "logout", "external_id": NSNull(), "clear_tags": true, "tag_keys": [String](), "tags_cleared": false,
         "tags_rechecked": false, "sent": false, "attempts": 0, "next_at": 0.0, "last_attempt_at": 0.0,
         "last_failure": NSNull(), "dormant_until": NSNull()]
    }

    private func rewrite(_ h: Harness, _ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/\(name)")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func test_keychainUnavailable_runsWithoutRegistration_andMintsNoId() {
        let h = Harness()
        h.keychainAccess.forcedReadStatus = errSecMissingEntitlement
        h.initialize()
        h.sendToken()
        h.advance(30)
        XCTAssertTrue(h.server.requests.isEmpty)
        XCTAssertTrue(h.logs.contains("storage.failed"))
        XCTAssertEqual(h.keychainAccess.writeCount, 0)
    }

    func test_identityFile_matchesTheFrozenSchema() throws {
        let h = Harness()
        h.registered()
        h.login("customer.token.a")
        h.advance(2)
        h.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        h.logout()
        h.advance(3)
        let identity = h.file("identity.json")
        XCTAssertEqual(Set(identity.keys), Self.identityKeys)
        XCTAssertEqual(identity["desired"] as? String, "guest")
        XCTAssertTrue(identity["desired_external_id"] is NSNull)
        XCTAssertEqual(identity["server_link"] as? String, "linked")
        let op = try XCTUnwrap((identity["ops"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(op.keys), ["id", "kind", "external_id", "clear_tags", "tag_keys", "tags_cleared", "tags_rechecked",
                                      "sent", "attempts", "next_at", "last_attempt_at", "last_failure", "dormant_until"])
        XCTAssertEqual(op["kind"] as? String, "logout")
        XCTAssertEqual(op["last_failure"] as? String, "network")

        let state = h.file("state.json")
        XCTAssertEqual(Set(state.keys), ["v", "app_id", "last_device_id", "registration", "push", "tags", "ops", "pending_clicks"])
        let registration = try XCTUnwrap(state["registration"] as? [String: Any])
        XCTAssertEqual(Set(registration.keys), ["status", "registered_token", "registered_env", "sent_fingerprint",
                                                "last_full_update_at", "dormant_until", "dormant_reason"])
        XCTAssertEqual(Set((state["push"] as? [String: Any] ?? [:]).keys), ["token", "user_opted_out", "language"])
        XCTAssertEqual(Set((state["tags"] as? [String: Any] ?? [:]).keys), ["mirror", "pending_add", "pending_remove"])
        let events = h.file("events.json")
        XCTAssertEqual(Set(events.keys).isSubset(of: ["v", "pending", "seen"]), true)
    }

    func test_filesLiveUnderTheAppAndHostFolder() {
        let h = Harness()
        h.registered()
        let folder = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("identity.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.json").path))
        XCTAssertEqual(h.hostTag.count, 8)
    }
}

// MARK: - Upgrade from an earlier version

extension PersistenceTests {
    static let identityKeys: Set<String> = ["v", "app_id", "api_base_url", "desired", "desired_external_id", "server_link",
                                            "linked_external_id", "server_tags", "ops"]

    /// identity.json as an earlier version writes it: Store API customer-token fingerprints, refusals, the legacy
    /// subscription id and the route key a login answer confirmed.
    private static func beta1Identity(base: String, desired: String, ops: [[String: Any]]) -> [String: Any] {
        ["v": 1, "app_id": "st_42_ios", "api_base_url": base, "desired": desired,
         "desired_fp": desired == "customer" ? "0123456789abcdef" : NSNull(), "server_link": "linked",
         "server_fp": "0123456789abcdef", "external_id": "route_key_1001", "login_unsupported": false,
         "rejected_fps": [["fp": "fedcba9876543210", "until": 1_790_000_000.0]], "revoked_fps": ["1111111111111111"],
         "legacy_onesignal_id": "os-player-1", "legacy_sent_for_fp": "0123456789abcdef", "server_tags": "some",
         "relogin_at": ["0123456789abcdef": 1_790_000_000.0], "unlinked_customer": NSNull(), "ops": ops]
    }

    /// An identity op as an earlier version writes it.
    private static func beta1Op(id: Int, kind: String, sent: Bool) -> [String: Any] {
        ["id": id, "kind": kind, "fp": kind == "login" ? "0123456789abcdef" : NSNull(), "clear_tags": true,
         "legacy_onesignal_id": kind == "login" ? "os-player-1" : NSNull(), "sent": sent, "attempts": sent ? 1 : 0,
         "next_at": 0.0, "last_attempt_at": 0.0, "last_failure": sent ? "network" : NSNull(), "dormant_until": NSNull()]
    }

    /// The tags op of an earlier version's state.json.
    private static let beta1TagsOp: [String: Any] = ["id": 9, "kind": "tags", "attempts": 0, "next_at": 0.0,
                                                     "last_attempt_at": 0.0, "last_failure": NSNull(),
                                                     "dormant_until": NSNull()]

    private func write(_ h: Harness, _ name: String, _ object: [String: Any]) throws {
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/\(name)")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// An earlier version's files load safely: the credentials, the tags and the consent are kept, and what served only
    /// the Store API login (token fingerprints, refusals, the legacy subscription id, the confirmed route key) is not
    /// read. The customer stays signed in, without an id, so the app's next login can't be told from another
    /// customer's: it is an account switch, whose tag clearing goes before the link (never skipped) and shows in the
    /// getters at once.
    func test_aBeta1SignedInState_loadsSafely_keepsCredentialsTagsAndConsent_andTheNextLoginIsASwitch() throws {
        let h = Harness()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.mutate(deviceId) { device in
            device.externalId = "route_key_1001"
            device.tags = ["plan": "gold"]
        }
        let base = try XCTUnwrap(h.file("identity.json")["api_base_url"] as? String)
        try write(h, "identity.json", Self.beta1Identity(base: base, desired: "customer", ops: []))
        try rewrite(h, "state.json") { state in
            state["tags"] = ["mirror": ["plan": "gold"], "pending_add": ["cart": ["v": "2", "epoch": 3]],
                             "pending_remove": [String: Int]()] as [String: Any]
            state["ops"] = [Self.beta1TagsOp]
        }
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.initialize()
        next.advance(15)
        XCTAssertNotNil(next.engine, "the consent is kept")
        XCTAssertFalse(next.logs.contains("storage.state_reset"), "an earlier version's file is not corrupt")
        XCTAssertEqual(next.deviceId, deviceId, "the credentials are kept")
        XCTAssertTrue(next.snapshot.isLoggedIn)
        XCTAssertNil(next.snapshot.externalId, "an earlier version's route key is not taken for the external id")
        XCTAssertEqual(next.snapshot.tags, ["plan": "gold", "cart": "2"], "the tags are kept")
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["plan": "gold", "cart": "2"], "the pending change went")
        let blocked = DispatchSemaphore(value: 0)
        try XCTUnwrap(next.engine).queue.async { blocked.wait() }
        let before = next.server.requests.count
        next.runtime.login(externalId: "1001", identityToken: FakeServer.token(for: "1001"))
        XCTAssertTrue(next.snapshot.tags.isEmpty, "the getters drop the tags at once")
        blocked.signal()
        next.advance(3)
        let sent = Array(next.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "link"], "no new registration, and the login is never skipped")
        XCTAssertEqual(sent.first?.json as NSDictionary?, ["remove": ["cart", "plan"]] as NSDictionary)
        XCTAssertEqual(next.logs.all.first { $0.code == "login.switched" }?.message,
                       "The previous customer's id is unknown (an upgrade from an earlier SallaPush version, or a "
                           + "consent withdrawal), so this login counts as an account switch; the previous customer's "
                           + "tags are cleared before the new customer is linked.")
        XCTAssertEqual(next.server.device(deviceId)?.externalId, "1001")
        XCTAssertEqual(next.server.device(deviceId)?.tags, [:])
        XCTAssertTrue(next.snapshot.tags.isEmpty)
        let identity = next.file("identity.json")
        XCTAssertEqual(Set(identity.keys), Self.identityKeys, "written in the new shape")
        XCTAssertEqual(identity["linked_external_id"] as? String, "1001")
    }

    /// An earlier version's log holding a login that may have reached the server, then a logout that clears the tags
    /// (that version emptied its copy of the tags at that logout): the login carries no external id and is dropped; the
    /// logout clears the tags the server's answer names and unlinks. A tag change that version marked as made before a
    /// login that could switch customers is dropped; the others go.
    func test_aBeta1LoginAndLogoutInTheLog_areUpgraded() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        h.server.mutate(deviceId) { device in
            device.externalId = "route_key_1001"
            device.tags = ["plan": "gold"]
        }
        let base = try XCTUnwrap(h.file("identity.json")["api_base_url"] as? String)
        try write(h, "identity.json", Self.beta1Identity(base: base, desired: "guest",
                                                         ops: [Self.beta1Op(id: 5, kind: "login", sent: true),
                                                               Self.beta1Op(id: 6, kind: "logout", sent: false)]))
        try rewrite(h, "state.json") { state in
            state["tags"] = ["mirror": [String: String](),
                             "pending_add": ["before_switch": ["v": "x", "epoch": -5], "guest": ["v": "1", "epoch": 9]],
                             "pending_remove": [String: Int]()] as [String: Any]
            state["ops"] = [Self.beta1TagsOp]
        }
        let next = h.relaunch()
        let before = next.server.requests.count
        next.initialize()
        next.advance(15)
        let sent = Array(next.server.requests.dropFirst(before))
        XCTAssertEqual(sent.map(\.template), ["tags", "tags", "unlink", "tags"])
        XCTAssertEqual(sent.first.flatMap { String(data: $0.body, encoding: .utf8) }, "{}")
        XCTAssertEqual(sent.dropFirst().first?.json as NSDictionary?, ["remove": ["plan"]] as NSDictionary)
        XCTAssertEqual(sent.last?.json as NSDictionary?, ["add": ["guest": "1"]] as NSDictionary)
        XCTAssertNil(next.server.device(deviceId)?.externalId)
        XCTAssertEqual(next.server.device(deviceId)?.tags, ["guest": "1"])
        XCTAssertEqual(next.snapshot.tags, ["guest": "1"])
        XCTAssertFalse(next.snapshot.isLoggedIn)
        XCTAssertFalse(next.logs.contains("storage.state_reset"))
        XCTAssertTrue(next.identityOps().isEmpty)
    }

    /// Every op kind and field of an earlier version decodes: its unlink is a logout, its login (no external id) is
    /// dropped, and a login that may have reached the server leaves the link unknown.
    func test_beta1Ops_decode() throws {
        let file = Self.beta1Identity(base: "https://push.salla.dev", desired: "customer",
                                      ops: [Self.beta1Op(id: 1, kind: "login", sent: true),
                                            Self.beta1Op(id: 2, kind: "unlink", sent: false),
                                            Self.beta1Op(id: 3, kind: "logout_confirm", sent: false)])
        var unlinked = file
        unlinked["server_link"] = "none"
        let decoded = try JSONDecoder().decode(IdentityState.self, from: JSONSerialization.data(withJSONObject: unlinked))
        XCTAssertEqual(decoded.ops.map(\.kind), [.logout, .logoutConfirm])
        XCTAssertEqual(decoded.ops.map(\.clearTags), [true, true])
        XCTAssertEqual(decoded.ops.map(\.tagKeys), [[], []])
        XCTAssertEqual(decoded.serverLink, .unknown, "the dropped login may have linked the device")
        XCTAssertEqual(decoded.desired, .customer)
        XCTAssertNil(decoded.desiredExternalId)
        XCTAssertNil(decoded.linkedExternalId)
        XCTAssertEqual(decoded.serverTags, .some)
    }
}
