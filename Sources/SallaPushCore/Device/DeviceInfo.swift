import Foundation

/// The device facts that are not app configuration. Injected so tests control them.
package protocol DeviceFactsSource: Sendable {
    /// `M.m.p` from `ProcessInfo` (no `UIDevice`, which is main-actor isolated).
    func osVersion() -> String
    /// The hardware model (`iPhone15,2`); the simulated model in the simulator.
    func deviceModel() -> String
    /// The language part of the first preferred language (`ar-SA` → `ar`).
    func preferredLanguage() -> String?
    /// The IANA time zone identifier.
    func timeZone() -> String
}

/// The real device.
package struct SystemDeviceFacts: DeviceFactsSource {
    package init() {}

    package func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    package func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "" }
        let bytes = withUnsafeBytes(of: &systemInfo.machine) { raw in
            Array(raw.prefix { $0 != 0 })
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    package func preferredLanguage() -> String? {
        guard let first = Locale.preferredLanguages.first else { return nil }
        let language = first.split(separator: "-").first.map(String.init) ?? first
        return language.isEmpty ? nil : language.lowercased()
    }

    package func timeZone() -> String {
        TimeZone.current.identifier
    }
}
