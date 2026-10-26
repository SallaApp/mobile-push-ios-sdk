import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// push-service's admin generates a UUID v4 app id or takes a custom slug (`^[A-Za-z0-9_-]{1,64}$`): the files and the
/// Keychain item of such an app are found like any other app's.
final class AppIdRuleTests: XCTestCase {
    private let uuidAppId = "6f1c2b7e-3d4a-4c5b-9e8f-0a1b2c3d4e5f"

    /// A pending unlink of a UUID app id, left by an earlier session, is found for a drain-only engine with its own API
    /// base, path included; a folder whose name is no app id is skipped.
    func test_drainScanner_findsTheFoldersOfUUIDAppIds() throws {
        let h = Harness()
        let files = FileStore(root: h.root)
        let keychain = KeychainStore(bundleIdentifier: "com.salla.test", access: h.keychainAccess)
        let tag = APIBase.production.hostTag
        let unlink: [String: Any] = ["id": 1, "kind": "unlink", "clear_tags": true, "sent": false, "attempts": 0, "next_at": 0.0]
        for appId in [uuidAppId, "bad.id", "st_42_ios"] {
            let identity: [String: Any] = ["v": 1, "app_id": appId, "api_base_url": APIBase.production.string, "ops": [unlink]]
            XCTAssertTrue(files.write("\(appId)/\(tag)/identity.json", data: try JSONSerialization.data(withJSONObject: identity)))
            let account = KeychainStore.credentialsAccount(appId: appId, hostTag: tag)
            XCTAssertEqual(keychain.write(account: account, data: Data("{}".utf8)), .success)
        }
        let found = DrainEngineScanner.candidates(files: files, keychain: keychain, excludedFolder: "st_42_ios/\(tag)")
        XCTAssertEqual(found.map(\.appId), [uuidAppId])
        XCTAssertEqual(found.first?.base.string, "https://api.salla.dev/notifications/v1/sallapush")
        XCTAssertEqual(found.first?.folder, "\(uuidAppId)/\(tag)")
    }
}
