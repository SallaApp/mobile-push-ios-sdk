import Foundation

/// Input validation by explicit character scans (no regular expressions on hot paths, nothing that can trap).
package enum Validation {
    /// `^[a-z0-9_]{1,64}$`: tag keys (app ids follow `isAppId`).
    package static func isLowerIdentifier(_ value: String, maxLength: Int = 64) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxLength else { return false }
        return scalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    /// `^[A-Za-z0-9_-]{1,64}$`: SallaPush app ids. push-service's admin generates a UUID v4 (lowercase hex with hyphens)
    /// or takes a custom slug.
    package static func isAppId(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 64 else { return false }
        return scalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "-"
        }
    }

    /// A UUID in any letter case.
    package static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.count == 36
    }

    /// Non-empty base64url (or padded base64) text.
    package static func isBase64URL(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 1_024 else { return false }
        var paddingStarted = false
        var padding = 0
        for scalar in scalars {
            if scalar == "=" {
                paddingStarted = true
                padding += 1
                continue
            }
            if paddingStarted { return false }
            let valid = ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
            if !valid { return false }
        }
        return padding <= 2 && padding < scalars.count
    }

    /// Lowercase hex digits only.
    package static func isLowerHex(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// An update fingerprint: 64 lowercase hex characters (SHA-256).
    package static func isUpdateFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && isLowerHex(value)
    }

    /// An APNs token as SallaPush keeps it: lowercase hex of 32 to 100 bytes.
    package static func isPushTokenHex(_ value: String) -> Bool {
        let count = value.utf8.count
        return (64...200).contains(count) && count.isMultiple(of: 2) && isLowerHex(value)
    }
}

/// Whether `value`, a class reference or a class-bound existential, is a null reference. Objective-C, React Native
/// and Flutter callers can pass nil where Swift declares a nonnull object, and any use of that null reference crashes,
/// so entry points check its bit pattern before anything else touches it.
package func isNullReference<Value>(_ value: Value) -> Bool {
    MemoryLayout<Value>.size == MemoryLayout<UnsafeRawPointer?>.size
        && unsafeBitCast(value, to: UnsafeRawPointer?.self) == nil
}

/// Exact conversions of payload numbers. JSON integers above 2^53 are not representable as `Double`, so integers are
/// read from their integer storage, never through `doubleValue`.
package enum NumericText {
    /// `[+-]digits[.digits][e[+-]digits]`: plain decimal notation, without hex, `inf` or `nan`.
    package static func isDecimal(_ text: String) -> Bool {
        let allowed = Set("0123456789+-.eE".unicodeScalars)
        return !text.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) } && Double(text) != nil
    }

    /// The exact integer value of `number`, or nil for booleans, fractions and values outside `Int`.
    package static func exactInteger(_ number: NSNumber) -> Int? {
        if number.isBoolean { return nil }
        // Integers beyond UInt64 arrive as NSDecimalNumber, whose integer accessors are not exact.
        if number is NSDecimalNumber { return Int(number.stringValue) }
        if CFNumberIsFloatType(number) { return Int(exactly: number.doubleValue) }
        switch UInt8(bitPattern: number.objCType.pointee) {
        case UInt8(ascii: "Q"), UInt8(ascii: "L"), UInt8(ascii: "I"), UInt8(ascii: "S"), UInt8(ascii: "C"):
            return Int(exactly: number.uint64Value)
        default:
            return Int(exactly: number.int64Value)
        }
    }
}
