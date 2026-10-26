import Foundation

/// SallaPush message ids (`^msg_[0-9a-f]{1,64}$`). Only notifications with a valid id of at most 40 characters, the
/// longest push-service stores, produce events.
package enum MessageId {
    /// The longest message id push-service stores: 40 characters. One longer id makes it lose the whole batch while
    /// answering 202, so neither the app nor the extension sends an event for it.
    package static let maximumStoredLength = 40

    /// Whether `value` is a valid message id.
    package static func isValid(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count > 4, scalars.count <= 68 else { return false }
        guard scalars[0] == "m", scalars[1] == "s", scalars[2] == "g", scalars[3] == "_" else { return false }
        return scalars[4...].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Whether `value` is a valid message id push-service stores: at most `maximumStoredLength` characters.
    package static func isStorable(_ value: String) -> Bool {
        isValid(value) && value.utf8.count <= maximumStoredLength
    }

    /// `value` when it is a string holding a valid message id.
    package static func validated(_ value: Any?) -> String? {
        guard let string = value as? String, isValid(string) else { return nil }
        return string
    }
}
