import Foundation
import Security
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// Every code the iOS SDK emits is in the catalogue, at the catalogue's level, and every iOS
/// catalogue code is emitted by some test. The extension's `nse.*` codes are covered by `SallaPushExtensionTests`.
final class LogCatalogTests: XCTestCase {
    /// The lines of the shared log catalogue (scripts/log-catalogue.txt) for "both" and "ios", with their levels.
    static let catalogue: [String: SallaPushLogLevel] = [
        "init.started": .info, "init.invalid_app_id": .error, "init.app_id_changed": .warn, "init.drain_started": .info,
        "init.buffer_full": .warn, "init.no_delegate": .warn, "config.no_app_group": .info, "status.launch": .info,
        "status.changed": .info, "consent.waiting": .info, "consent.given": .info, "consent.revoked": .info,
        "api.invalid_argument": .warn, "api.callback_repeated": .debug, "token.received": .info,
        "token.unchanged": .debug, "token.invalid": .warn, "token.missing": .warn, "token.registration_failed": .warn,
        "register.ok": .info, "register.reregistering": .info, "register.dormant": .error,
        "update.sent": .debug, "heartbeat.sent": .debug, "permission.changed": .info, "subscription.opted_out": .info,
        "subscription.opted_in": .info, "login.queued": .debug, "login.ok": .info, "login.skipped_same": .debug,
        "login.switched": .info, "login.rejected": .warn, "logout.queued": .info, "logout.ok": .info,
        "logout.skipped": .debug, "identity.token_needed": .warn, "identity.client_error": .error,
        "tags.flushed": .debug, "tags.normalized": .debug, "tags.invalid_key": .warn, "tags.value_truncated": .warn,
        "tags.limit": .warn, "tags.rejected_key": .warn, "events.flushed": .debug, "events.dropped": .warn,
        "events.queue_full": .warn, "inbox.ingested": .debug, "inbox.invalid_file": .debug, "net.retry": .info,
        "net.retry_exhausted": .warn, "net.rate_limited": .warn, "net.client_error": .error,
        "net.redirect_refused": .error, "net.invalid_response": .warn, "net.routes_closed": .warn,
        "storage.keychain_locked": .warn, "storage.failed": .error, "storage.state_reset": .error,
        "notif.foreign": .verbose, "notif.parse_failed": .warn, "notif.unknown_version": .warn,
        "notif.off_main_thread": .warn, "notif.suppressed": .debug, "notif.display_failed": .warn,
        "notif.click_queued": .debug, "notif.click_delivered": .debug, "badge.cleared": .debug, "badge.set": .debug,
        "badge.zero_skipped": .debug, "lifecycle.background_expired": .warn,
        "log.dropped": .warn, "nse.attachment_failed": .warn, "nse.expired": .warn, "nse.replaced_request": .debug,
        "nse.received_sent": .debug, "nse.received_deferred": .info, "nse.badge_set": .debug, "nse.badge_skipped": .info,
    ]

    static let extensionOnly: Set<String> = [
        "nse.attachment_failed", "nse.expired", "nse.replaced_request", "nse.received_sent", "nse.received_deferred",
        "nse.badge_set", "nse.badge_skipped",
    ]

    func test_theCodeEnum_isExactlyTheCatalogue_withTheCatalogueLevels() {
        XCTAssertEqual(Set(LogCode.allCases.map(\.rawValue)), Set(Self.catalogue.keys))
        XCTAssertEqual(LogCode.allCases.count, Self.catalogue.count)
        for code in LogCode.allCases {
            XCTAssertEqual(code.level, Self.catalogue[code.rawValue], code.rawValue)
        }
    }

    func test_everyCatalogueCode_isEmitted_atItsCatalogueLevel_andNothingElse() throws {
        var entries: [SallaPushLogEntry] = []
        entries += lifecycleAndConsentEntries()
        entries += tokenAndRegistrationEntries()
        entries += identityEntries()
        entries += logoutEntries()
        entries += try tagsAndEventsEntries()
        entries += try networkAndStorageEntries()
        entries += notificationEntries()
        entries += badgeEntries()
        entries += handlerOverflowEntries()
        let emitted = Set(entries.map(\.code))
        XCTAssertTrue(emitted.isSubset(of: Set(Self.catalogue.keys)),
                      "outside the catalogue: \(emitted.subtracting(Self.catalogue.keys))")
        let missing = Set(Self.catalogue.keys).subtracting(Self.extensionOnly).subtracting(emitted)
        XCTAssertTrue(missing.isEmpty, "never emitted by a test: \(missing.sorted())")
        let offLevel = entries.filter { Self.catalogue[$0.code] != $0.level }.map { "\($0.code) at \($0.level.name)" }
        XCTAssertTrue(offLevel.isEmpty, "emitted at a level other than the catalogue's: \(Set(offLevel).sorted())")
    }

