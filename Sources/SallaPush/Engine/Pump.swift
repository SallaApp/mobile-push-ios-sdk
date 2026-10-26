import Foundation
import SallaPushCore

/// The pump: the one place that picks the next request, by its selection rule, and arms the wake-up for the next
/// ready operation.
extension Engine {
    /// Sends the next ready operation, by this selection rule: register gates device operations; then
    /// identity operations (strict FIFO), update, tags (never while an identity operation is pending), events.
    /// An operation in backoff does not block other categories.
    func pump() {
        // Each pass either starts a request, waits, or removes work, so the number of passes is bounded.
        var passes = 0
        while passes < 16, pumpOnce() == .again {
            passes += 1
        }
    }

    private enum PumpResult {
        case done
        case again
    }

    private func pumpOnce() -> PumpResult {
        guard phase == .running, inFlight == nil else { return .done }
        if isHandingOver {
            // Nothing is in flight any more: the new main engine of this folder continues from the files.
            stop()
            return .done
        }
        let now = env.clock.now()
        switch consentMode {
        case .paused:
            return .done
        case .withdrawing:
            pumpWithdrawal(now: now)
            return .done
        case .normal:
            break
        }
        guard storageAvailable else { return .done }
        clearExpiredDormancy(now: now)
        let workBefore = pendingWorkCount
        if credentials == nil {
            return pumpUnregistered(now: now, workBefore: workBefore)
        }
        if deviceRoutesDormant(now: now) {
            waitForNextWork(now: now)
            return .done
        }
        if let op = nextIdentityOp(), isReady(op.retry, id: op.id, now: now) {
            sendIdentity(op, now: now)
            if let next = outcome(after: workBefore) { return next }
        }
        if mode == .drainOnly || isDraining {
            finishDrainIfDone()
            if phase == .running { scheduleWake(now: now) }
            return .done
        }
        if let next = pumpDeviceRoutes(now: now, workBefore: workBefore) {
            return next
        }
        waitForNextWork(now: now)
        return .done
    }

    /// Before registration only the register request can go.
    private func pumpUnregistered(now: Double, workBefore: Int) -> PumpResult {
        if mode == .main, !isDraining, canRegister(now: now),
           let op = stateOp(.register), isReady(op.retry, id: op.id, now: now) {
            sendRegister(now: now)
            if let next = outcome(after: workBefore) { return next }
        }
        finishDrainIfDone()
        waitForNextWork(now: now)
        return .done
    }

    /// Update and tags (once no identity operation is pending) wait for the first foreground of a background launch;
    /// events go.
    private func pumpDeviceRoutes(now: Double, workBefore: Int) -> PumpResult? {
        if !isBackgroundLaunch, let op = stateOp(.update), isReady(op.retry, id: op.id, now: now) {
            sendUpdate(now: now)
            if let next = outcome(after: workBefore) { return next }
        }
        if !isBackgroundLaunch, identity.ops.isEmpty, let op = stateOp(.tags), isReady(op.retry, id: op.id, now: now) {
            if state.tags.hasPendingChanges {
                sendTags(now: now)
            } else {
                // A tags op kept for its wait after a failure: the wait is over and nothing is left to send.
                dropIdleTagsOp(now: now)
            }
            if let next = outcome(after: workBefore) { return next }
        }
        if eventsReady(now: now) {
            sendEvents(now: now)
            if let next = outcome(after: workBefore) { return next }
        }
        return nil
    }

    /// After a send: done while its request is in flight, again when it removed work without a request (the next
    /// operation may go now), nil when nothing changed.
    private func outcome(after workBefore: Int) -> PumpResult? {
        if inFlight != nil { return .done }
        if pendingWorkCount < workBefore { return .again }
        return nil
    }

    /// Nothing can go now: wake up when something becomes ready and let a background task end.
    private func waitForNextWork(now: Double) {
        scheduleWake(now: now)
        endBackgroundTaskIfIdle()
    }

    /// Operations and events still waiting; a send that removed work without starting a request lets the pump
    /// select again.
    private var pendingWorkCount: Int {
        identity.ops.count + state.ops.count + events.pending.count + (state.tags.hasPendingChanges ? 1 : 0)
    }

    /// The identity operation that may go next: the head of the log, or in drain mode the first logout-like one.
    func nextIdentityOp() -> IdentityOp? {
        if mode == .drainOnly || isDraining {
            return identity.ops.first { $0.kind != .login }
        }
        return identity.ops.first
    }

    func isReady(_ retry: RetryState, id: Int, now: Double) -> Bool {
        retry.nextAt <= now && (retry.dormantUntil ?? 0) <= now && !exhausted.contains(id)
    }

    /// Device routes answered `404 not_found` (SDK routes closed): everything waits, identity included.
    func deviceRoutesDormant(now: Double) -> Bool {
        state.registration.status == .dormant && state.registration.dormantReason == .notFound
            && (state.registration.dormantUntil ?? 0) > now
    }

    /// Schedules the pump at the earliest time an operation becomes ready.
    func scheduleWake(now: Double) {
        var earliest = Double.infinity
        func consider(_ retry: RetryState, id: Int) {
            guard !exhausted.contains(id) else { return }
            let time = max(retry.nextAt, retry.dormantUntil ?? 0)
            if time > now { earliest = min(earliest, time) }
        }
        if let until = state.registration.dormantUntil, until > now { earliest = min(earliest, until) }
        if let op = nextIdentityOp() { consider(op.retry, id: op.id) }
        for op in state.ops where !(isBackgroundLaunch && (op.kind == .update || op.kind == .tags)) {
            consider(op.retry, id: op.id)
        }
        if !events.pending.isEmpty {
            consider(eventsRetry, id: eventsRetryId)
            if let first = firstPendingEventAt, first + Self.eventsDebounce > now {
                earliest = min(earliest, first + Self.eventsDebounce)
            }
        }
        if !withdrawalSteps.isEmpty { consider(withdrawalRetry, id: Self.withdrawalRetryId) }
        if earliest.isFinite {
            armWake(at: earliest, now: now)
        } else {
            cancelTimer(.pump)
        }
    }

    /// Arms the pump wake-up for `time`, unless one is armed for that time or earlier (it then fires first and arms the
    /// next). Re-arming on every pass would leave each cancelled item alive inside libdispatch until its deadline, up
    /// to a day while dormant.
    private func armWake(at time: Double, now: Double) {
        if let armed = armedWakeAt, timers[.pump] != nil, armed <= time { return }
        armedWakeAt = time
        schedule(.pump, after: time - now) { _ in }
    }
}
