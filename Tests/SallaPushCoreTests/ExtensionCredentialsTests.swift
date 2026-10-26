import Foundation
import Security
@testable import SallaPushCore
import XCTest

/// The Keychain item through which the app shares its device credentials with its Notification Service Extension: in
/// the App Group's access group, under a service of its own, readable after the first unlock on this device only, never
/// synced, deleted from every access group, and read back only when this SDK could have written it.
final class ExtensionCredentialsTests: XCTestCase {
    private let access = ScriptedKeychain()
    private let group = "group.salla.store42"
    private let deviceId = "6f1c2a4e-9b7d-4c3a-8e5f-1a2b3c4d5e6f"

    private func makeStore() throws -> ExtensionCredentialsStore {
        try XCTUnwrap(ExtensionCredentialsStore(appBundleIdentifier: "com.salla.store42", access: access))
    }

    private func credentials() throws -> ExtensionCredentials {
        let base = try XCTUnwrap(APIBase.validated(URL(string: "https://api.salla.dev/notifications/v1/sallapush")))
        return ExtensionCredentials(appId: "st_42_ios", base: base, deviceId: deviceId, secret: SecretString("c2VjcmV0LWE"))
    }

    /// The JSON of a valid item, with `changes` applied (`NSNull` removes a field).
    private func item(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "api_base_url": "https://api.salla.dev/notifications/v1/sallapush", "app_id": "st_42_ios",
            "device_id": deviceId, "device_secret": "c2VjcmV0LWE", "v": 1,
        ]
        for (key, value) in changes {
            object[key] = value is NSNull ? nil : value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func test_store_usesTheAppGroup_andAServiceOfItsOwn() throws {
        XCTAssertEqual(ExtensionCredentialsStore.account, "device_credentials")
        let store = try makeStore()
        access.addStatus = errSecDuplicateItem
        XCTAssertEqual(store.save(try credentials(), group: group), .success)
        XCTAssertEqual(store.read(group: group), .absent)
        let calls = access.recorded
        let added = try XCTUnwrap(calls.add.first)
        XCTAssertEqual(added[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(added[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        for query in [added, try XCTUnwrap(calls.update.first?.0), try XCTUnwrap(calls.copy.first)] {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.salla.store42.sallapush.extension")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "device_credentials")
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        }
        XCTAssertEqual(calls.update.first?.1[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// A delete names no access group, so it removes the item from every group the app belongs to,
    /// also one the app's configuration no longer names.
    func test_delete_namesNoAccessGroup() throws {
        let store = try makeStore()
        XCTAssertEqual(store.delete(), .success)
        access.deleteStatus = errSecItemNotFound
        XCTAssertEqual(store.delete(), .success, "an absent item counts as deleted")
        access.deleteStatus = errSecMissingEntitlement
        XCTAssertEqual(store.delete(), .failed(errSecMissingEntitlement))
        let query = try XCTUnwrap(access.recorded.delete.first)
        XCTAssertEqual(query as NSDictionary, [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.salla.store42.sallapush.extension",
            kSecAttrAccount as String: "device_credentials", kSecAttrSynchronizable as String: false,
        ] as NSDictionary)
        XCTAssertNil(query[kSecAttrAccessGroup as String])
    }

    func test_saveThenRead_roundTrips_andTheItemHoldsFiveFields() throws {
        let store = try makeStore()
        let shared = try credentials()
        XCTAssertEqual(store.save(shared, group: group), .success)
        let data = try XCTUnwrap(access.recorded.add.first?[kSecValueData as String] as? Data)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, [
            "api_base_url": "https://api.salla.dev/notifications/v1/sallapush", "app_id": "st_42_ios",
            "device_id": deviceId, "device_secret": "c2VjcmV0LWE", "v": 1,
        ] as NSDictionary)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\"api_base_url\":"), "sorted keys: \(text)")
        access.copyResult = (errSecSuccess, data)
        XCTAssertEqual(store.read(group: group), .found(shared))
    }

    func test_withoutABundleId_thereIsNoStore() {
        for bundle in [nil, "", "  "] as [String?] {
            XCTAssertNil(ExtensionCredentialsStore(appBundleIdentifier: bundle, access: access), String(describing: bundle))
        }
        XCTAssertTrue(access.recorded.add.isEmpty)
        XCTAssertTrue(access.recorded.delete.isEmpty)
    }

    func test_readStatuses() throws {
        let store = try makeStore()
        access.copyResult = (errSecItemNotFound, nil)
        XCTAssertEqual(store.read(group: group), .absent)
        access.copyResult = (errSecInteractionNotAllowed, nil)
        XCTAssertEqual(store.read(group: group), .locked)
        access.copyResult = (errSecMissingEntitlement, nil)
        XCTAssertEqual(store.read(group: group), .unavailable(errSecMissingEntitlement))
        XCTAssertEqual(access.recorded.copy.count, 3)
        XCTAssertEqual(store.read(group: ""), .absent, "no App Group, nothing to read")
        XCTAssertEqual(store.save(try credentials(), group: ""), .failed(errSecParam))
        XCTAssertEqual(access.recorded.copy.count, 3)
        XCTAssertTrue(access.recorded.add.isEmpty)
    }

    /// Anything this SDK could not have written reads as malformed, never as credentials: a deep or unreadable text
    /// never reaches the parser, and an insecure base, a bad id or secret, or another version is refused.
    func test_invalidContent_isMalformed() throws {
        let store = try makeStore()
        let deep = Data(("{\"v\":1,\"x\":" + String(repeating: "[", count: 40) + String(repeating: "]", count: 40) + "}").utf8)
        let invalid: [(String, Data)] = [
            ("an http base off localhost", try item(["api_base_url": "http://api.salla.dev/notifications/v1/sallapush"])),
            ("a base with credentials", try item(["api_base_url": "https://user:pass@api.salla.dev/sallapush"])),
            ("a bad device id", try item(["device_id": "not-a-uuid"])),
            ("a bad secret", try item(["device_secret": "not a secret!"])),
            ("a bad app id", try item(["app_id": "st 42"])),
            ("version 2", try item(["v": 2])),
            ("no version", try item(["v": NSNull()])),
            ("no secret", try item(["device_secret": NSNull()])),
            ("too deep", deep),
            ("not JSON", Data("garbage".utf8)),
        ]
        for (name, data) in invalid {
            access.copyResult = (errSecSuccess, data)
            XCTAssertEqual(store.read(group: group), .malformed, name)
        }
        access.copyResult = (errSecSuccess, try item(["api_base_url": "http://localhost:8080/sallapush"]))
        guard case let .found(local) = store.read(group: group) else { return XCTFail("http on localhost is valid") }
        XCTAssertEqual(local.base.string, "http://localhost:8080/sallapush")
    }

    func test_deviceId_isLowercased() throws {
        let store = try makeStore()
        access.copyResult = (errSecSuccess, try item(["device_id": deviceId.uppercased()]))
        guard case let .found(read) = store.read(group: group) else { return XCTFail("expected credentials") }
        XCTAssertEqual(read.deviceId, deviceId)
        XCTAssertEqual(read.appId, "st_42_ios")
        XCTAssertEqual(read.secret.revealed, "c2VjcmV0LWE")
        XCTAssertEqual(read.base.string, "https://api.salla.dev/notifications/v1/sallapush")
    }
}
