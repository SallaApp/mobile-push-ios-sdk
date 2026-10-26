import Foundation
import SallaPushCore

extension Engine {
    /// A registration answer is a new device row: it has no link and no tags, and push-service reports neither. A
    /// queued logout has nothing left to do there, and neither has a tag clearing; a link sent on the previous row no
    /// longer matters. The asserted customer is linked again with the identity token in memory (without one, the app's
    /// next `login` call links them), and the tags SallaPush holds are sent again, after that link.
    func afterRegistration(now: Double) {
        identity.serverLink = .none
        identity.linkedExternalId = nil
        identity.serverTags = .none
        identityDirty = true
        unknownOutcomeLogin = false
        var settled = 0
        for op in identity.ops {
            switch op.kind {
            case .logout, .logoutConfirm:
                removeIdentityOp(id: op.id)
                settled += 1
            case .login:
                updateIdentityOp(id: op.id) { login in
                    login.sent = false
                    if login.clearsTagsNext {
                        login.tagsCleared = true
                        login.tagKeys = []
                    }
                }
            }
        }
        if settled > 0 {
            logger.log(.logoutSkipped, "This device is registered without a link or tags to clear; the queued logout "
                           + "needs no request.")
        }
        // While consent is withheld nothing is sent on the app's behalf; consent given again links the customer.
        guard consentMode == .normal else { return }
        relinkAfterRegistration(now: now)
        requeueTagMirror(now: now)
        state.tags.pendingRemove = [:]
        stateDirty = true
        scheduleTagsFlush(now: now)
    }

    /// Links the asserted customer to the new row with the identity token in memory; without one, the app's next `login`
    /// call does.
    private func relinkAfterRegistration(now: Double) {
        guard identity.desired == .customer else { return }
        if let externalId = identity.desiredExternalId, loginOp(for: externalId) != nil { return }
        guard let externalId = identity.desiredExternalId, identityToken(for: externalId) != nil else {
            logTokenNeeded()
            return
        }
        enqueueLogin(externalId: externalId, clearTags: false, tagKeys: [], now: now)
    }
}
