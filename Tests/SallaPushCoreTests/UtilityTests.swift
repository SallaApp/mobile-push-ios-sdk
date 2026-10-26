import Foundation
@testable import SallaPushCore
import XCTest

final class BackoffTests: XCTestCase {
    func test_delay_followsTheFormula() {
        XCTAssertEqual(Backoff.delay(attempt: 1, random: 1), 2)
        XCTAssertEqual(Backoff.delay(attempt: 1, random: 0), 1)
        XCTAssertEqual(Backoff.delay(attempt: 2, random: 1), 4)
        XCTAssertEqual(Backoff.delay(attempt: 5, random: 1), 32)
        XCTAssertEqual(Backoff.delay(attempt: 12, random: 1), 3_600)
    }

    func test_delay_isBounded_forHugeOrInvalidInput() {
        XCTAssertEqual(Backoff.delay(attempt: Int.max, random: 1), 3_600)
        XCTAssertEqual(Backoff.delay(attempt: Int.min, random: 1), 2)
        XCTAssertEqual(Backoff.delay(attempt: 3, random: .nan), 8)
        XCTAssertEqual(Backoff.delay(attempt: 3, random: 7), 8)
        for attempt in 1...40 {
            let delay = Backoff.delay(attempt: attempt, random: 0.5)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 3_600)
        }
    }

    func test_durations_areClamped() {
        XCTAssertEqual(Duration.clamped(-5), 0)
        XCTAssertEqual(Duration.clamped(.infinity), 0)
        XCTAssertEqual(Duration.clamped(.nan), 0)
        XCTAssertEqual(Duration.clamped(1e12), 86_400)
        XCTAssertEqual(Duration.clamped(12), 12)
    }
}

final class RetryAfterTests: XCTestCase {
    private let now: Double = 1_790_000_000

    func test_seconds() {
        XCTAssertEqual(RetryAfter.seconds(from: "120", now: now), 120)
        XCTAssertEqual(RetryAfter.seconds(from: " 0 ", now: now), 1)
        XCTAssertEqual(RetryAfter.seconds(from: "999999999", now: now), 86_400)
    }

    func test_httpDate() {
        // 1790000000 = Mon, 21 Sep 2026 14:13:20 GMT
        XCTAssertEqual(RetryAfter.seconds(from: "Mon, 21 Sep 2026 14:15:20 GMT", now: now), 120)
        XCTAssertEqual(RetryAfter.seconds(from: "Mon, 21 Sep 2026 14:13:00 GMT", now: now), 1)
    }

    func test_invalid_isNil() {
        XCTAssertNil(RetryAfter.seconds(from: nil, now: now))
        XCTAssertNil(RetryAfter.seconds(from: "", now: now))
        XCTAssertNil(RetryAfter.seconds(from: "soon", now: now))
    }
}

final class UTF16TruncationTests: XCTestCase {
    func test_arabicWithHarakat_countsUTF16Units() {
        let text = String(repeating: "مَ", count: 200)
        XCTAssertEqual(text.utf16.count, 400)
        for limit in [254, 255, 256] {
            let truncated = text.truncatedUTF16(limit)
            XCTAssertLessThanOrEqual(truncated.utf16.count, limit)
            XCTAssertGreaterThanOrEqual(truncated.utf16.count, limit - 1)
            XCTAssertTrue(text.unicodeScalars.starts(with: truncated.unicodeScalars))
        }
    }

    func test_surrogatePairAtTheBoundary_isNeverSplit() {
        let text = String(repeating: "a", count: 254) + "😀" + "b"
        XCTAssertEqual(text.truncatedUTF16(255), String(repeating: "a", count: 254))
        XCTAssertEqual(text.truncatedUTF16(256).utf16.count, 256)
        XCTAssertEqual(text.truncatedUTF16(257).utf16.count, 257)
    }

    func test_emoji_onlyWholeScalars() {
        let text = String(repeating: "👍🏽", count: 100)
        let truncated = text.truncatedUTF16(255)
        XCTAssertLessThanOrEqual(truncated.utf16.count, 255)
        XCTAssertNotNil(truncated.data(using: .utf8))
        XCTAssertFalse(truncated.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) })
    }

    func test_normalize_trimsTruncatesAndOmitsEmpty() {
        XCTAssertNil(FieldLimit.normalize(nil, max: 16))
        XCTAssertNil(FieldLimit.normalize("   ", max: 16))
        XCTAssertEqual(FieldLimit.normalize("  ar  ", max: 16), "ar")
        XCTAssertEqual(FieldLimit.normalize(String(repeating: "x", count: 40), max: 32)?.utf16.count, 32)
        XCTAssertEqual("abc".truncatedUTF16(0), "")
    }
}

final class ValidationTests: XCTestCase {
    func test_lowerIdentifier() {
        XCTAssertTrue(Validation.isLowerIdentifier("st_42_ios"))
        XCTAssertFalse(Validation.isLowerIdentifier("St-42"))
        XCTAssertFalse(Validation.isLowerIdentifier(""))
        XCTAssertFalse(Validation.isLowerIdentifier(String(repeating: "a", count: 65)))
        XCTAssertFalse(Validation.isLowerIdentifier("مرحبا"))
    }

