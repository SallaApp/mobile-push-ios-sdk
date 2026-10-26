import Foundation
@testable import SallaPushCore
import XCTest

final class APNsEnvironmentReaderTests: XCTestCase {
    private func reader(_ profile: String?, simulator: Bool = false) throws -> APNsEnvironmentReader {
        APNsEnvironmentReader(profileURL: try profile.map { try Fixtures.url("profiles/\($0)") }, isSimulator: simulator)
    }

    // The five cases of the APNs environment.
    func test_withoutAProvisioningProfile_isProduction() throws {
        XCTAssertEqual(try reader(nil).read(), .production)
    }

    func test_withADevelopmentProfile_isSandbox() throws {
        XCTAssertEqual(try reader("development.profile").read(), .sandbox)
    }

    func test_withAProductionProfile_isProduction() throws {
        XCTAssertEqual(try reader("production.profile").read(), .production)
    }

    func test_withAProfileWithoutPushEntitlement_isProduction() throws {
        XCTAssertEqual(try reader("no-push.profile").read(), .production)
    }

    func test_withAnUnreadableProfile_isProduction() throws {
        XCTAssertEqual(try reader("garbage.profile").read(), .production)
    }

    // The simulator fix and the override.
    func test_simulatorWithoutProfile_isSandbox() throws {
        XCTAssertEqual(try reader(nil, simulator: true).read(), .sandbox)
    }

    func test_missingFileURL_behavesLikeNoProfile() {
        let missing = APNsEnvironmentReader(profileURL: URL(fileURLWithPath: "/nonexistent/embedded.mobileprovision"),
                                            isSimulator: true)
        XCTAssertEqual(missing.read(), .sandbox)
    }

    func test_override_wins() throws {
        let development = try reader("development.profile")
        XCTAssertEqual(development.environment(override: .production), .production)
        XCTAssertEqual(try reader(nil).environment(override: .sandbox), .sandbox)
        XCTAssertEqual(development.environment(override: .automatic), .sandbox)
    }
}

final class DeviceInfoTests: XCTestCase {
    func test_osVersion_isMajorMinorPatch() {
        let parts = SystemDeviceFacts().osVersion().split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func test_deviceModel_isNonEmptyMachineName() {
        let model = SystemDeviceFacts().deviceModel()
        XCTAssertFalse(model.isEmpty)
        XCTAssertFalse(model.contains("\u{0}"))
    }

    func test_language_isTheLanguagePart() {
        if let language = SystemDeviceFacts().preferredLanguage() {
            XCTAssertFalse(language.contains("-"))
            XCTAssertEqual(language, language.lowercased())
        }
    }

    func test_timeZone_isAnIdentifier() {
        XCTAssertEqual(SystemDeviceFacts().timeZone(), TimeZone.current.identifier)
    }

    func test_pushToken_isLowercaseHexAndRedacted() throws {
        let bytes = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let token = try XCTUnwrap(PushToken(deviceToken: bytes))
        XCTAssertEqual(token.hex, Hex.lowercase(bytes))
        XCTAssertEqual(token.hex.count, 64)
        XCTAssertEqual("\(token)", "…" + String(token.hex.suffix(6)))
        XCTAssertNil(PushToken(deviceToken: Data()))
        XCTAssertNil(PushToken(deviceToken: Data(repeating: 1, count: 31)))
        XCTAssertNil(PushToken(deviceToken: Data(repeating: 1, count: 101)))
        XCTAssertNotNil(PushToken(deviceToken: Data(repeating: 1, count: 100)))
    }
}

final class RedactionCoreTests: XCTestCase {
    func test_secretString_neverPrints() {
        let secret = SecretString("super-secret")
        XCTAssertEqual("\(secret)", "<redacted>")
        XCTAssertEqual(String(describing: secret), "<redacted>")
        XCTAssertEqual(String(reflecting: secret), "<redacted>")
        var dumped = ""
        dump(secret, to: &dumped)
        XCTAssertFalse(dumped.contains("super-secret"))
        XCTAssertEqual(secret.revealed, "super-secret")
    }

    func test_sanitizer_removesControlCharacters_andCaps() {
        XCTAssertEqual(LogSanitizer.clean("a\u{0}b\nc\u{202E}d"), "ab cd")
        XCTAssertEqual(LogSanitizer.clean(String(repeating: "x", count: 500)).count, 200)
        XCTAssertEqual(LogSanitizer.clean("  spaced   out  "), "spaced out")
    }
}
