import Foundation
import Security
@testable import SallaPushCore
import XCTest

/// A scripted Keychain that records every query.
final class ScriptedKeychain: KeychainAccess, @unchecked Sendable {
    struct Calls {
        var copy: [[String: Any]] = []
        var add: [[String: Any]] = []
        var update: [([String: Any], [String: Any])] = []
        var delete: [[String: Any]] = []
    }

    private let lock = NSLock()
    private var calls = Calls()
    var copyResult: (OSStatus, Data?) = (errSecItemNotFound, nil)
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    var recorded: Calls {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        calls.copy.append(query)
        return copyResult
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        calls.add.append(attributes)
        return addStatus
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        calls.update.append((query, attributes))
        return updateStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        calls.delete.append(query)
        return deleteStatus
    }
}

final class KeychainStoreTests: XCTestCase {
    private let access = ScriptedKeychain()
    private lazy var store = KeychainStore(bundleIdentifier: "com.salla.store42", access: access)

    func test_service_isBundleScoped_andFallsBack() {
        XCTAssertEqual(store.service, "com.salla.store42.sallapush")
        XCTAssertEqual(KeychainStore(bundleIdentifier: nil, access: access).service, "com.salla.push")
        XCTAssertEqual(KeychainStore(bundleIdentifier: "", access: access).service, "com.salla.push")
    }

    func test_credentialsAccount_includesTheHostTag() {
        let base = try? XCTUnwrap(APIBase.validated(URL(string: "https://push.salla.dev")))
        let tag = base?.hostTag ?? ""
        XCTAssertEqual(KeychainStore.credentialsAccount(appId: "st_42_ios", hostTag: tag), "device_credentials.st_42_ios.\(tag)")
        XCTAssertEqual(tag.count, 8)
    }

    func test_found_returnsData() {
        access.copyResult = (errSecSuccess, Data("value".utf8))
        XCTAssertEqual(store.read(account: "a"), .found(Data("value".utf8)))
        let query = access.recorded.copy.first ?? [:]
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.salla.store42.sallapush")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "a")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertNil(query[kSecAttrAccessGroup as String])
    }

    func test_itemNotFound_isTheOnlyAbsent() {
        access.copyResult = (errSecItemNotFound, nil)
        XCTAssertEqual(store.read(account: "a"), .notFound)
    }

    func test_interactionNotAllowed_isUnavailable_notAbsent() {
        access.copyResult = (errSecInteractionNotAllowed, nil)
        XCTAssertEqual(store.read(account: "a"), .locked)
    }

    func test_missingEntitlement_isUnavailable() {
        access.copyResult = (errSecMissingEntitlement, nil)
        XCTAssertEqual(store.read(account: "a"), .unavailable(errSecMissingEntitlement))
        access.copyResult = (errSecSuccess, nil)
        XCTAssertEqual(store.read(account: "a"), .unavailable(errSecSuccess))
    }

    func test_attributes_thisDeviceOnly_noSync() {
        XCTAssertEqual(store.write(account: "a", data: Data("v".utf8)), .success)
        let attributes = access.recorded.add.first ?? [:]
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("v".utf8))
        XCTAssertNil(attributes[kSecAttrAccessGroup as String])
    }

    func test_duplicateOnAdd_updates() {
        access.addStatus = errSecDuplicateItem
        XCTAssertEqual(store.write(account: "a", data: Data("v".utf8)), .success)
        let update = access.recorded.update.first
        XCTAssertEqual(update?.1[kSecValueData as String] as? Data, Data("v".utf8))
        XCTAssertEqual(update?.0[kSecAttrAccount as String] as? String, "a")
    }

    func test_writeStatuses() {
        access.addStatus = errSecInteractionNotAllowed
        XCTAssertEqual(store.write(account: "a", data: Data()), .locked)
        access.addStatus = errSecMissingEntitlement
        XCTAssertEqual(store.write(account: "a", data: Data()), .failed(errSecMissingEntitlement))
        access.addStatus = errSecDuplicateItem
        access.updateStatus = errSecInteractionNotAllowed
        XCTAssertEqual(store.write(account: "a", data: Data()), .locked)
    }

    func test_delete_absentCountsAsDeleted() {
        access.deleteStatus = errSecItemNotFound
        XCTAssertEqual(store.delete(account: "a"), .success)
        access.deleteStatus = errSecMissingEntitlement
        XCTAssertEqual(store.delete(account: "a"), .failed(errSecMissingEntitlement))
    }

    /// The app's own items: every query is exactly what it was before stores of an access group existed, so the items
    /// stay in the app's default access group.
    func test_defaultStore_namesNoAccessGroup() {
        XCTAssertNil(store.accessGroup)
        access.copyResult = (errSecSuccess, Data("v".utf8))
        _ = store.read(account: "a")
        access.addStatus = errSecDuplicateItem
        _ = store.write(account: "a", data: Data("v".utf8))
        _ = store.delete(account: "a")
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.salla.store42.sallapush",
            kSecAttrAccount as String: "a", kSecAttrSynchronizable as String: false,
        ]
        var read = item
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var added = item
        added[kSecValueData as String] = Data("v".utf8)
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let calls = access.recorded
        XCTAssertEqual(calls.copy.map { $0 as NSDictionary }, [read as NSDictionary])
        XCTAssertEqual(calls.add.map { $0 as NSDictionary }, [added as NSDictionary])
        XCTAssertEqual(calls.update.map { $0.0 as NSDictionary }, [item as NSDictionary])
        XCTAssertEqual(calls.delete.map { $0 as NSDictionary }, [item as NSDictionary])
    }

    func test_groupStore_namesItsGroup_inReadsWritesAndUpdates() {
        let shared = KeychainStore(service: "com.salla.store42.sallapush.extension", accessGroup: "group.salla.store42",
                                   access: access)
        XCTAssertEqual(shared.service, "com.salla.store42.sallapush.extension")
        access.copyResult = (errSecSuccess, Data("v".utf8))
        XCTAssertEqual(shared.read(account: "a"), .found(Data("v".utf8)))
        access.addStatus = errSecDuplicateItem
        XCTAssertEqual(shared.write(account: "a", data: Data("v".utf8)), .success)
        XCTAssertEqual(shared.delete(account: "a"), .success)
        let calls = access.recorded
        let queries = calls.copy + calls.add + calls.update.map(\.0) + calls.delete
        XCTAssertEqual(queries.count, 4)
        for query in queries {
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "group.salla.store42")
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.salla.store42.sallapush.extension")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "a")
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        }
        XCTAssertEqual(calls.add.first?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(calls.update.first?.1[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
