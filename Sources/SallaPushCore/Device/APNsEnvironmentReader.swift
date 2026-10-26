import Foundation

/// The `apns_env` value sent to push-service.
package enum APNsEnvironment: String, Sendable, Codable {
    case sandbox
    case production
}

/// Reads the APNs environment of this build from its embedded provisioning profile.
///
/// The profile is a CMS envelope around an XML plist. It is decoded as ISO-Latin-1, the slice from `<?xml` to
/// `</plist>` is parsed, and `Entitlements["aps-environment"]` is read: `development` means sandbox, anything else
/// production. Without a profile, the simulator is sandbox and a device is production (App Store and TestFlight).
package struct APNsEnvironmentReader: Sendable {
    /// The profile location; nil when the bundle has none.
    package let profileURL: URL?
    /// Whether this process runs in the simulator.
    package let isSimulator: Bool

    package init(profileURL: URL?, isSimulator: Bool) {
        self.profileURL = profileURL
        self.isSimulator = isSimulator
    }

    /// The reader for the main bundle of the current process.
    package static func mainBundle() -> APNsEnvironmentReader {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return APNsEnvironmentReader(profileURL: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                                     isSimulator: simulator)
    }

    /// The environment, honouring an explicit override first. An undeclared raw value counts as `.automatic`.
    package func environment(override: SallaPushAPNsEnvironment) -> APNsEnvironment {
        switch SallaPushAPNsEnvironment(rawValue: override.rawValue) ?? .automatic {
        case .sandbox: return .sandbox
        case .production: return .production
        case .automatic: return read()
        }
    }

    /// The environment from the profile, or the platform default without one.
    package func read() -> APNsEnvironment {
        guard let profileURL, let data = try? Data(contentsOf: profileURL) else {
            return isSimulator ? .sandbox : .production
        }
        return Self.environment(profile: data)
    }

    /// Parses profile bytes; anything unreadable or without `aps-environment = development` is production.
    package static func environment(profile data: Data) -> APNsEnvironment {
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex)
        else { return .production }
        let plistText = String(text[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return .production }
        return environment == "development" ? .sandbox : .production
    }
}