    // MARK: - Scenarios

    private let compat: [AnyHashable: Any] = ["aps": ["alert": "x"], "custom": ["i": "i", "a": ["push_ref": "msg_ab"]]]

    private func entries(_ harnesses: Harness...) -> [SallaPushLogEntry] {
        harnesses.flatMap(\.logs.all)
    }

    /// Lifecycle, configuration, the pre-init buffer, the delegate check and consent.
    private func lifecycleAndConsentEntries() -> [SallaPushLogEntry] {
        let lifecycle = Harness()
        lifecycle.center.hasDelegateValue = false
        for index in 0..<120 { lifecycle.runtime.addTags(["k\(index)": "v"]) }
        lifecycle.runtime.addTags(["": "x"])
        lifecycle.initialize()
        lifecycle.send(.didBecomeActive)
        lifecycle.advance(31)
        lifecycle.initialize("st_43_ios")

        // An invalid first app id disables SallaPush for the process, so it gets a harness of its own.
        let invalid = Harness()
        invalid.initialize("Bad Id")

        let consent = Harness()
        consent.runtime.setConsentRequired(true)
        consent.registered()
        consent.runtime.setConsentGiven(true)
        consent.advance(3)
        consent.runtime.setConsentGiven(false)
        consent.advance(3)
        return entries(lifecycle, invalid, consent)
    }

    /// Tokens, permission, opt-in/out, every registration answer, and the status lines they change.
    private func tokenAndRegistrationEntries() -> [SallaPushLogEntry] {
        let tokens = Harness()
        tokens.installAsShared()
        tokens.registered()
        tokens.sendToken()
        SallaPush.Notifications.didRegisterForRemoteNotifications(deviceToken: Data())
        SallaPush.Notifications.didFailToRegisterForRemoteNotifications(error: NSError(domain: "APNs", code: 1))
        tokens.center.status = .denied
        tokens.send(.didBecomeActive)
        tokens.submit(.optOut)
        tokens.submit(.optIn)
        tokens.advance(86_401)
        tokens.send(.willEnterForeground)
        tokens.advance(3)
        var result = entries(tokens)

        for (status, code) in [(404, "unknown_app")] {
            let h = Harness()
            h.server.script("register") { _ in FakeServer.error(status, code) }
            h.registered()
            result += entries(h)
        }
        let refused = Harness()
        refused.registered()
        refused.server.mutate(refused.deviceId) { $0.secret = "refused" }
        refused.sendToken(3)
        refused.advance(3)
        return result + entries(refused)
    }

    /// Login and logout, the link answers, the identity token kept in memory only, and a system callback called twice.
    private func identityEntries() -> [SallaPushLogEntry] {
        let identity = Harness()
        identity.initialize()
        identity.login(customer: "cust_a")
        identity.sendToken()
        identity.advance(3)
        identity.login(customer: "cust_a")
        identity.submit(.addTags(["a": "1"]))
        identity.advance(12)
        identity.login(customer: "cust_b")
        identity.login(customer: "cust_b")
        identity.advance(3)
        identity.logout()
        identity.logout()
        identity.advance(3)
        identity.logout()

        let failures = Harness()
        failures.registered()
        failures.login(externalId: "cust_c", token: "eyJ.expired")
        failures.advance(3)
        failures.server.script("link") { _ in FakeServer.error(400, "invalid_request") }
        failures.login(customer: "cust_d")
        failures.advance(3)

        let withoutToken = Harness()
        withoutToken.registered()
        withoutToken.server.script("link", times: nil) { _ in .failure(.network("offline")) }
        withoutToken.login(customer: "cust_e")
        withoutToken.advance(3)
        let relaunched = withoutToken.relaunch()
        relaunched.server.clearScripts()
        relaunched.initialize()
        relaunched.advance(3)

        let repeated = LogCapture()
        let backend = NotificationCenterClientTests.TwiceCalling()
        let client = SystemNotificationCenterClient(logger: repeated.logger, backend: { backend })
        client.authorizationStatus { _ in }
        backend.queue.sync {}
        return entries(identity, failures, relaunched) + repeated.all
    }

