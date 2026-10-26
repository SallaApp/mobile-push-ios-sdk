import Foundation
import Security

/// The outcome of a Keychain read.
package enum KeychainReadResult: Equatable, Sendable {
    /// `errSecSuccess` with data.
    case found(Data)
    /// `errSecItemNotFound`: the only status that means "absent".
    case notFound
    /// `errSecInteractionNotAllowed`: protected data is unavailable (before first unlock). Not absent.
    case locked
    /// Any other status, including `errSecMissingEntitlement`. Not absent.
    case unavailable(OSStatus)
}

/// The outcome of a Keychain write or delete.
package enum KeychainWriteResult: Equatable, Sendable {
    case success
    case locked
    case failed(OSStatus)
}

/// The Security framework calls, injected so tests script every status and inspect every query.
package protocol KeychainAccess: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real Keychain.
package struct SystemKeychain: KeychainAccess {
    package init() {}

    package func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    package func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    package func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    package func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Generic-password items of service `<bundleId>.sallapush`, readable after the first unlock, never synced,
/// never migrated to another device, in the app's default access group. `init(service:accessGroup:access:)` makes a
/// store of another service, which may name an access group (the item the app shares with its extension).
package final class KeychainStore: Sendable {
    /// The account of the credentials of one (app id, API host).
    package static func credentialsAccount(appId: String, hostTag: String) -> String {
        "device_credentials.\(appId).\(hostTag)"
    }

    /// `<bundleId>.sallapush`, or `com.salla.push` without a bundle id.
    package let service: String
    /// The access group every query names. nil names none: an add then goes to the app's default access group (its app
    /// ID), and a read, an update or a delete matches the item in every access group the app belongs to.
    package let accessGroup: String?
    /// The Security framework calls, which another store of the same Keychain shares.
    package let access: KeychainAccess

    package init(bundleIdentifier: String?, access: KeychainAccess = SystemKeychain()) {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            service = bundleIdentifier + ".sallapush"
        } else {
            service = "com.salla.push"
        }
        accessGroup = nil
        self.access = access
    }

    /// Items of `service`, in `accessGroup` when it is set.
    package init(service: String, accessGroup: String?, access: KeychainAccess) {
        self.service = service
        self.accessGroup = accessGroup
        self.access = access
    }

    /// Reads one item.
    package func read(account: String) -> KeychainReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = access.copyMatching(query)
        switch status {
        case errSecSuccess:
            return data.map { .found($0) } ?? .unavailable(status)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .unavailable(status)
        }
    }

    /// Adds the item, or updates it when it already exists.
    package func write(account: String, data: Data) -> KeychainWriteResult {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = access.add(attributes)
        switch status {
        case errSecSuccess:
            return .success
        case errSecDuplicateItem:
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            return result(of: access.update(baseQuery(account: account), changes))
        default:
            return result(of: status)
        }
    }

    /// Deletes the item; an absent item counts as deleted.
    package func delete(account: String) -> KeychainWriteResult {
        let status = access.delete(baseQuery(account: account))
        return status == errSecItemNotFound ? .success : result(of: status)
    }

    /// The query that identifies one item.
    package func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func result(of status: OSStatus) -> KeychainWriteResult {
        switch status {
        case errSecSuccess: return .success
        case errSecInteractionNotAllowed: return .locked
        default: return .failed(status)
        }
    }
}
