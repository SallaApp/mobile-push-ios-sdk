import Foundation
import Security

/// The device credentials the app shares with its Notification Service Extension, so the extension can send `received`
/// itself: the app id and the API base the device registered with, its id and its secret.
package struct ExtensionCredentials: Sendable, Equatable {
    package let appId: String
    package let base: APIBase
    /// Lowercase.
    package let deviceId: String
    package let secret: SecretString

    package init(appId: String, base: APIBase, deviceId: String, secret: SecretString) {
        self.appId = appId
        self.base = base
        self.deviceId = deviceId
        self.secret = secret
    }
}

/// What a read of the item the app shares with its extension found.
package enum ExtensionCredentialsRead: Sendable, Equatable {
    case found(ExtensionCredentials)
    /// `errSecItemNotFound`: none is shared, also when this process doesn't belong to the App Group read.
    case absent
    /// `errSecInteractionNotAllowed`: unavailable until the first unlock.
    case locked
    /// Any other status.
    case unavailable(OSStatus)
    /// An item this SDK could not have written.
    case malformed
}

/// The Keychain item through which the app shares its device credentials with its Notification Service Extension: one
/// generic password in the App Group's access group (Apple: "You can use app group names as keychain access group
/// names, without adding them to the Keychain access groups entitlement"), of service
/// `<app bundle id>.sallapush.extension` and account `device_credentials`, readable after the first unlock, this device
/// only, never synced. The app writes it only while SallaPush runs with consent and deletes it everywhere else; the
/// extension only reads it.
package struct ExtensionCredentialsStore: Sendable {
    /// One item per app, the current main engine's: the extension knows neither the app id nor the API host.
    package static let account = "device_credentials"

    /// `<app bundle id>.sallapush.extension`: apart from the app's own items (`<bundle id>.sallapush`), whose queries
    /// name no access group and so match every group, and from another app's item in the same App Group.
    private let service: String
    private let access: KeychainAccess

    /// nil without a bundle id: the item is never stored under a name another app could share.
    package init?(appBundleIdentifier: String?, access: KeychainAccess) {
        guard let bundle = appBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundle.isEmpty
        else { return nil }
        service = bundle + ".sallapush.extension"
        self.access = access
    }

    /// The item in `group`, the extension's App Group. A group this process doesn't belong to reads as absent.
    package func read(group: String) -> ExtensionCredentialsRead {
        guard !group.isEmpty else { return .absent }
        switch keychain(group).read(account: Self.account) {
        case let .found(data): return Self.decode(data).map { .found($0) } ?? .malformed
        case .notFound: return .absent
        case .locked: return .locked
        case let .unavailable(status): return .unavailable(status)
        }
    }

    /// Adds or updates the item in `group`. An App Group is never the app's default access group, so it is named.
    package func save(_ credentials: ExtensionCredentials, group: String) -> KeychainWriteResult {
        guard !group.isEmpty else { return .failed(errSecParam) }
        let item = Item(appId: credentials.appId, apiBaseURL: credentials.base.string, deviceId: credentials.deviceId,
                        deviceSecret: credentials.secret.revealed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(item) else { return .failed(errSecParam) }
        return keychain(group).write(account: Self.account, data: data)
    }

    /// Deletes the item from every access group this app belongs to: the query names none, and Apple says that such a
    /// query "matches any of your app's groups" and that `SecItemDelete` "deletes all items matching the specified
    /// query". An absent item counts as deleted.
    package func delete() -> KeychainWriteResult {
        KeychainStore(service: service, accessGroup: nil, access: access).delete(account: Self.account)
    }

    private func keychain(_ group: String) -> KeychainStore {
        KeychainStore(service: service, accessGroup: group, access: access)
    }

    /// The stored JSON, written with sorted keys.
    private struct Item: Codable {
        var v = 1
        var appId: String
        var apiBaseURL: String
        var deviceId: String
        var deviceSecret: String

        private enum CodingKeys: String, CodingKey {
            case v
            case appId = "app_id"
            case apiBaseURL = "api_base_url"
            case deviceId = "device_id"
            case deviceSecret = "device_secret"
        }
    }

    /// Valid credentials, or nil for a value this SDK could not have written.
    private static func decode(_ data: Data) -> ExtensionCredentials? {
        guard let item = StoredJSON.decode(Item.self, from: data), item.v == 1, Validation.isAppId(item.appId),
              let base = APIBase.validated(URL(string: item.apiBaseURL)), Validation.isUUID(item.deviceId),
              Validation.isBase64URL(item.deviceSecret)
        else { return nil }
        return ExtensionCredentials(appId: item.appId, base: base, deviceId: item.deviceId.lowercased(),
                                    secret: SecretString(item.deviceSecret))
    }
}