    /// A reinstall's launch logout, a logout queued before registration, drain-only engines and identity client errors.
    private func logoutEntries() -> [SallaPushLogEntry] {
        let reinstall = Harness()
        reinstall.registered()
        reinstall.login(customer: "cust_a")
        reinstall.advance(3)
        try? FileManager.default.removeItem(at: reinstall.root)
        let reinstalled = reinstall.relaunch()
        reinstalled.initialize()
        reinstalled.logout()
        reinstalled.sendToken()
        reinstalled.advance(15)

        let queued = Harness()
        queued.initialize()
        queued.logout()

        let drain = Harness()
        drain.registered()
        drain.login(customer: "cust_a")
        drain.advance(3)
        drain.server.script("unlink", times: nil) { _ in .failure(.network("offline")) }
        drain.logout()
        drain.advance(3)
        let drainNext = drain.relaunch()
        drainNext.server.clearScripts()
        drainNext.initialize("st_43_ios")
        drainNext.advance(3)

        let clientError = Harness()
        clientError.registered()
        clientError.login(customer: "cust_a")
        clientError.advance(3)
        clientError.server.script("unlink") { _ in FakeServer.error(400, "invalid_request") }
        clientError.logout()
        clientError.advance(3)
        return entries(reinstalled, queued, drainNext, clientError)
    }

    /// Tag validation and rejection, events and the App Group inbox.
    private func tagsAndEventsEntries() throws -> [SallaPushLogEntry] {
        let tags = Harness()
        tags.registered()
        var many: [String: String] = ["UPPER": "1", "bad key": "1", "long": String(repeating: "x", count: 300)]
        for index in 0..<110 { many["t\(index)"] = "v" }
        tags.submit(.addTags(many))
        tags.server.script("tags", times: nil) { request in
            let add = request.json["add"] as? [String: String] ?? [:]
            if add["t5"] != nil { return FakeServer.error(400, "invalid_request") }
            return .json(200, ["tags": add], [:])
        }
        tags.advance(12)
        tags.advance(200)

        let events = Harness()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        events.appGroupContainer.set(container)
        let inbox = Inbox(folder: Inbox.folder(inContainer: container))
        _ = inbox.writeReceived(messageId: "msg_aa", at: events.clock.now())
        try FileManager.default.createDirectory(at: inbox.folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inbox.folder.appendingPathComponent("1-x.json"))
        events.initialize { $0.appGroupIdentifier = "group.test" }
        let weekAgo = events.clock.now() - 7 * 86_400
        events.submit(.events((0..<505).map { index in
            EventRecord(messageId: "msg_\(String(index + 1, radix: 16))", type: .received, at: weekAgo, actionId: nil)
        }))
        events.submit(.events([EventRecord(messageId: "msg_bb", type: .opened, at: events.clock.now(), actionId: nil)]))
        events.sendToken()
        events.advance(8)

        // A configured App Group the app cannot use: ERROR storage.failed.
        let unavailableGroup = Harness()
        unavailableGroup.appGroupContainer.set(nil)
        unavailableGroup.initialize { $0.appGroupIdentifier = "group.com.salla.typo" }
        return entries(tags, events, unavailableGroup)
    }

