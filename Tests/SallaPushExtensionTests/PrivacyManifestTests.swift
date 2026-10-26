import Foundation
import XCTest

/// The extension library's privacy manifest, which Xcode adds to the app's privacy report.
final class PrivacyManifestTests: XCTestCase {
    /// The extension sends `received` itself, so its privacy manifest declares the notification events (product
    /// interaction, used for delivery analytics) next to the device id and the customer link, none of it for tracking,
    /// and no required-reason API.
    func test_extensionPrivacyManifest_declaresTheCollectedData() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/SallaPushExtension/PrivacyInfo.xcprivacy").standardizedFileURL
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
