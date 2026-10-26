import Foundation
@testable import SallaPushCore
import XCTest

final class PayloadParserTests: XCTestCase {
    private let logs = LogRecorder()

    // MARK: - Goldens

    func test_nativeGolden_parsesEveryField() throws {
        let payloads = try Fixtures.goldenPayloads()
        let userInfo = try XCTUnwrap(payloads["c3-ios"])
        let parsed = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger))
        XCTAssertEqual(parsed.kind, .native)
        XCTAssertFalse(parsed.isLocalCopy)
        let notification = parsed.notification
        // "msg_test_001" is not lowercase hex, so it is no message id (covered below).
        XCTAssertNil(notification.notificationId)
        XCTAssertEqual(notification.title, "تم شحن طلبك")
        XCTAssertEqual(notification.body, "طلبك رقم 987 في الطريق")
        XCTAssertEqual(notification.imageURL?.absoluteString, "https://cdn.salla.sa/x.jpg")
        XCTAssertEqual(notification.launchURL, "salla://orders/987")
        XCTAssertEqual(notification.additionalData["orderId"] as? String, "987")
        XCTAssertNil(notification.additionalData["sp_id"])
        XCTAssertNil(notification.additionalData["aps"])
        XCTAssertEqual(notification.badge, 1)
        XCTAssertEqual(notification.sound, "default")
        XCTAssertEqual(notification.threadId, "orders")
        XCTAssertEqual(notification.source, .native)
        XCTAssertEqual(notification.int(forKey: "orderId"), 987)
    }

    func test_nativeGoldenId_isNotAMessageIdBecauseItIsNotHex() throws {
        // The golden uses "msg_test_001", which is not lowercase hex: the payload stays native, without events.
        let userInfo = try XCTUnwrap(try Fixtures.goldenPayloads()["c3-ios"])
        let parsed = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger))
        XCTAssertNil(parsed.messageId)
        XCTAssertEqual(logs.count("notif.parse_failed"), 1)
    }

    func test_compatGolden_parsesPushRefLaunchURLAndImage() throws {
        let userInfo = try XCTUnwrap(try Fixtures.goldenPayloads()["compat-push-ref"])
        let parsed = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger))
        XCTAssertEqual(parsed.kind, .compat)
        let notification = parsed.notification
        XCTAssertEqual(notification.notificationId, "msg_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(notification.launchURL, "https://s.salla.sa/o/987")
        XCTAssertEqual(notification.imageURL?.absoluteString, "https://cdn.salla.sa/x.jpg")
        XCTAssertEqual(notification.sound, "orders.wav")
        XCTAssertEqual(notification.string(forKey: "type"), "order")
        XCTAssertEqual(notification.int(forKey: "id"), 987)
        XCTAssertNil(notification.additionalData["push_ref"])
        XCTAssertEqual(notification.source, .compat)
    }

    func test_compatGolden_msg1_isCompat() throws {
        let userInfo = try XCTUnwrap(try Fixtures.goldenPayloads()["compat-ios"])
        let parsed = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger))
        XCTAssertEqual(parsed.messageId, "msg_1")
        XCTAssertEqual(parsed.notification.title, "تم شحن طلبك")
    }

    func test_compatTypedData_keepsTypes() throws {
        let userInfo = try XCTUnwrap(try Fixtures.goldenPayloads()["compat-ios-typed-data"])
        let notification = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger)).notification
        let id = try XCTUnwrap(notification.additionalData["id"] as? NSNumber)
        XCTAssertFalse(id.isBoolean)
        XCTAssertEqual(id.intValue, 987)
        let flag = try XCTUnwrap(notification.additionalData["flag"] as? NSNumber)
        XCTAssertTrue(flag.isBoolean)
        XCTAssertEqual(notification.bool(forKey: "flag"), true)
        XCTAssertEqual(notification.int(forKey: "id"), 987)
        XCTAssertEqual(notification.number(forKey: "id")?.intValue, 987)
        XCTAssertEqual(notification.string(forKey: "id"), "987")
    }

    // MARK: - Native rules

    func test_stringAlert_isTheBody() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["aps": ["alert": "Hello"], "sp_v": "1", "sp_id": "msg_ab"],
                                                       logger: logs.logger))
        XCTAssertEqual(parsed.notification.body, "Hello")
        XCTAssertNil(parsed.notification.title)
    }

    func test_numericVersion_isNative() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": 1, "sp_id": "msg_ab"], logger: logs.logger))
        XCTAssertEqual(parsed.kind, .native)
        XCTAssertEqual(parsed.messageId, "msg_ab")
        XCTAssertEqual(logs.count("notif.unknown_version"), 0)
    }

    func test_unknownVersion_parsedBestEffort() throws {
        let version = "v\(UUID().uuidString.prefix(6))"
        let first = try XCTUnwrap(PayloadParser.parse(["sp_v": version, "sp_id": "msg_ab"], logger: logs.logger))
        XCTAssertEqual(first.kind, .native)
        XCTAssertEqual(first.messageId, "msg_ab")
        _ = PayloadParser.parse(["sp_v": version, "sp_id": "msg_cd"], logger: logs.logger)
        XCTAssertEqual(logs.count("notif.unknown_version"), 1)
    }

    /// WARN `notif.unknown_version` once per process, not once per version (the
    /// process's logger keeps the once-key).
    func test_unknownVersion_isWarnedOncePerProcess_whateverTheVersion() {
        for version in ["2", "3", "9", "v4"] {
            _ = PayloadParser.parse(["sp_v": version, "sp_id": "msg_ab"], logger: logs.logger)
        }
        _ = PayloadParser.parse(["sp_v": 7, "sp_id": "msg_ab"], logger: logs.logger)
        XCTAssertEqual(logs.count("notif.unknown_version"), 1)
        XCTAssertTrue(logs.all.first { $0.code == "notif.unknown_version" }?.message.contains("payload version 2") ?? false)
    }

    func test_invalidSpId_isNativeWithoutId() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "sp_id": "msg_XYZ", "aps": ["alert": ["title": "T"]]],
                                                       logger: logs.logger))
        XCTAssertEqual(parsed.kind, .native)
        XCTAssertNil(parsed.messageId)
        XCTAssertEqual(parsed.notification.title, "T")
    }

    func test_nonHTTPSImage_isDropped() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "sp_image": "http://cdn.salla.sa/x.jpg"],
                                                       logger: logs.logger))
        XCTAssertNil(parsed.notification.imageURL)
    }

    func test_soundDictionary_readsName() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "aps": ["sound": ["name": "chime.caf", "critical": 1]]],
                                                       logger: logs.logger))
        XCTAssertEqual(parsed.notification.sound, "chime.caf")
    }

    func test_localCopy_isRecognised() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "sp_id": "msg_ab", "sp_local": "1"], logger: logs.logger))
        XCTAssertTrue(parsed.isLocalCopy)
    }

    // MARK: - Compat rules

    func test_compatWithoutPushRef_isForeign() {
        let userInfo: [AnyHashable: Any] = ["custom": ["i": "7d3f1c2a-0000-4000-8000-000000000001", "a": ["type": "order"]]]
        XCTAssertNil(PayloadParser.parse(userInfo, logger: logs.logger))
        XCTAssertNil(PayloadParser.kind(of: userInfo))
    }

    func test_aCompatPushWithoutPushRef_isForeign() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "Hi"], "custom": ["i": "7d3f1c2a-0000-4000-8000-000000000001"]]
        XCTAssertNil(PayloadParser.parse(userInfo, logger: logs.logger))
    }

    func test_numericPushRef_isForeign() {
        let userInfo: [AnyHashable: Any] = ["custom": ["i": "x", "a": ["push_ref": 42]]]
        XCTAssertNil(PayloadParser.kind(of: userInfo))
    }

    func test_otherSDKs_areForeign() {
        let samples: [[AnyHashable: Any]] = [
            ["aps": ["alert": "MoEngage"], "moengage": ["cid": "1"], "moe_push_service": 1],
            ["aps": ["alert": "Klaviyo"], "body": ["_k": "abc", "url": "https://k.example"]],
            ["aps": ["alert": "WebEngage"], "source": "webengage", "message_data": ["identifier": "1"]],
            ["aps": ["content-available": 1], "af-uinstall-tracking": 1],
            ["intercom_push_type": "notification", "aps": ["alert": "Intercom"]],
        ]
        for sample in samples {
            XCTAssertNil(PayloadParser.parse(sample, logger: logs.logger))
        }
    }

    func test_compatLargerThan4KB_isForeign() {
        let big = String(repeating: "x", count: 5_000)
        let userInfo: [AnyHashable: Any] = ["custom": ["i": "x", "a": ["push_ref": "msg_1", "note": big]]]
        XCTAssertNil(PayloadParser.kind(of: userInfo))
    }

    func test_compatDeeperThan32_isForeign() {
        var nested: Any = ["leaf": "x"]
        for _ in 0..<40 { nested = ["n": nested] }
        let userInfo: [AnyHashable: Any] = ["custom": ["i": "x", "a": ["push_ref": "msg_1", "deep": nested]]]
        XCTAssertNil(PayloadParser.kind(of: userInfo))
    }

    // MARK: - Typed accessors

    func test_typedAccessors_acceptNumericStrings() throws {
        let parsed = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "id": "1234", "flag": "true", "zero": "0",
                                                        "ratio": "2.5", "word": "abc"], logger: logs.logger))
        let notification = parsed.notification
        XCTAssertEqual(notification.int(forKey: "id"), 1_234)
        XCTAssertEqual(notification.bool(forKey: "flag"), true)
        XCTAssertEqual(notification.bool(forKey: "zero"), false)
        XCTAssertEqual(notification.number(forKey: "ratio")?.doubleValue, 2.5)
        XCTAssertNil(notification.int(forKey: "ratio"))
        XCTAssertNil(notification.int(forKey: "word"))
        XCTAssertNil(notification.bool(forKey: "word"))
        XCTAssertNil(notification.int(forKey: "missing"))
    }

    func test_typedAccessors_areExact_above2To53() throws {
        let json = #"{"custom": {"i": "x", "a": {"push_ref": "msg_1", "big": 9007199254740993, "huge": 9223372036854775808, "#
            + #""whole": 42.0, "half": 42.5}}, "aps": {"alert": "x"}}"#
        let userInfo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let compat = try XCTUnwrap(PayloadParser.parse(userInfo, logger: logs.logger)).notification
        XCTAssertEqual(compat.int(forKey: "big"), 9_007_199_254_740_993, "not rounded to 9007199254740992")
        XCTAssertEqual(compat.string(forKey: "big"), "9007199254740993")
        XCTAssertNil(compat.int(forKey: "huge"), "beyond Int: nil, never a wrapped value")
        XCTAssertEqual(compat.int(forKey: "whole"), 42)
        XCTAssertNil(compat.int(forKey: "half"))

        let native = try XCTUnwrap(PayloadParser.parse(["sp_v": "1", "big": "9007199254740993", "padded": "12.000",
                                                        "hex": "0x10", "inf": "inf"], logger: logs.logger)).notification
        XCTAssertEqual(native.int(forKey: "big"), 9_007_199_254_740_993)
        XCTAssertEqual(native.int(forKey: "padded"), 12)
        XCTAssertNil(native.int(forKey: "hex"))
        XCTAssertNil(native.number(forKey: "hex"))
        XCTAssertNil(native.number(forKey: "inf"))
    }

    // MARK: - Robustness

    func test_deepNesting_isBounded() throws {
        var deep: Any = "bottom"
        for _ in 0..<2_000 { deep = ["n": deep] }
        let userInfo: [AnyHashable: Any] = ["sp_v": "1", "sp_id": "msg_ab", "deep": deep]
        let result = Locked<Int?>(nil)
        let done = expectation(description: "parsed")
        let logger = logs.logger
        let thread = Thread {
            let parsed = PayloadParser.parse(userInfo, logger: logger)
            var depth = 0
            var cursor = parsed?.notification.additionalData["deep"]
            while let dictionary = cursor as? [String: Any] {
                depth += 1
                cursor = dictionary["n"]
            }
            result.set(depth)
            done.fulfill()
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        wait(for: [done], timeout: 30)
        let depth = try XCTUnwrap(result.current)
        XCTAssertGreaterThan(depth, 0)
        XCTAssertLessThanOrEqual(depth, JSONValue.maximumDepth)
    }

    func test_fuzz_randomPayloads_neverCrash() {
        var generator = SeededGenerator(seed: 0x5A11A)
        for _ in 0..<1_000 {
            let userInfo = randomDictionary(&generator, depth: 0)
            _ = PayloadParser.kind(of: userInfo)
            _ = PayloadParser.parse(userInfo, logger: logs.logger)
        }
    }

    private func randomValue(_ generator: inout SeededGenerator, depth: Int) -> Any {
        switch Int.random(in: 0..<9, using: &generator) {
        case 0: return NSNull()
        case 1: return Int.random(in: -1_000...1_000, using: &generator)
        case 2: return Bool.random(using: &generator)
        case 3: return String(repeating: "ك", count: Int.random(in: 0...20_000, using: &generator))
        case 4: return depth < 6 ? randomDictionary(&generator, depth: depth + 1) : "leaf"
        case 5:
            guard depth < 6 else { return [] }
            return (0..<Int.random(in: 0...5, using: &generator)).map { _ in randomValue(&generator, depth: depth + 1) }
        case 6: return Double.random(in: -1e20...1e20, using: &generator)
        case 7: return ["msg_ab", "msg_", "1", "msg_XYZ", ""].randomElement(using: &generator) ?? ""
        default: return Data([0x01, 0x02])
        }
    }

    private func randomDictionary(_ generator: inout SeededGenerator, depth: Int) -> [AnyHashable: Any] {
        let keys: [AnyHashable] = ["aps", "sp_v", "sp_id", "sp_image", "sp_url", "custom", "i", "a", "u", "att", "id",
                                   "push_ref", "alert", "title", "body", "badge", "sound", 7, "thread-id"]
        var dictionary: [AnyHashable: Any] = [:]
        for _ in 0..<Int.random(in: 0...8, using: &generator) {
            if let key = keys.randomElement(using: &generator) {
                dictionary[key] = randomValue(&generator, depth: depth)
            }
        }
        return dictionary
    }
}

/// A deterministic generator for fuzzing.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
