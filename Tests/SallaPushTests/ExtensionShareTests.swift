import Foundation
import Security
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The device credentials the app shares with its Notification Service Extension, in the App Group's Keychain access
/// group: only the current main engine writes them, only while it runs registered with consent and has a usable App
/// Group, and they are deleted from every access group everywhere else.
final class ExtensionShareTests: XCTestCase {
    private static let group = "group.salla.test"
    private static let service = "com.salla.test.sallapush.extension"

    /// A harness whose App Groups are available, at a temporary folder removed after the test.
    private func harnessWithAnAppGroup() -> Harness {
        let h = Harness()
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-share-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        h.appGroupContainer.set(container)
        return h
    }

    /// The shared item's JSON, or nil when there is none.
    private func sharedItem(_ h: Harness) -> [String: Any]? {
        guard let data = h.keychainAccess.attributes(service: Self.service, account: "device_credentials")?[
            kSecValueData as String] as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The access group the shared item is in.
    private func sharedGroup(_ h: Harness) -> String? {
        h.keychainAccess.attributes(service: Self.service, account: "device_credentials")?[kSecAttrAccessGroup as String]
            as? String
    }

    /// An item an earlier launch shared: the credentials of another device, in the App Group.
    private func shareALeftover(_ h: Harness) throws {
        let store = try XCTUnwrap(ExtensionCredentialsStore(appBundleIdentifier: "com.salla.test", access: h.keychainAccess))
        let leftover = ExtensionCredentials(appId: "st_42_ios", base: .production, deviceId: UUID().uuidString.lowercased(),
                                            secret: SecretString("bGVmdG92ZXI"))
        XCTAssertEqual(store.save(leftover, group: Self.group), .success)
        XCTAssertNotNil(sharedItem(h))
    }

    /// The last delete was of the shared item, and named no access group, so it reached the item in any group.
    private func assertTheLastDelete_namedNoGroup(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        let query = try XCTUnwrap(h.keychainAccess.lastDeleteQuery, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, Self.service, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "device_credentials", file: file, line: line)
        XCTAssertNil(query[kSecAttrAccessGroup as String], file: file, line: line)
    }

    func test_registration_sharesTheCredentials_inTheAppGroup() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let deviceId = try XCTUnwrap(h.deviceId)
        let secret = try XCTUnwrap(h.server.device(deviceId)?.secret)
        let attributes = try XCTUnwrap(h.keychainAccess.attributes(service: Self.service, account: "device_credentials"))
        XCTAssertEqual(attributes[kSecAttrAccessGroup as String] as? String, Self.group)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(sharedItem(h) as NSDictionary?, [
            "api_base_url": "https://api.salla.dev/notifications/v1/sallapush", "app_id": "st_42_ios",
            "device_id": deviceId, "device_secret": secret, "v": 1,
        ] as NSDictionary)
        // The app's own item stays where it was, in the app's default access group.
        let own = h.keychainAccess.attributes(service: "com.salla.test.sallapush",
                                              account: KeychainStore.credentialsAccount(appId: "st_42_ios", hostTag: h.hostTag))
        XCTAssertNotNil(own)
        XCTAssertNil(own?[kSecAttrAccessGroup as String])
        // What the extension reads: these credentials in its App Group, none in another.
        let store = try XCTUnwrap(ExtensionCredentialsStore(appBundleIdentifier: "com.salla.test", access: h.keychainAccess))
        XCTAssertEqual(store.read(group: Self.group), .found(ExtensionCredentials(
            appId: "st_42_ios", base: .production, deviceId: deviceId, secret: SecretString(secret))))
        XCTAssertEqual(store.read(group: "group.other"), .absent)
    }

    func test_load_backFillsADeviceRegisteredBefore() throws {
        let h = harnessWithAnAppGroup()
        h.registered()
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertNil(sharedItem(h), "no App Group configured: nothing is shared")
        let next = h.relaunch()
        next.initialize { $0.appGroupIdentifier = Self.group }
        XCTAssertEqual(next.server.requests("register").count, 1, "the same device")
        XCTAssertEqual(sharedItem(next)?["device_id"] as? String, deviceId)
        XCTAssertEqual(sharedItem(next)?["device_secret"] as? String, next.server.device(deviceId)?.secret)
        XCTAssertEqual(sharedGroup(next), Self.group)
    }

