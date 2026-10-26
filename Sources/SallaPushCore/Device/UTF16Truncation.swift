import Foundation

extension String {
    /// The longest prefix made of whole Unicode scalars whose UTF-16 length is at most `max`.
    /// push-service measures limits in UTF-16 code units (JavaScript `String.length`), so this never exceeds them
    /// and never splits a surrogate pair.
    package func truncatedUTF16(_ max: Int) -> String {
        guard max > 0 else { return "" }
        if utf16.count <= max { return self }
        var units = 0
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            let width = scalar.utf16.count
            if units + width > max { break }
            units += width
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

/// Device metadata normalisation: trimmed, truncated to the server limit, and omitted when empty.
package enum FieldLimit {
    package static let appVersion = 32
    package static let sdkVersion = 32
    package static let osVersion = 32
    package static let deviceModel = 64
    package static let language = 16
    package static let timezone = 64
    package static let tagValue = 255

    /// The trimmed, truncated value, or nil when nothing is left.
    package static func normalize(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).truncatedUTF16(max)
        let cleaned = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