    /// push-service's admin generates a UUID v4 app id or takes a custom slug: `^[A-Za-z0-9_-]{1,64}$`.
    func test_appId() {
        for valid in ["st_42_ios", "6f1c2b7e-3d4a-4c5b-9e8f-0a1b2c3d4e5f", "6F1C2B7E-3D4A-4C5B-9E8F-0A1B2C3D4E5F", "St-42",
                      "my-store_app", "-", "_", String(repeating: "a", count: 64)] {
            XCTAssertTrue(Validation.isAppId(valid), valid)
        }
        for invalid in ["", String(repeating: "a", count: 65), "st 42", "st.42", "st/42", "../st", "st_42\n", "مرحبا", "st+42",
                        "st%2F42", "é"] {
            XCTAssertFalse(Validation.isAppId(invalid), invalid)
        }
        XCTAssertFalse(Validation.isLowerIdentifier("6f1c2b7e-3d4a-4c5b-9e8f-0a1b2c3d4e5f"), "tag keys keep their rule")
    }

    func test_messageId() {
        XCTAssertTrue(MessageId.isValid("msg_0123456789abcdef"))
        XCTAssertFalse(MessageId.isValid("msg_"))
        XCTAssertFalse(MessageId.isValid("msg_XYZ"))
        XCTAssertFalse(MessageId.isValid("0123abcd"))
        XCTAssertFalse(MessageId.isValid("42"))
        XCTAssertFalse(MessageId.isValid("msg_" + String(repeating: "a", count: 65)))
        XCTAssertNil(MessageId.validated(42))
    }

    func test_uuidAndBase64URL() {
        XCTAssertTrue(Validation.isUUID("3F2A8C1E-0000-4000-8000-000000000001"))
        XCTAssertTrue(Validation.isUUID("3f2a8c1e-0000-4000-8000-000000000001"))
        XCTAssertFalse(Validation.isUUID("not-a-uuid"))
        XCTAssertTrue(Validation.isBase64URL("c2VjcmV0"))
        XCTAssertTrue(Validation.isBase64URL("c2VjcmV0-_=="))
        XCTAssertFalse(Validation.isBase64URL(""))
        XCTAssertFalse(Validation.isBase64URL("a=b"))
        XCTAssertFalse(Validation.isBase64URL("with space"))
    }
}

final class LockedTests: XCTestCase {
    func test_exchange_returnsTheOldValue_andStoresTheNewOne() {
        let box = Locked("old")
        XCTAssertEqual(box.exchange("new"), "old")
        XCTAssertEqual(box.current, "new")
    }

    /// A value whose deinit takes the lock of the box that held it: releasing it inside the lock would deadlock.
    private final class Reentrant: @unchecked Sendable {
        let box: Locked<Reentrant?>
        let touched: Locked<Bool>

        init(box: Locked<Reentrant?>, touched: Locked<Bool>) {
            self.box = box
            self.touched = touched
        }

        deinit {
            _ = box.current
            touched.set(true)
        }
    }

    func test_exchange_releasesTheOldValueOutsideTheLock() {
        let box = Locked<Reentrant?>(nil)
        let touched = Locked(false)
        box.set(Reentrant(box: box, touched: touched))
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // The scope ends before the signal, so the old value's deinit has run when the test reads `touched`.
            do {
                let replaced = box.exchange(nil)
                withExtendedLifetime(replaced) {}
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the old value's deinit re-entered the lock")
        XCTAssertTrue(touched.current)
    }
}

final class NumericTextTests: XCTestCase {
    private func number(_ json: String) throws -> NSNumber {
        let object = try JSONSerialization.jsonObject(with: Data("{\"n\": \(json)}".utf8)) as? [String: Any]
        return try XCTUnwrap(object?["n"] as? NSNumber)
    }

    func test_exactInteger_readsIntegerStorage_withoutRoundingThroughDouble() throws {
        XCTAssertEqual(NumericText.exactInteger(try number("9007199254740993")), 9_007_199_254_740_993)
        XCTAssertEqual(NumericText.exactInteger(try number("9223372036854775807")), Int.max)
        XCTAssertEqual(NumericText.exactInteger(try number("-9223372036854775808")), Int.min)
        XCTAssertNil(NumericText.exactInteger(try number("9223372036854775808")), "unsigned storage above Int.max")
        XCTAssertNil(NumericText.exactInteger(try number("18446744073709551615")))
        XCTAssertNil(NumericText.exactInteger(try number("18446744073709551616")), "NSDecimalNumber beyond UInt64")
        XCTAssertEqual(NumericText.exactInteger(try number("42.0")), 42)
        XCTAssertNil(NumericText.exactInteger(try number("42.5")))
        XCTAssertEqual(NumericText.exactInteger(try number("1e3")), 1_000)
        XCTAssertNil(NumericText.exactInteger(try number("true")))
        XCTAssertEqual(NumericText.exactInteger(NSNumber(value: UInt8(250))), 250)
        XCTAssertEqual(NumericText.exactInteger(NSNumber(value: Int8(-5))), -5)
    }