    func test_noAppGroup_orAnUnavailableOne_writesNoItem_andDeletesALeftover() throws {
        for configured in [nil, "group.com.salla.typo"] as [String?] {
            let h = Harness()
            try shareALeftover(h)
            h.registered { $0.appGroupIdentifier = configured }
            XCTAssertNotNil(h.deviceId)
            XCTAssertNil(sharedItem(h), configured ?? "no App Group")
            try assertTheLastDelete_namedNoGroup(h)
        }
    }

    /// A later version of the app that drops the App Group from its configuration leaves no item
    /// behind.
    func test_appGroupDroppedFromTheConfiguration_deletesTheItemSharedBefore() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertEqual(sharedGroup(h), Self.group)
        let next = h.relaunch()
        next.initialize()
        XCTAssertEqual(next.deviceId, h.deviceId)
        XCTAssertNil(sharedItem(next))
        try assertTheLastDelete_namedNoGroup(next)
    }

    /// A withdrawal deletes the item from whatever App Group holds it, also one the configuration no
    /// longer names.
    func test_withdrawal_deletesTheItem_whateverTheConfiguredGroup() throws {
        let h = harnessWithAnAppGroup()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered { $0.appGroupIdentifier = "group.salla.a" }
        XCTAssertEqual(sharedGroup(h), "group.salla.a")
        let next = h.relaunch()
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.initialize { $0.appGroupIdentifier = "group.salla.b" }
        next.advance(30)
        XCTAssertTrue(next.logs.contains("consent.revoked"))
        XCTAssertNil(sharedItem(next))
        try assertTheLastDelete_namedNoGroup(next)
    }

    func test_consentPause_deletesIt_andConsentWritesItAgain() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertNotNil(sharedItem(h))
        h.runtime.setConsentRequired(true)
        h.advance(3)
        XCTAssertNil(sharedItem(h), "consent is required and not given")
        h.runtime.setConsentGiven(true)
        h.advance(3)
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, deviceId)
        XCTAssertEqual(h.server.requests("register").count, 1)
    }

    func test_consentWithdrawal_deletesIt_beforeItsRequests() throws {
        let h = harnessWithAnAppGroup()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertNotNil(sharedItem(h))
        let sharedAtTheOptOut = Locked<Bool?>(nil)
        h.server.script("update", times: 1) { [keychain = h.keychainAccess] _ in
            sharedAtTheOptOut.set(keychain.attributes(service: Self.service, account: "device_credentials") != nil)
            return .json(200, [:], [:])
        }
        h.runtime.setConsentGiven(false)
        h.advance(5)
        XCTAssertEqual(h.server.requests("update").map { $0.json["opted_in"] as? Bool }, [false])
        XCTAssertEqual(sharedAtTheOptOut.current, false, "deleted before the withdrawal's first request")
        XCTAssertTrue(h.logs.contains("consent.revoked"))
        XCTAssertNil(sharedItem(h))
    }

    /// A registration answered while consent is withdrawn keeps its credentials in memory only, so nothing
    /// is shared until consent is given again.
    func test_registrationAnsweredDuringAWithdrawal_isNotShared_untilConsentIsBack() throws {
        let h = harnessWithAnAppGroup()
        h.server.script("register", times: 1) { _ in .hold }
        h.runtime.setConsentRequired(true)
        h.initialize { $0.appGroupIdentifier = Self.group }
        h.runtime.setConsentGiven(true)
        h.sendToken()
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1)
        h.runtime.setConsentGiven(false)
        h.advance(3)
        h.server.releaseHeld()
        h.advance(5)
        XCTAssertEqual(h.server.templates, ["register", "update"], "the new row is opted out")
        XCTAssertNil(h.keychainAccess.attributes(service: Self.service, account: "device_credentials"))
        h.runtime.setConsentGiven(true)
        h.advance(5)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(h.server.requests("register").count, 1)
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, deviceId)
        XCTAssertEqual(sharedItem(h)?["device_secret"] as? String, h.server.device(deviceId)?.secret)
    }

    /// No engine runs while SallaPush waits for consent at launch: the runtime deletes an item an earlier launch shared.
    func test_waitingForConsentAtLaunch_deletesALeftoverItem() throws {
        let h = harnessWithAnAppGroup()
        try shareALeftover(h)
        h.runtime.setConsentRequired(true)
        h.initialize { $0.appGroupIdentifier = Self.group }
        XCTAssertNil(h.engine)
        XCTAssertTrue(h.logs.contains("consent.waiting"))
        XCTAssertNil(sharedItem(h))
        try assertTheLastDelete_namedNoGroup(h)
    }

    /// A withdrawal before `initialize` deletes the item at once, so the extension stops sending `received` also when
    /// the app initializes SallaPush late, or not in that launch. The rest of the withdrawal waits for `initialize`.
    func test_withdrawalBeforeInitialize_deletesTheItemAtOnce() throws {
        let h = harnessWithAnAppGroup()
        h.runtime.setConsentRequired(true)
        h.runtime.setConsentGiven(true)
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertNotNil(sharedItem(h))
        let next = h.relaunch()
        let sent = next.server.requests.count
        next.runtime.setConsentRequired(true)
        next.runtime.setConsentGiven(false)
        next.advance(3)
        XCTAssertNil(next.engine)
        XCTAssertNil(sharedItem(next), "deleted before initialize")
        try assertTheLastDelete_namedNoGroup(next)
        XCTAssertEqual(next.server.requests.count, sent, "nothing is sent before initialize")
        next.initialize { $0.appGroupIdentifier = Self.group }
        next.advance(30)
        XCTAssertTrue(next.logs.contains("consent.revoked"))
        XCTAssertNil(sharedItem(next))
    }

    /// `401 invalid_device_secret`: the refused credentials stop being shared at once, and the new device's are shared
    /// once it registered.
    func test_reregistration_replacesIt() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let first = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, first)
        h.server.script("update", times: 1) { _ in FakeServer.error(401, "invalid_device_secret") }
        h.server.script("register", times: 1) { _ in .hold }
        h.submit(.setLanguage("en"))
        h.advance(3)
        XCTAssertEqual(h.server.heldCount, 1, "the new registration is on the wire")
        XCTAssertNil(sharedItem(h))
        h.server.releaseHeld()
        h.advance(3)
        let second = try XCTUnwrap(h.deviceId)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, second)
        XCTAssertEqual(sharedItem(h)?["device_secret"] as? String, h.server.device(second)?.secret)
    }

    /// Malformed credentials are deleted with the app's item, before the load goes on (here it waits for protected
    /// data), and the device's next registration is shared.
    func test_malformedCredentials_deleteIt() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertNotNil(sharedItem(h))
        let account = KeychainStore.credentialsAccount(appId: "st_42_ios", hostTag: h.hostTag)
        XCTAssertEqual(KeychainStore(bundleIdentifier: "com.salla.test", access: h.keychainAccess)
            .write(account: account, data: Data("{".utf8)), .success)
        let next = h.relaunch()
        next.protectedFiles.set(["identity.json"])
        next.initialize { $0.appGroupIdentifier = Self.group }
        XCTAssertTrue(next.logs.all.contains { $0.message == "Stored SallaPush credentials were malformed; registering again." })
        XCTAssertNil(sharedItem(next))
        next.protectedFiles.set([])
        next.send(.protectedDataAvailable)
        next.advance(3)
        XCTAssertEqual(next.server.requests("register").count, 2)
        XCTAssertEqual(sharedItem(next)?["device_id"] as? String, try XCTUnwrap(next.deviceId))
    }

    func test_unregisteredDevice_deletesALeftoverItem() throws {
        let h = harnessWithAnAppGroup()
        try shareALeftover(h)
        h.initialize { $0.appGroupIdentifier = Self.group }
        XCTAssertNil(h.deviceId)
        XCTAssertNil(sharedItem(h))
        try assertTheLastDelete_namedNoGroup(h)
    }

    /// The engine an app id switch leaves draining never writes the item, even when its registration is answered after
    /// the new engine shared its own.
    func test_appIdSwitch_replacesIt_andTheDrainingEngineNeverWritesIt() throws {
        let h = harnessWithAnAppGroup()
        h.server.script("register", times: 1) { _ in .hold }
        h.initialize { $0.appGroupIdentifier = Self.group }
        h.sendToken()
        h.advance(2)
        XCTAssertEqual(h.server.heldCount, 1)
        h.initialize("st_43_ios") { $0.appGroupIdentifier = Self.group }
        h.sendToken()
        h.advance(2)
        let deviceId = try XCTUnwrap(h.deviceId)
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios")
        h.server.releaseHeld()
        h.advance(61)
        XCTAssertEqual(h.server.requests("register").map(\.path), ["/apps/st_42_ios/devices", "/apps/st_43_ios/devices"])
        XCTAssertTrue(h.runtime.drainingEngines.isEmpty)
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios")
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, deviceId)
    }

    /// The item is the current engine's alone. An engine the runtime doesn't run, as one it switched away from is until
    /// it learns that it drains, leaves it as it is.
    func test_anEngineTheRuntimeDoesNotRun_neverTouchesIt() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let current = try XCTUnwrap(h.engine)
        let shared = try XCTUnwrap(sharedItem(h)) as NSDictionary
        var config = current.config
        config.appId = "st_43_ios"
        let other = Engine(config: config, mode: .main, environment: current.env, host: h.runtime)
        // Unregistered, it would delete the item if it could.
        other.queue.sync { other.syncExtensionCredentials() }
        XCTAssertEqual(sharedItem(h) as NSDictionary?, shared)
        current.queue.sync { current.syncExtensionCredentials() }
        XCTAssertEqual(sharedItem(h) as NSDictionary?, shared)
    }

    /// A failed write (the registration, then the consent given after a pause) and a failed delete (the withdrawal,
    /// then the pause that ends it) each log one ERROR.
    func test_writeFailure_isLoggedOnce() throws {
        let h = harnessWithAnAppGroup()
        h.keychainAccess.forcedAddStatus = errSecMissingEntitlement
        h.registered { $0.appGroupIdentifier = Self.group }
        h.runtime.setConsentRequired(true)
        h.advance(3)
        h.runtime.setConsentGiven(true)
        h.advance(3)
        let shareFailures = { h.logs.all.filter { $0.code == "storage.failed" && $0.message.contains("Extension") } }
        XCTAssertEqual(shareFailures().map(\.message), [
            "Could not share the device credentials with the Notification Service Extension (Keychain status -34018); "
                + "'received' is sent by the app only.",
        ])
        h.keychainAccess.forcedAddStatus = nil
        h.keychainAccess.forcedDeleteStatus = errSecMissingEntitlement
        h.runtime.setConsentGiven(false)
        h.advance(30)
        XCTAssertTrue(h.logs.contains("consent.revoked"))
        XCTAssertEqual(shareFailures().map(\.message).last,
                       "Could not remove the device credentials shared with the Notification Service Extension (Keychain "
                           + "status -34018).")
        XCTAssertEqual(shareFailures().count, 2)
        XCTAssertTrue(shareFailures().allSatisfy { $0.level == .error })
    }
}

