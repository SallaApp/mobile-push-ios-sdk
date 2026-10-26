import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// One re-registration valve for every device-level re-registration, with Android's semantics and
/// persistence. These cases mirror Android's `RecoveryTest` valve cases one for one.
final class ReregistrationValveTests: XCTestCase {
    private let hour: Double = 3_600

    func test_reregistrationValve_firstAtOnce_secondHeldUntilAnHourAfterTheFirst() throws {
        let h = Harness()
        h.registered()
        let first = try holdASecondReregistration(h)
        XCTAssertTrue(h.logs.contains("register.reregistering"))
        XCTAssertEqual(h.logs.count("net.client_error"), 1)
        let held = try XCTUnwrap(h.logs.all.last { $0.code == "net.client_error" })
        XCTAssertEqual(held.level, .error)
        XCTAssertEqual(held.metadata["reason"], "unknown_device")
        XCTAssertEqual(held.metadata["http_status"], "404")
        let delay = try XCTUnwrap(Int(held.metadata["delay_s"] ?? ""))
        XCTAssertTrue((2_390...2_400).contains(delay), "\(delay)")
        XCTAssertTrue(held.message.contains("within an hour of the previous registration"), held.message)
        h.server.clearScripts()
        h.advance(first + hour - h.clock.now() - 1)
        XCTAssertEqual(h.server.requests("register").count, 2)
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 3)
        XCTAssertNil(h.server.requests("register").last?.json["previous_device_id"], "push-service takes none")
    }

    func test_secondInvalidSecretWithinAnHour_heldUntilAnHourAfterTheFirst() throws {
        let h = Harness()
        h.registered()
        h.server.script("update", times: nil) { _ in FakeServer.error(401, "invalid_device_secret") }
        h.submit(.setLanguage("en"))
        h.advance(5)
        XCTAssertEqual(h.server.requests("register").count, 2)
        let first = try XCTUnwrap(lastReregisterAt(h))
        h.advance(600)
        h.submit(.setLanguage("fr"))
        h.advance(5)
        XCTAssertEqual(h.logs.count("net.client_error"), 1)
        XCTAssertEqual(h.logs.all.last { $0.code == "net.client_error" }?.metadata["reason"], "invalid_device_secret")
        XCTAssertEqual(try XCTUnwrap(registerHold(h)), first + hour, accuracy: 0.001)
        h.server.clearScripts()
        h.advance(first + hour - h.clock.now() - 1)
        XCTAssertEqual(h.server.requests("register").count, 2)
        h.advance(2)
        XCTAssertEqual(h.server.requests("register").count, 3)
        XCTAssertNotNil(h.deviceId)
    }

    /// A server that keeps answering `unknown_device` gets exactly one registration an hour, an hour after the
    /// previous one.
    func test_repeatedUnknownDevice_oneRegistrationPerHour_anHourAfterThePrevious() throws {
        let h = Harness()
        h.registered()
        h.server.script("update", times: nil) { _ in FakeServer.error(404, "unknown_device") }
        h.server.script("tags", times: nil) { _ in FakeServer.error(404, "unknown_device") }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 2)
        let first = try XCTUnwrap(lastReregisterAt(h))
        h.submit(.addTags(["plan": "gold"]))
        h.advance(12)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertTrue(h.logs.contains("net.client_error"))
        for index in 1...3 {
            let due = first + hour * Double(index)
            XCTAssertEqual(try XCTUnwrap(registerHold(h)), due, accuracy: 0.001, "hour \(index)")
            h.advance(due - h.clock.now() - 1)
            XCTAssertEqual(h.server.requests("register").count, 1 + index, "hour \(index)")
            h.advance(15)
            XCTAssertEqual(h.server.requests("register").count, 2 + index, "hour \(index)")
            XCTAssertEqual(h.server.requests("tags").count, 1 + index, "hour \(index)")
        }
        XCTAssertEqual(try XCTUnwrap(registerHold(h)), first + hour * 4, accuracy: 0.001)
    }

    /// No trigger shortens a hold: not a foreground, not a new token, not the background flush.
    func test_heldReregistration_notShortened_byForegroundNewTokenOrBackgroundFlush() throws {
        let h = Harness()
        h.registered()
        let first = try holdASecondReregistration(h)
        h.send(.didEnterBackground)
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.sendToken(2)
        h.send(.didEnterBackground)
        h.advance(60)
        XCTAssertEqual(h.server.requests("register").count, 2)
        XCTAssertEqual(try XCTUnwrap(registerHold(h)), first + hour, accuracy: 0.001)
        h.server.clearScripts()
        h.advance(first + hour - h.clock.now() + 1)
        XCTAssertEqual(h.server.requests("register").count, 3)
        XCTAssertEqual(h.server.requests("register").last?.json["push_token"] as? String, Harness.tokenHex(2))
    }

    func test_heldReregistration_survivesARelaunch_andCountsAsThePrevious() throws {
        let h = Harness()
        h.registered()
        let heldUntil = try holdASecondReregistration(h) + hour
        let next = h.relaunch()
        next.initialize()
        XCTAssertEqual(try XCTUnwrap(lastReregisterAt(next)), heldUntil, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(registerHold(next)), heldUntil, accuracy: 0.001)
        next.advance(60)
        XCTAssertEqual(next.server.requests("register").count, 2)

        // The server still purges the row: the next re-registration waits an hour after the restored one.
        let errors = next.logs.count("net.client_error")
        next.advance(heldUntil - next.clock.now() + 1)
        XCTAssertEqual(next.server.requests("register").count, 3)
        next.submit(.setLanguage("de"))
        next.advance(3)
        XCTAssertEqual(next.server.requests("register").count, 3)
        XCTAssertEqual(try XCTUnwrap(registerHold(next)), heldUntil + hour, accuracy: 0.001)
        XCTAssertEqual(next.logs.count("net.client_error"), errors + 1)
    }

    func test_heldReregistration_afterTheClockMovedBack_holdsAtMostAnHour() throws {
        let h = Harness()
        h.registered()
        _ = try holdASecondReregistration(h)
        let next = h.relaunch()
        next.clock.set(next.clock.now() - 3 * hour)
        let restartedAt = next.clock.now()
        next.initialize()
        XCTAssertEqual(try XCTUnwrap(registerHold(next)), restartedAt + hour, accuracy: 0.001)
        next.server.clearScripts()
        next.advance(restartedAt + hour - next.clock.now() - 1)
        XCTAssertEqual(next.server.requests("register").count, 2)
        next.advance(2)
        XCTAssertEqual(next.server.requests("register").count, 3)
    }

    /// A rejected registration's 24 h wait is not a re-registration: a relaunch never restores it as a hold.
    func test_dormantRegistration_isNotRestoredAsAHold() throws {
        let h = Harness()
        h.server.script("register") { _ in FakeServer.error(404, "unknown_app") }
        h.registered()
        XCTAssertEqual(h.logs.count("register.dormant"), 1)
        h.advance(86_400 - 1_800)
        let next = h.relaunch()
        next.initialize()
        XCTAssertNil(lastReregisterAt(next))
        next.advance(1_800 + 5)
        XCTAssertEqual(next.server.requests("register").count, 2, "the dormancy ended and the device registered")
        let errors = next.logs.count("net.client_error")
        next.server.script("update") { _ in FakeServer.error(404, "unknown_device") }
        next.submit(.setLanguage("en"))
        next.advance(3)
        XCTAssertEqual(next.server.requests("register").count, 3, "the first re-registration of the process runs at once")
        XCTAssertEqual(next.logs.count("net.client_error"), errors)
    }

    /// push-service's two answers that register a device again, `401 invalid_device_secret` and `404 unknown_device`,
    /// share one clock, on any device route: the second within an hour of the first waits until an hour after it.
    func test_valve_coversBothReregistrationAnswers_withOneClock() throws {
        let h = Harness()
        h.registered()
        h.server.script("update") { _ in FakeServer.error(401, "invalid_device_secret") }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 2)
        let first = try XCTUnwrap(lastReregisterAt(h))
        h.server.script("events") { _ in FakeServer.error(404, "unknown_device") }
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(60)
        XCTAssertEqual(h.server.requests("register").count, 2, "the second answer waits for the valve")
        let held = try XCTUnwrap(h.logs.all.last { $0.code == "net.client_error" })
        XCTAssertEqual(held.metadata["reason"], "unknown_device")
        XCTAssertEqual(held.metadata["route"], "/devices/{id}/events")
        XCTAssertEqual(try XCTUnwrap(registerHold(h)), first + hour, accuracy: 0.001)
        h.advance(first + hour - h.clock.now() + 1)
        XCTAssertEqual(h.server.requests("register").count, 3)
        h.advance(6)
        XCTAssertEqual(h.server.requests("events").count, 2, "the event goes once the device is registered again")
        XCTAssertNotNil(h.deviceId)
    }

    // MARK: - Helpers

    /// Two device-level re-registrations within an hour on a registered device: the first runs at once, the second
    /// is held. Returns the time of the first one; the hold ends an hour after it. `update` keeps answering
    /// `unknown_device` until the test clears the scripts.
    private func holdASecondReregistration(_ h: Harness) throws -> Double {
        h.server.script("update", times: nil) { _ in FakeServer.error(404, "unknown_device") }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 2, "the first re-registration runs at once")
        let first = try XCTUnwrap(lastReregisterAt(h))
        h.advance(1_200)
        h.submit(.setLanguage("fr"))
        h.advance(3)
        XCTAssertEqual(h.server.requests("register").count, 2, "the second one is held")
        XCTAssertEqual(try XCTUnwrap(registerHold(h)), first + hour, accuracy: 0.001)
        return first
    }

    private func lastReregisterAt(_ h: Harness) -> Double? {
        guard let engine = h.engine else { return nil }
        return engine.queue.sync { engine.lastReregisterAt }
    }

    /// The register op's own dormant wait (`retry.dormantUntil`).
    private func registerHold(_ h: Harness) -> Double? {
        guard let engine = h.engine else { return nil }
        return engine.queue.sync { engine.stateOp(.register)?.retry.dormantUntil }
    }
}
