import CryptoKit
import Foundation

/// SHA-256 helpers. Fingerprints identify a value without storing or logging it.
package enum Fingerprint {
    /// Lowercase hex SHA-256 of `data`.
    package static func sha256Hex(_ data: Data) -> String {
        Hex.lowercase(SHA256.hash(data: data))
    }

    /// SHA-256 of the canonical JSON (sorted keys) of `value`; nil when it cannot be encoded.
    package static func canonical<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return sha256Hex(data)
    }
}

/// Lowercase hexadecimal encoding, two characters per byte.
package enum Hex {
    private static let digits = Array("0123456789abcdef")

    /// Encodes any byte sequence.
    package static func lowercase<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var characters: [Character] = []
        characters.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(characters)
    }
}