    /// Retries, rate limits, redirects, invalid answers, closed routes and storage failures.
    private func networkAndStorageEntries() throws -> [SallaPushLogEntry] {
        let network = Harness()
        network.registered()
        network.server.script("update", times: 1) { _ in FakeServer.error(429, "rate_limited", headers: ["retry-after": "5"]) }
        network.server.script("update", times: 1) { _ in .raw(302, Data(), [:]) }
        network.server.script("update", times: 1) { _ in .raw(200, Data("<html>".utf8), [:]) }
        network.server.script("update", times: nil) { _ in FakeServer.error(503, "server_error") }
        network.submit(.setLanguage("en"))
        network.advance(400)
        network.server.clearScripts()
        network.server.script("update") { _ in FakeServer.error(400, "invalid_request") }
        network.send(.willEnterForeground)
        network.advance(3)
        network.server.script("update") { _ in FakeServer.error(404, "not_found") }
        network.advance(86_401)
        network.send(.willEnterForeground)
        network.advance(3)

        let locked = Harness()
        locked.keychainAccess.forcedReadStatus = errSecInteractionNotAllowed
        locked.initialize()
        let unavailable = Harness()
        unavailable.keychainAccess.forcedReadStatus = errSecMissingEntitlement
        unavailable.initialize()
        let corrupt = Harness()
        corrupt.registered()
        let statePath = corrupt.root.appendingPathComponent("st_42_ios/\(corrupt.hostTag)/state.json")
        try Data("{".utf8).write(to: statePath)
        let corruptNext = corrupt.relaunch()
        corruptNext.initialize()
        return entries(network, locked, unavailable, corruptNext)
    }

    /// Foreign and native payloads, display, clicks, threading and background expiry.
    private func notificationEntries() -> [SallaPushLogEntry] {
        let notifications = Harness()
        let router = notifications.runtime.router
        let preventing = ForegroundTests.Listener(prevent: true)
        router.addForegroundListener(preventing)
        notifications.center.addError = "denied"
        _ = router.willPresent(userInfo: ["moengage": [:]])
        _ = router.willPresent(userInfo: ["sp_v": "9", "sp_id": "msg_XYZ", "aps": ["alert": "x"]])
        _ = router.willPresent(userInfo: compat)
        if let event = preventing.lastEvent { router.display(event.notification) }
        _ = router.didReceive(identifier: "r", actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: compat)
        router.addClickListener(preventing)
        let offMain = expectation(description: "off main")
        let payload = compat
        DispatchQueue.global().async {
            _ = router.willPresent(userInfo: payload)
            offMain.fulfill()
        }
        wait(for: [offMain], timeout: 10)
        notifications.settle()

        let optedOut = Harness()
        optedOut.registered()
        optedOut.submit(.optOut)
        _ = optedOut.runtime.router.willPresent(userInfo: compat)

        let background = Harness()
        background.registered()
        background.server.script("update") { _ in .hold }
        background.submit(.setLanguage("en"))
        background.send(.didEnterBackground)
        if let task = background.application.begunTasks.last { background.application.expire(task) }
        background.settle()
        return entries(notifications, optedOut, background)
    }

    /// The app badge: the clear as the app becomes active, a count set from Notification Center, and iOS 15's 0 held
    /// back while another SDK's notification is delivered.
    private func badgeEntries() -> [SallaPushLogEntry] {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-badge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let cleared = Harness()
        cleared.initialize()

        let counted = Harness()
        counted.appGroupContainer.set(container)
        counted.center.supportsBadgeCount = false
        counted.center.deliver([DeliveredNotification(identifier: "moengage", userInfo: ["moengage": ["cid": "1"]])])
        counted.initialize { configuration in
            configuration.appGroupIdentifier = "group.com.salla.test"
            configuration.autoClearBadge = false
        }
        counted.center.deliver([DeliveredNotification(identifier: "a", userInfo: ["sp_v": "1", "sp_id": "msg_ab"])])
        counted.send(.didBecomeActive)
        return entries(cleared, counted)
    }

    /// The handler queue overflows and reports `log.dropped` to the handler.
    private func handlerOverflowEntries() -> [SallaPushLogEntry] {
        let queue = DispatchQueue(label: "catalog.handler")
        let logger = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, _ in }, handlerQueue: queue)
        let handled = Locked<[SallaPushLogEntry]>([])
        let block = DispatchSemaphore(value: 0)
        logger.setHandler(level: .verbose) { entry in
            if entry.message == "first" { block.wait() }
            handled.withLock { $0.append(entry) }
        }
        logger.log(.registerOk, "first")
        // Wait until the handler is blocked inside "first", so the next entries pile up behind it.
        while true {
            let probe = DispatchSemaphore(value: 0)
            queue.async { probe.signal() }
            if probe.wait(timeout: .now() + .milliseconds(5)) == .timedOut { break }
        }
        for _ in 0..<(SDKLogger.handlerCapacity + 5) { logger.log(.registerOk, "more") }
        block.signal()
        queue.sync {}
        return handled.current
    }
}
