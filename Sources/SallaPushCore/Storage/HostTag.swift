import Foundation

/// Per-host partitioning of stored state: credentials of one API host are never sent to another.
package enum HostTag {
    /// The lowercased `scheme://host[:port]` of `url`.
    package static func origin(of url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// The first 8 hex characters of SHA-256 of the lowercased `scheme://host[:port]`.
    package static func make(for url: URL) -> String {
        String(Fingerprint.sha256Hex(Data(origin(of: url).utf8)).prefix(8))
    }
}
