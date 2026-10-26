import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

final class RedactionTests: XCTestCase {
    private let customerToken = "eyJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE3OTAwMDAwMDB9.SECRET-signature_value"

    private func fileText(_ h: Harness, _ name: String) -> String {
        let url = h.root.appendingPathComponent("st_42_ios/\(h.hostTag)/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A full scripted session with successes and failures; returns the secrets it used.
    private func session(_ h: Harness) throws -> [String] {
        h.server.customers = { token in token.hasPrefix("eyJ") ? .linked("cust_route_key_98765") : .rejected }
        h.registered()
        h.login(customerToken)
        h.submit(.addTags(["Cart": "1"]))
        _ = h.runtime.router.didReceive(identifier: "r1", actionIdentifier: UNNotificationDefaultActionIdentifier,
                                        userInfo: ["sp_v": "1", "sp_id": "msg_ab", "aps": ["alert": "x"]])
        h.server.script("update") { _ in
            FakeServer.error(400, "invalid_request")
        }
        h.submit(.setLanguage("en"))
        h.server.script("tags") { _ in .failure(.network("offline")) }
        h.advance(30)
        h.server.mutate(h.deviceId) { $0.secret = "s0refused0secret" }
        h.submit(.setLanguage("fr"))
        h.advance(30)
        h.logout()
        h.advance(5)
        return [customerToken, Harness.tokenHex()] + h.server.allDevices.map(\.secret)
    }

    func test_secrets_neverInLogsHandlerEntriesOrFiles() throws {
        let h = Harness()
        let handled = Locked<[SallaPushLogEntry]>([])
        h.logs.logger.setHandler(level: .verbose) { entry in handled.withLock { $0.append(entry) } }
        let secrets = try session(h)
        XCTAssertGreaterThan(h.logs.all.count, 10)
        let entries = h.logs.all + handled.current
        for entry in entries {
            let text = entry.message + " " + entry.metadata.values.joined(separator: " ")
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(entry.code) leaks a secret or the full push token")
            }
        }
        // Every entry shows at most the push token's last 6 characters, the info status lines included.
        let maskedToken = "…" + String(Harness.tokenHex().suffix(6))
        XCTAssertTrue(entries.contains { $0.code == "status.changed" && $0.message.contains(maskedToken) })
        let identity = fileText(h, "identity.json")
        let events = fileText(h, "events.json")
        let state = fileText(h, "state.json")
        XCTAssertFalse(identity.isEmpty)
        for secret in secrets {
            XCTAssertFalse(identity.contains(secret))
            XCTAssertFalse(events.contains(secret))
        }
        // state.json holds this app's own push token by its schema, never a secret.
        for secret in secrets where secret != Harness.tokenHex() {
            XCTAssertFalse(state.contains(secret))
        }
    }

    func test_noCustomerIdDerivativeLogged() throws {
        let h = Harness()
        _ = try session(h)
        let routeKey = "cust_route_key_98765"
        let hashed = Fingerprint.sha256Hex(Data(routeKey.utf8))
        for entry in h.logs.all {
            let text = entry.message + " " + entry.metadata.values.joined(separator: " ")
            // No entry names the customer, the info status lines included.
            XCTAssertFalse(text.contains(routeKey), entry.code)
            XCTAssertFalse(text.contains(String(hashed.prefix(6))), entry.code)
            XCTAssertFalse(text.contains(String(Fingerprint.sha256Hex(Data(customerToken.utf8)).prefix(16))), entry.code)
        }
        XCTAssertTrue(h.logs.all.contains { $0.code == "status.changed" && $0.message.contains("id hidden (linked)") })
        XCTAssertEqual(h.logs.all.first { $0.code == "login.ok" }?.message, "Customer linked.")
    }

    func test_serverText_isSanitisedAndCapped() {
        let h = Harness()
        h.registered()
        let message = "Bad\nthing\u{0}" + String(repeating: "x", count: 400)
        h.server.script("update") { _ in .json(400, ["error": ["code": "invalid_request", "message": message]], [:]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        let entry = h.logs.all.first { $0.code == "net.client_error" }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.message.contains("\n") ?? true)
        XCTAssertFalse(entry?.message.contains("\u{0}") ?? true)
        XCTAssertLessThan(entry?.message.count ?? 1_000, 400)
    }

    /// A server (or a proxy, or a wrong `apiBaseURL`) that echoes the device secret and
    /// the customer token in a 400 and in a 503 message never gets them into an entry, a console line or the handler.
    /// The 400's text is shown masked; a retryable 503 shows no server text at all.
    func test_serverEchoOfTheSecrets_neverReachesAnEntryAConsoleLineOrTheHandler() throws {
        let h = Harness()
        h.logs.logger.setRuntimeLevel(.verbose)
        let handled = Locked<[SallaPushLogEntry]>([])
        h.logs.logger.setHandler(level: .verbose) { entry in handled.withLock { $0.append(entry) } }
        h.registered()
        let secret = try XCTUnwrap(h.server.device(h.deviceId)?.secret)
        let echo = "echo Authorization: Device \(secret) token \(customerToken)"
        h.server.script("link", times: 1) { _ in .json(400, ["error": ["code": "invalid_request", "message": echo]], [:]) }
        h.login(customerToken)
        h.advance(2)
        h.server.script("update", times: 1) { _ in .json(503, ["error": ["code": "server_error", "message": echo]], [:]) }
        h.submit(.setLanguage("en"))
        h.advance(2)
        h.logs.handlerQueue.sync {}
        let clientError = try XCTUnwrap(h.logs.all.first { $0.code == "identity.client_error" })
        XCTAssertTrue(clientError.message.contains("echo Authorization: Device <redacted> token <redacted>"),
                      clientError.message)
        let retry = try XCTUnwrap(h.logs.all.first { $0.code == "net.retry" })
        XCTAssertFalse(retry.message.contains("echo"), retry.message)
        XCTAssertFalse(h.logs.console.isEmpty)
        XCTAssertFalse(handled.current.isEmpty)
        let texts = h.logs.all.map { $0.message + " " + $0.metadata.values.joined(separator: " ") }
            + handled.current.map { $0.message + " " + $0.metadata.values.joined(separator: " ") } + h.logs.console
        for text in texts {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains(customerToken), text)
            XCTAssertFalse(text.contains("SECRET-signature_value"), text)
            XCTAssertFalse(text.contains("eyJpYXQiOjE3OTAwMDAwMDB9"), text)
        }
    }

    func test_customerToken_neverInLogsOrFiles() throws {
        let h = Harness()
        h.server.customers = { _ in .rejected }
        h.registered()
        h.login(customerToken)
        h.advance(5)
        for entry in h.logs.all {
            XCTAssertFalse(entry.message.contains(customerToken))
        }
        XCTAssertFalse(fileText(h, "identity.json").contains(customerToken))
        XCTAssertFalse(fileText(h, "identity.json").contains("SECRET"))
    }

    /// The privacy manifest declares what SallaPush sends: the device id, the customer link and
    /// the notification events (product interaction, used for delivery analytics), none of it for tracking, and no
    /// required-reason API.
    func test_privacyManifest_declaresTheCollectedData() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/SallaPush/PrivacyInfo.xcprivacy").standardizedFileURL
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0)
        let types = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        let purposes = Dictionary(uniqueKeysWithValues: types.map { entry in
            (entry["NSPrivacyCollectedDataType"] as? String ?? "", entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [])
        })
        XCTAssertEqual(purposes, [
            "NSPrivacyCollectedDataTypeDeviceID": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
            "NSPrivacyCollectedDataTypeUserID": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
            "NSPrivacyCollectedDataTypeProductInteraction": ["NSPrivacyCollectedDataTypePurposeAnalytics",
                                                             "NSPrivacyCollectedDataTypePurposeAppFunctionality"],
        ])
        for entry in types {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
    }
}
