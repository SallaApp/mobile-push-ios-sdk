import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The status lines: one `status.launch` per started main engine once its status is complete, then a `status.changed`
/// naming each field a turn changed, old → new. Both are info entries: they show the push token's last 6 characters and
/// the customer without their id, unless the Info.plist switch `SallaPushLogFullIdentifiers` is on, and never a secret.
final class StatusLogTests: XCTestCase {
    /// The harness's push token as the lines show it by default: `…` and its last 6 characters.
    private let maskedToken = "…" + String(Harness.tokenHex().suffix(6))

    private func messages(_ h: Harness, _ code: String) -> [String] {
        h.logs.all.filter { $0.code == code }.map(\.message)
    }

    /// A first launch logs one line once the engine read the permission: no device, no token, no login yet.
    func test_aFirstLaunch_logsOneLaunchLine_onceThePermissionIsRead() throws {
        let h = Harness()
        h.logs.logger.setRuntimeLevel(.info)
        h.center.status = .denied
        h.initialize()
        XCTAssertEqual(h.logs.count("status.launch"), 1)
        XCTAssertFalse(h.logs.contains("status.changed"))
        let launch = try XCTUnwrap(h.logs.all.first { $0.code == "status.launch" })
        let message = "SallaPush \(sallaPushSDKVersion) status at launch (foreground): app st_42_ios; device none (not "
            + "registered (no push token yet)); push token none (none, apns_env sandbox); permission denied; opted_in false "
            + "(user opted out: false); guest (no login yet); language device default."
        XCTAssertEqual(launch.message, message)
        XCTAssertEqual(launch.level, .info)
        XCTAssertEqual(launch.category, "lifecycle")
        XCTAssertEqual(launch.metadata, ["app_id": "st_42_ios"])
        XCTAssertEqual(h.logs.console.filter { $0.contains("status.") }, ["[SallaPush] INFO status.launch: " + message])
    }

    /// The token, then the registration's answer, log what they change: the token's last 6 characters, then the device
    /// id, the registration and the token's status.
    func test_theTokenAndTheRegistration_logTheFieldsTheyChange() throws {
        let h = Harness()
        h.initialize()
        h.sendToken()
        XCTAssertEqual(messages(h, "status.changed"), [
            "SallaPush status changed: registration not registered (no push token yet) → registering; push token none → "
                + "\(maskedToken); push token status none → not sent yet; opted_in false → true.",
        ])
        h.advance(2)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(messages(h, "status.changed").dropFirst(), [
            "SallaPush status changed: device none → \(deviceId); registration registering → registered; push token status "
                + "not sent yet → registered with the server.",
        ])
        XCTAssertEqual(h.logs.all.last { $0.code == "status.changed" }?.metadata,
                       ["app_id": "st_42_ios", "device_id": deviceId])
        XCTAssertEqual(h.logs.count("status.launch"), 1)
    }

