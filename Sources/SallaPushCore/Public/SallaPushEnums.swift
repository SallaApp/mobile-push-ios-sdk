import Foundation

/// The APNs environment SallaPush reports for this build's push token.
@objc public enum SallaPushAPNsEnvironment: Int, Sendable {
    /// Read from the app's embedded provisioning profile; the simulator is always sandbox,
    /// and a build without a profile (App Store, TestFlight) is production.
    case automatic
    /// Development APNs (debug builds signed with a development profile).
    case sandbox
    /// Production APNs (App Store, TestFlight, ad hoc and enterprise builds).
    case production
}

/// The shape of a SallaPush notification payload.
@objc public enum SallaPushPayloadSource: Int, Sendable {
    /// A native SallaPush payload (`sp_v`, `sp_id`, …).
    case native
    /// SallaPush's compatible payload format, with typed data (`custom.a.push_ref`).
    case compat
}
