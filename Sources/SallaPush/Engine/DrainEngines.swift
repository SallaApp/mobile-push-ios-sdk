import Foundation
import SallaPushCore

/// Finds other (app id, API host) folders that still have a pending logout from an earlier session, so they can be
/// finished by drain-only engines. Each candidate keeps its own API host and credentials: credentials of one host are
/// never sent to another.
enum DrainEngineScanner {
    /// At most this many drain-only engines start per launch.
    static let limit = 3

    /// Candidates other than `excludedFolder`, in a stable order.
    static func candidates(files: FileStore, keychain: KeychainStore, excludedFolder: String) -> [EngineConfig] {
        var found: [EngineConfig] = []
        for appId in files.folders(in: "") where Validation.isAppId(appId) {
            for hostTag in files.folders(in: appId) where hostTag.count == 8 && Validation.isLowerHex(hostTag) {
                let folder = "\(appId)/\(hostTag)"
                guard folder != excludedFolder,
                      case let .data(data) = files.read(folder + "/identity.json"),
                      let identity = StoredJSON.decode(IdentityState.self, from: data),
                      identity.appId == appId,
                      identity.ops.contains(where: { $0.kind != .login }),
                      let base = APIBase.validated(URL(string: identity.apiBaseURL)),
                      base.hostTag == hostTag,
                      case .found = keychain.read(account: KeychainStore.credentialsAccount(appId: appId, hostTag: hostTag))
                else { continue }
                found.append(EngineConfig(appId: appId, base: base, appGroupIdentifier: nil, apnsOverride: .automatic,
                                          appVersionOverride: nil, autoClearBadge: false, autoUpdateBadge: false,
                                          clearTagsOnLogout: true, registerOnInit: false, openLaunchURLs: false,
                                          logFullIdentifiers: false))
                if found.count == limit { return found }
            }
        }
        return found
    }
}

/// Drain mode: an engine that is no longer the current one finishes its pending logouts, then stops.
extension Engine {
    /// After an app id or host switch: only pending logout, unlink and logout confirmation ops run; the engine stops
    /// when they are done or after 60 s. Its persisted state stays.
    func enterDrainMode() {
        guard phase != .stopped, !isDraining else { return }
        isDraining = true
        cancelTimer(.tokenMissing)
        cancelTimer(.delegateCheck)
        schedule(.drainDeadline, after: Self.drainDeadline) { engine in engine.stop() }
        if phase == .running {
            finishDrainIfDone()
        }
    }

    /// Stops once nothing is in flight and no logout is pending. A consent withdrawal under way is carried on first:
    /// the app switched away while it waited to retry.
    func finishDrainIfDone() {
        guard mode == .drainOnly || isDraining, phase == .running, inFlight == nil, consentMode != .withdrawing else { return }
        if credentials == nil || !identity.ops.contains(where: { $0.kind != .login }) {
            stop()
        }
    }

    /// The app initialized this engine's app id and host again while it drained: it stops as soon as nothing is in
    /// flight (the answer of a request on the wire is applied and written first), and the new main engine, started
    /// after that, continues from the same files, pending logouts included. Two engines never share a folder.
    func handOver() {
        guard phase != .stopped else { return }
        isHandingOver = true
        if phase != .running || inFlight == nil {
            stop()
        }
    }
}