    func test_isDecimal_acceptsPlainNotationOnly() {
        for text in ["12", "-12", "+1.5", "12.000", "4.2e1", "1E-3"] {
            XCTAssertTrue(NumericText.isDecimal(text), text)
        }
        for text in ["", "0x10", "inf", "nan", "Infinity", "1-2", "1e5e5", "12abc", " 12"] {
            XCTAssertFalse(NumericText.isDecimal(text), text)
        }
    }
}

final class OnceTests: XCTestCase {
    func test_claim_succeedsOnlyOnce_acrossThreads() {
        let once = Once()
        let wins = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if once.claim() { wins.withLock { $0 += 1 } }
        }
        XCTAssertEqual(wins.current, 1)
        XCTAssertFalse(once.claim(), "a later claim still fails")
    }

    func test_continuation_resumesOnce_andReportsRepeats() async {
        let repeats = Locked(0)
        let value = await onceContinuation(onRepeat: { repeats.withLock { $0 += 1 } }, { (resume: @escaping @Sendable (Int) -> Void) in
            resume(1)
            resume(2)
            DispatchQueue.global().async { resume(3) }
        })
        XCTAssertEqual(value, 1)
        XCTAssertGreaterThanOrEqual(repeats.current, 1)
    }
}

final class FingerprintTests: XCTestCase {
    func test_hex_isLowercaseTwoPerByte() {
        XCTAssertEqual(Hex.lowercase([0x0A, 0xFF, 0x00, 0x7B, 0xC4]), "0aff007bc4")
    }

    func test_canonical_isOrderIndependent() {
        struct Forward: Encodable { let beta = 1; let alpha = "x" }
        struct Backward: Encodable { let alpha = "x"; let beta = 1 }
        XCTAssertEqual(Fingerprint.canonical(Forward()), Fingerprint.canonical(Backward()))
    }
}

final class ISO8601Tests: XCTestCase {
    /// push-service cuts an event's `at` at the first `.` before it stores it: SallaPush writes UTC with milliseconds,
    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, always three digits.
    func test_string_isUTCWithMilliseconds() {
        XCTAssertEqual(ISO8601.string(from: 1_790_000_000), "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(ISO8601.string(from: 1_790_000_000.123), "2026-09-21T14:13:20.123Z")
        XCTAssertEqual(ISO8601.string(from: 1_790_000_000.001), "2026-09-21T14:13:20.001Z")
        XCTAssertEqual(ISO8601.string(from: 1_790_000_000.05), "2026-09-21T14:13:20.050Z")
        XCTAssertEqual(ISO8601.string(from: 0), "1970-01-01T00:00:00.000Z")
        let text = ISO8601.string(from: 1_790_000_000.5)
        XCTAssertEqual(text.count, 24)
        XCTAssertEqual(text.split(separator: ".").first.map(String.init), "2026-09-21T14:13:20", "what push-service keeps")
    }

    /// Events and inbox files of an earlier version carry no fraction: both forms are read, with any zone designator.
    func test_seconds_readsBothForms() throws {
        XCTAssertEqual(ISO8601.seconds(from: "2026-09-21T14:13:20Z"), 1_790_000_000)
        XCTAssertEqual(ISO8601.seconds(from: "2026-09-21T14:13:20.000Z"), 1_790_000_000)
        XCTAssertEqual(try XCTUnwrap(ISO8601.seconds(from: "2026-09-21T14:13:20.123Z")), 1_790_000_000.123, accuracy: 0.000_5)
        XCTAssertEqual(ISO8601.seconds(from: "2026-09-21T17:13:20+03:00"), 1_790_000_000)
        XCTAssertEqual(ISO8601.seconds(from: "2026-09-21T17:13:20.500+03:00"), 1_790_000_000.5)
        XCTAssertNil(ISO8601.seconds(from: "not-a-date"))
        XCTAssertNil(ISO8601.seconds(from: "2026-09-21T14:13:20"), "a zone designator is required")
        XCTAssertNil(ISO8601.seconds(from: "2026-09-21 14:13:20.000Z"))
        XCTAssertNil(ISO8601.seconds(from: ""))
    }

    /// Reading what was written and writing it again gives the same text, so re-sending a stored event never moves it.
    func test_roundTrip_isStable() throws {
        for seconds in [1_790_000_000.0, 1_790_000_000.001, 1_790_000_000.5, 1_790_000_000.999, 1_790_000_123.456_7] {
            let text = ISO8601.string(from: seconds)
            let read = try XCTUnwrap(ISO8601.seconds(from: text), text)
            XCTAssertEqual(read, seconds, accuracy: 0.000_5, text)
            XCTAssertEqual(ISO8601.string(from: read), text)
        }
        XCTAssertEqual(ISO8601.seconds(from: "2026-09-21T14:13:20Z").map(ISO8601.string(from:)), "2026-09-21T14:13:20.000Z")
    }
}