// MARK: - A switch while an engine changes the item

extension ExtensionShareTests {
    /// A configuration with the App Group.
    private func configuration() -> SallaPushConfiguration {
        let configuration = SallaPushConfiguration()
        configuration.appGroupIdentifier = Self.group
        return configuration
    }

    /// A launch running app st_42_ios registered, which shares its credentials, on a device an earlier launch
    /// registered with st_43_ios too. Returns that launch and its engine.
    private func runningAfterAnotherApp() throws -> (Harness, Engine) {
        let first = harnessWithAnAppGroup()
        first.registered("st_43_ios") { $0.appGroupIdentifier = Self.group }
        let h = first.relaunch()
        h.registered { $0.appGroupIdentifier = Self.group }
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_42_ios")
        return (h, try XCTUnwrap(h.engine))
    }

    /// The app switches to another app id while the old engine shares its credentials, past its own checks. The old
    /// engine leaves the item the new engine shared: whether it is still the current engine is checked in the step that
    /// changes the item.
    func test_anEngineSwitchedAwayFromWhileItShares_leavesTheNewEnginesItem() throws {
        let (h, old) = try runningAfterAnotherApp()
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        // The old engine pauses as it starts to change the item.
        h.bundle.onBundleIdentifierRead.set {
            paused.signal()
            resume.wait()
        }
        old.queue.async { old.syncExtensionCredentials() }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
        h.bundle.onBundleIdentifierRead.set(nil)
        let writing = DispatchSemaphore(value: 0)
        h.keychainAccess.beforeWrite.set { _, service in
            if service == Self.service { writing.signal() }
        }
        h.runtime.initialize(appId: "st_43_ios", configuration: configuration())
        XCTAssertEqual(writing.wait(timeout: .now() + 5), .success, "the new engine shares its own")
        h.keychainAccess.beforeWrite.set(nil)
        // It writes on its own queue: once that queue is past the write, the item is the new engine's.
        h.engine?.queue.sync {}
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios", "the new engine shared its own")
        resume.signal()
        h.settle()
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios")
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, try XCTUnwrap(h.deviceId))
    }

    /// Every change of the item waits for the one under way. The old engine pauses inside its Keychain write; the new
    /// engine's change, once the app switched, waits for that write, so it lands last.
    func test_theNewEnginesChange_waitsForTheOldEnginesWrite() throws {
        let (h, old) = try runningAfterAnotherApp()
        let writing = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let writes = Locked(0)
        h.keychainAccess.beforeWrite.set { _, service in
            guard service == Self.service else { return }
            let write = writes.withLock { count -> Int in
                count += 1
                return count
            }
            if write == 1 {
                writing.signal()
                resume.wait()
            }
        }
        old.queue.async { old.syncExtensionCredentials() }
        XCTAssertEqual(writing.wait(timeout: .now() + 5), .success)
        let waiting = DispatchSemaphore(value: 0)
        h.runtime.onExtensionCredentialsLockWait.set { waiting.signal() }
        h.runtime.initialize(appId: "st_43_ios", configuration: configuration())
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success, "the new engine's change waits for the lock")
        h.runtime.onExtensionCredentialsLockWait.set(nil)
        XCTAssertEqual(writes.current, 1, "nothing written while the old engine writes")
        resume.signal()
        h.settle()
        h.keychainAccess.beforeWrite.set(nil)
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios")
        XCTAssertEqual(sharedItem(h)?["device_id"] as? String, try XCTUnwrap(h.deviceId))
    }

    /// The check that the engine is the current one is made under the lock: a change that waited for the lock while the
    /// app switched to another app id doesn't run.
    func test_aChangeThatWaitsForTheLock_runsOnlyIfItsEngineIsStillCurrent() throws {
        let (h, old) = try runningAfterAnotherApp()
        let ran = Locked(false)
        let waiting = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        h.runtime.onExtensionCredentialsLockWait.set { waiting.signal() }
        h.runtime.extensionCredentialsLock.lock()
        DispatchQueue.global().async {
            _ = h.runtime.changeExtensionCredentials(by: old) { ran.set(true) }
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success, "the change waits for the lock")
        h.runtime.onExtensionCredentialsLockWait.set(nil)
        h.runtime.initialize(appId: "st_43_ios", configuration: configuration())
        // The switch runs on the control queue: once that queue is past it, another engine is the current one.
        h.runtime.controlQueue.sync {}
        XCTAssertTrue(h.runtime.currentEngine.map { $0 !== old } ?? false, "the app switched")
        h.runtime.extensionCredentialsLock.unlock()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        h.settle()
        XCTAssertFalse(ran.current, "its engine was switched away from while it waited")
        XCTAssertEqual(sharedItem(h)?["app_id"] as? String, "st_43_ios")
    }

    /// The runtime's delete, when the app switches to an app id that waits for consent, waits for the old engine's
    /// write under way, so no item is left while SallaPush waits for consent.
    func test_theRuntimesDelete_waitsForTheOldEnginesWrite() throws {
        let h = harnessWithAnAppGroup()
        h.registered { $0.appGroupIdentifier = Self.group }
        let old = try XCTUnwrap(h.engine)
        let writing = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let deletes = Locked(0)
        let paused = Locked(false)
        h.keychainAccess.beforeWrite.set { operation, service in
            guard service == Self.service else { return }
            if operation == "delete" {
                deletes.withLock { $0 += 1 }
            } else if !paused.exchange(true) {
                writing.signal()
                resume.wait()
            }
        }
        old.queue.async { old.syncExtensionCredentials() }
        XCTAssertEqual(writing.wait(timeout: .now() + 5), .success)
        let waiting = DispatchSemaphore(value: 0)
        h.runtime.onExtensionCredentialsLockWait.set { waiting.signal() }
        let waitsForConsent = configuration()
        waitsForConsent.requiresUserConsent = true
        h.runtime.initialize(appId: "st_43_ios", configuration: waitsForConsent)
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success, "the runtime's delete waits for the lock")
        h.runtime.onExtensionCredentialsLockWait.set(nil)
        XCTAssertEqual(deletes.current, 0, "nothing deleted while the old engine writes")
        resume.signal()
        h.settle()
        h.keychainAccess.beforeWrite.set(nil)
        XCTAssertNil(h.engine)
        XCTAssertTrue(h.logs.contains("consent.waiting"))
        XCTAssertNil(sharedItem(h))
    }
}