    /// Every launch logs its own line: a registered device's names its id, its token's last 6 characters and its
    /// registration, and a launch that changes nothing logs no change.
    func test_aRelaunch_logsOneNewLaunchLine_withTheDeviceAndTheToken() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        let changes = h.logs.count("status.changed")
        let next = h.relaunch()
        next.initialize()
        XCTAssertEqual(next.logs.count("status.launch"), 2, "the relaunch shares the first launch's log")
        XCTAssertEqual(next.logs.count("status.changed"), changes)
        let launch = try XCTUnwrap(next.logs.all.last { $0.code == "status.launch" })
        XCTAssertEqual(launch.message,
                       "SallaPush \(sallaPushSDKVersion) status at launch (foreground): app st_42_ios; device \(deviceId) "
                           + "(registered); push token \(maskedToken) (registered with the server, apns_env sandbox); "
                           + "permission authorized; opted_in true (user opted out: false); guest (no login yet); language "
                           + "device default.")
        XCTAssertEqual(launch.metadata, ["app_id": "st_42_ios", "device_id": deviceId])
    }

    /// A registered device that relaunches in the other APNs environment (a device build without a profile: production)
    /// with the same token has not sent that environment yet: the token is registered again once the update is answered.
    func test_aRelaunchInTheOtherAPNsEnvironment_logsTheTokenNotSentYet_untilTheUpdateIsAnswered() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        let next = h.relaunch()
        next.simulatorProfile.set(false)
        next.initialize()
        XCTAssertEqual(next.logs.all.last { $0.code == "status.launch" }?.message,
                       "SallaPush \(sallaPushSDKVersion) status at launch (foreground): app st_42_ios; device \(deviceId) "
                           + "(registered); push token \(maskedToken) (not sent yet, apns_env production); "
                           + "permission authorized; opted_in true (user opted out: false); guest (no login yet); language "
                           + "device default.")
        let changes = next.logs.count("status.changed")
        next.advance(2)
        XCTAssertEqual(next.server.requests("update").last?.json["apns_env"] as? String, "production")
        XCTAssertEqual(messages(next, "status.changed").dropFirst(changes), [
            "SallaPush status changed: push token status not sent yet → registered with the server.",
        ])
    }

    /// A background launch that comes to the foreground before the engine's first permission read answers logs its
    /// launch line as one: the line says how the engine launched, not whether it still runs as a background launch.
    func test_aBackgroundLaunchThatComesToTheForegroundBeforeThePermissionRead_logsABackgroundLaunch() throws {
        let h = Harness()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        let next = h.relaunch()
        next.application.state = .background
        let reads = DispatchQueue(label: "test.permission.reads")
        reads.suspend()
        next.center.callbackQueue.set(reads)
        next.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        next.runtime.controlQueue.sync {}
        let engine = try XCTUnwrap(next.engine)
        engine.queue.sync {}
        engine.queue.sync {}
        XCTAssertTrue(engine.queue.sync { engine.isBackgroundLaunch && engine.permissionReadInFlight },
                      "a background launch whose first permission read is on its way")
        next.center.callbackQueue.set(nil)
        next.application.state = .active
        next.send(.willEnterForeground)
        XCTAssertFalse(engine.queue.sync { engine.isBackgroundLaunch }, "the foreground ends the background launch")
        XCTAssertEqual(next.logs.count("status.launch"), 1, "no launch line before the permission read answers")
        reads.resume()
        reads.sync {}
        next.settle()
        XCTAssertEqual(next.logs.all.last { $0.code == "status.launch" }?.message,
                       "SallaPush \(sallaPushSDKVersion) status at launch (background): app st_42_ios; device \(deviceId) "
                           + "(registered); push token \(maskedToken) (registered with the server, apns_env sandbox); "
                           + "permission authorized; opted_in true (user opted out: false); guest (no login yet); language "
                           + "device default.")
    }

    /// A permission changed in Settings is caught at the next foreground, and `opted_in` with it.
    func test_aPermissionChangeCaughtAtTheForeground_logsThePermissionAndOptedIn() {
        let h = Harness()
        h.center.status = .denied
        h.registered()
        h.center.status = .authorized
        h.send(.willEnterForeground)
        XCTAssertEqual(messages(h, "status.changed").last,
                       "SallaPush status changed: permission denied → authorized; opted_in false → true.")
    }

    func test_optOutAndOptIn_logOptedInAndTheUsersOptOut() {
        let h = Harness()
        h.registered()
        h.submit(.optOut)
        h.submit(.optIn)
        XCTAssertEqual(messages(h, "status.changed").suffix(2), [
            "SallaPush status changed: opted_in true → false; user opted out false → true.",
            "SallaPush status changed: opted_in false → true; user opted out true → false.",
        ])
    }

    /// A login shows the customer without their id, and the link's answer links them; a logout shows the guest once the
    /// server unlinked.
    func test_loginAndLogout_logTheCustomerAndTheirLink() {
        let h = Harness()
        h.registered()
        h.login(customer: "1001")
        h.advance(2)
        h.logout()
        h.advance(2)
        XCTAssertEqual(messages(h, "status.changed").suffix(4), [
            "SallaPush status changed: customer guest (no login yet) → id hidden (login pending).",
            "SallaPush status changed: customer id hidden (login pending) → id hidden (linked).",
            "SallaPush status changed: customer id hidden (linked) → guest (logout pending).",
            "SallaPush status changed: customer guest (logout pending) → guest.",
        ])
    }

    /// An account switch between two linked customers shows in `status.changed` only as the link's state, linked →
    /// login pending → linked, without either customer's id; `login.switched` names the switch.
    func test_anAccountSwitch_logsOnlyTheLinksState_andLoginSwitchedNamesIt() {
        let h = Harness()
        h.registered()
        h.login(customer: "1001")
        h.advance(2)
        let changes = h.logs.count("status.changed")
        h.login(customer: "1002")
        h.advance(2)
        XCTAssertEqual(messages(h, "status.changed").dropFirst(changes), [
            "SallaPush status changed: customer id hidden (linked) → id hidden (login pending).",
            "SallaPush status changed: customer id hidden (login pending) → id hidden (linked).",
        ])
        XCTAssertEqual(h.logs.count("login.switched"), 1)
    }

    /// One launch line per started engine: lifecycle notifications and a second `initialize` of the same app log none,
    /// and turns that change nothing in the status (a tags call, an events flush) log no change.
    func test_lifecycleEvents_aSecondInitialize_tagsAndEvents_logNoStatusLine() {
        let h = Harness()
        h.registered()
        let changes = h.logs.count("status.changed")
        h.send(.didEnterBackground)
        h.send(.willEnterForeground)
        h.send(.didBecomeActive)
        h.initialize()
        h.submit(.addTags(["a": "1"]))
        h.submit(.events([EventRecord(messageId: "msg_ab", type: .opened, at: h.clock.now(), actionId: nil)]))
        h.advance(30)
        XCTAssertEqual(h.server.requests("tags").count, 1)
        XCTAssertEqual(h.server.requests("events").count, 1)
        XCTAssertEqual(h.logs.count("status.launch"), 1)
        XCTAssertEqual(h.logs.count("status.changed"), changes)
    }

    /// An `initialize` with another app id starts an engine for it, which logs its own launch line; the previous one,
    /// with no logout to finish, stops and logs none.
    func test_anotherAppId_logsALaunchLineForIt() throws {
        let h = Harness()
        h.registered()
        let changes = h.logs.count("status.changed")
        h.initialize("st_43_ios")
        let launches = h.logs.all.filter { $0.code == "status.launch" }
        XCTAssertEqual(launches.count, 2)
        XCTAssertTrue(try XCTUnwrap(launches.last?.message).contains(": app st_43_ios; device none ("))
        XCTAssertEqual(launches.last?.metadata, ["app_id": "st_43_ios"])
        XCTAssertEqual(h.logs.count("status.changed"), changes)
    }

    /// A registration push-service refuses waits: the line names the reason and when it is tried again. The try at the
    /// end of the wait, which the pump starts, logs its own line.
    func test_aDormantRegistration_logsTheReasonAndTheNextTry() throws {
        let h = Harness()
        h.server.script("register") { _ in FakeServer.error(404, "unknown_app") }
        h.registered()
        let registration = try XCTUnwrap(h.file("state.json")["registration"] as? [String: Any])
        let until = try XCTUnwrap(registration["dormant_until"] as? Double)
        let dormant = "dormant (unknown_app) until \(ISO8601.string(from: until))"
        XCTAssertEqual(messages(h, "status.changed").last, "SallaPush status changed: registration registering → \(dormant).")
        h.advance(86_400)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(messages(h, "status.changed").suffix(2), [
            "SallaPush status changed: registration \(dormant) → retrying after a client failure.",
            "SallaPush status changed: device none → \(deviceId); registration retrying after a client failure → registered; "
                + "push token status not sent yet → registered with the server.",
        ])
    }

    /// Background time that runs out cancels the registration on the wire, outside an engine turn: the line says it
    /// waits to retry.
    func test_backgroundTimeRunningOut_logsTheRegistrationWaitingToRetry() throws {
        let h = Harness()
        h.server.script("register") { _ in .hold }
        h.initialize()
        h.sendToken()
        h.send(.didEnterBackground)
        let task = try XCTUnwrap(h.application.begunTasks.last)
        h.application.expire(task)
        h.settle()
        XCTAssertEqual(messages(h, "status.changed").last,
                       "SallaPush status changed: registration registering → retrying after a network failure.")
    }

    /// An engine that loads while consent is withheld reads no permission: its launch line comes at once and says so,
    /// and consent given later logs what it changes.
    func test_consentWithheldAtTheLoad_logsTheLaunchLineAtOnce() {
        let h = Harness()
        h.useAsynchronousSystemCallbacks()
        h.runtime.initialize(appId: "st_42_ios", configuration: SallaPushConfiguration())
        h.runtime.controlQueue.sync {}
        h.runtime.setConsentRequired(true)
        h.settle()
        XCTAssertEqual(messages(h, "status.launch"), [
            "SallaPush \(sallaPushSDKVersion) status at launch (foreground): app st_42_ios; device none (not registered "
                + "(consent not given)); push token none (none, apns_env sandbox); permission not read yet; opted_in false "
                + "(user opted out: false); guest (no login yet); language device default; consent paused.",
        ])
        h.runtime.setConsentGiven(true)
        h.settle()
        XCTAssertEqual(messages(h, "status.changed"), [
            "SallaPush status changed: registration not registered (consent not given) → not registered (no push token "
                + "yet); consent paused → normal.",
            "SallaPush status changed: permission not read yet → authorized.",
        ])
    }

    /// With the Info.plist switch `SallaPushLogFullIdentifiers` on, the status lines hold the full push token and the
    /// customer's id, and still no secret: never the device secret or the identity token. No other line holds the full
    /// token, on the console or in an entry.
    func test_withTheSwitchOn_theStatusLinesAloneHoldTheFullToken_andNoSecret() {
        let h = Harness()
        h.bundle.setObject("SallaPushLogFullIdentifiers", true)
        h.logs.logger.setRuntimeLevel(.verbose)
        let identityToken = "eyJ.1001.SECRET-identity-token"
        h.server.customers = { $0 == identityToken ? .linked("1001") : .rejected }
        h.registered()
        h.login(externalId: "1001", token: identityToken)
        h.advance(2)
        h.logout()
        h.advance(2)
        let secrets = h.server.allDevices.map(\.secret) + [identityToken, "SECRET"]
        let status = h.logs.all.filter { $0.code.hasPrefix("status.") }
        XCTAssertTrue(status.contains { $0.message.contains(Harness.tokenHex()) })
        XCTAssertTrue(status.contains { $0.message.contains("\"1001\" (linked)") })
        let entries = h.logs.all.map { ($0.code, $0.message + " " + $0.metadata.values.joined(separator: " ")) }
        let lines = h.logs.console.map { line in
            (line.contains(" status.launch: ") || line.contains(" status.changed: ") ? "status.line" : "line", line)
        }
        for (code, text) in entries + lines {
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(code) leaks a secret")
            }
            if !code.hasPrefix("status.") {
                XCTAssertFalse(text.contains(Harness.tokenHex()), "\(code) holds the full push token")
            }
        }
    }

    /// By default both lines show the push token as its last 6 characters and the customer without their id: a
    /// relaunch's launch line as much as the changes, on the console and in the handler's entries alike. No entry and no
    /// console line holds the full token or the id.
    func test_byDefault_bothLinesMaskTheTokenAndDropTheCustomersId_onTheConsoleAndInTheHandler() throws {
        let customer = "shopper-42"
        let h = Harness()
        h.logs.logger.setRuntimeLevel(.info)
        let handled = Locked<[SallaPushLogEntry]>([])
        h.logs.logger.setHandler(level: .info) { entry in handled.withLock { $0.append(entry) } }
        h.registered()
        h.login(customer: customer)
        h.advance(2)
        let next = h.relaunch()
        next.initialize()
        next.login(customer: customer)
        next.advance(2)
        next.logs.handlerQueue.sync {}
        XCTAssertTrue(messages(next, "status.changed").contains { $0.contains("push token none → \(maskedToken);") })
        XCTAssertTrue(messages(next, "status.changed").contains {
            $0 == "SallaPush status changed: customer guest (no login yet) → id hidden (login pending)."
        })
        XCTAssertEqual(next.logs.count("status.launch"), 2)
        let launch = try XCTUnwrap(messages(next, "status.launch").last)
        XCTAssertTrue(launch.contains("; push token \(maskedToken) (registered with the server, apns_env sandbox); "), launch)
        XCTAssertTrue(launch.contains("; customer id hidden ("), launch)
        let entries = handled.current.filter { $0.code.hasPrefix("status.") }.map(\.message)
        XCTAssertEqual(entries, next.logs.all.filter { $0.code.hasPrefix("status.") }.map(\.message))
        let consoleLines = next.logs.console.filter { $0.contains(" status.launch: ") || $0.contains(" status.changed: ") }
        XCTAssertEqual(consoleLines.count, entries.count)
        for text in entries + consoleLines {
            XCTAssertFalse(text.contains(Harness.tokenHex()), text)
            XCTAssertFalse(text.contains(customer), text)
        }
    }

    /// The Info.plist switch `SallaPushLogFullIdentifiers`, a Boolean YES, shows the full push token and the customer's
    /// id in both lines, for debugging.
    func test_theInfoPlistSwitch_showsTheFullTokenAndTheCustomersId_inBothLines() throws {
        let h = Harness()
        h.bundle.setObject("SallaPushLogFullIdentifiers", true)
        h.registered()
        h.login(customer: "1001")
        h.advance(2)
        XCTAssertTrue(messages(h, "status.changed").contains { $0.contains("push token none → \(Harness.tokenHex());") })
        XCTAssertEqual(messages(h, "status.changed").suffix(2), [
            "SallaPush status changed: customer guest (no login yet) → \"1001\" (login pending).",
            "SallaPush status changed: customer \"1001\" (login pending) → \"1001\" (linked).",
        ])
        let next = h.relaunch()
        next.initialize()
        let launch = try XCTUnwrap(messages(next, "status.launch").last)
        XCTAssertTrue(launch.contains("; push token \(Harness.tokenHex()) (registered with the server, apns_env sandbox); "),
                      launch)
        XCTAssertTrue(launch.contains("; customer \"1001\" ("), launch)
    }

    /// The switch is on for the Boolean YES and for the strings a build setting writes, `YES`, `true` and `1`, in any
    /// case; NO, a missing key and any other value are off.
    func test_theSwitch_isOnForYesTrueAnd1_only() {
        for value: Any in [true, "YES", "yes", "Yes", "true", "TRUE", "1", " YES "] {
            XCTAssertTrue(InfoPlistSwitch.isOn(value), "\(value)")
        }
        let off: [Any?] = [nil, false, "NO", "no", "false", "0", "", "on", "y", 1, 0, NSNumber(value: 1), ["YES"], ["on": true]]
        for value in off {
            XCTAssertFalse(InfoPlistSwitch.isOn(value), String(describing: value))
        }
    }

    /// The switch set to NO, or to a value that is no switch (a number, another word), keeps both lines masked.
    func test_theSwitchOff_orNotASwitch_keepsTheLinesMasked() {
        let customer = "shopper-42"
        for value: Any in [false, "NO", 1, "on"] {
            let h = Harness()
            h.bundle.setObject("SallaPushLogFullIdentifiers", value)
            h.registered()
            h.login(customer: customer)
            h.advance(2)
            let lines = messages(h, "status.launch") + messages(h, "status.changed")
            XCTAssertTrue(lines.contains { $0.contains("push token none → \(maskedToken);") }, "\(value)")
            XCTAssertTrue(lines.contains { $0.hasSuffix("→ id hidden (linked).") }, "\(value)")
            XCTAssertFalse(lines.contains { $0.contains(Harness.tokenHex()) || $0.contains(customer) }, "\(value)")
        }
    }

    /// The switch is honoured only in the sandbox APNs environment: a build in the production environment, such as a
    /// TestFlight or App Store build, keeps both lines masked with the switch on.
    func test_theSwitchOn_inTheProductionAPNsEnvironment_keepsTheLinesMasked() throws {
        let customer = "shopper-42"
        let h = Harness()
        h.simulatorProfile.set(false)
        h.bundle.setObject("SallaPushLogFullIdentifiers", true)
        h.registered()
        h.login(customer: customer)
        h.advance(2)
        let lines = messages(h, "status.launch") + messages(h, "status.changed")
        XCTAssertTrue(try XCTUnwrap(lines.first).contains("apns_env production"))
        XCTAssertTrue(lines.contains { $0.contains("push token none → \(maskedToken);") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("→ id hidden (linked).") })
        XCTAssertFalse(lines.contains { $0.contains(Harness.tokenHex()) || $0.contains(customer) })
    }
}
