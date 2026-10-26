import Foundation

/// A secret held in memory: the device secret or the customer token.
/// It prints as `<redacted>` everywhere (string interpolation, `print`, `dump`, debuggers).
package struct SecretString: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The secret itself. Read it only to build a request header or body.
    package let revealed: String

    package init(_ value: String) {
        revealed = value
    }

    package var description: String { "<redacted>" }
    package var debugDescription: String { "<redacted>" }
    package var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// An APNs push token (lowercase hex). It prints as `…` plus its last 6 characters.
package struct PushToken: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The full token: sent to push-service, and logged only by the info status lines (`status.launch`,
    /// `status.changed`) while the app's Info.plist turns on the debug switch `SallaPushLogFullIdentifiers` in the
    /// sandbox APNs environment.
    package let hex: String

    package init(hex: String) {
        self.hex = hex
    }

    /// The token of an APNs registration, or nil when the data is not 32-100 bytes.
    package init?(deviceToken: Data) {
        guard (32...100).contains(deviceToken.count) else { return nil }
        hex = Hex.lowercase(deviceToken)
    }

    package var description: String { "…" + String(hex.suffix(6)) }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
