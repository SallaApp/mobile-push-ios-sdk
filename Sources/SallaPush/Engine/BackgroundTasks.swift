import Foundation
import SallaPushCore

/// A background task that is ended exactly once: by the engine when idle, or by the system's expiration path.
final class BackgroundTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: Int?
    private var finished = false
    private var endRequested = false
    private let application: ApplicationClient

    init(application: ApplicationClient) {
        self.application = application
    }

    /// The task started; ends it at once when the engine already asked to end it.
    func attach(_ identifier: Int) {
        lock.lock()
        self.identifier = identifier
        let endNow = endRequested && !finished
        if endNow { finished = true }
        lock.unlock()
        if endNow { application.endBackgroundTask(identifier) }
    }

    /// Ends the task (any thread). Later calls do nothing.
    func end() {
        lock.lock()
        let target = finished ? nil : identifier
        if target != nil { finished = true }
        if identifier == nil { endRequested = true }
        lock.unlock()
        if let target { application.endBackgroundTask(target) }
    }

    /// The system expired the task and the client already ended it.
    func expired() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// The background task that lets pending work finish after the app leaves the foreground.
extension Engine {
    /// Starts the background task (main engine only); when the system expires it, the work in flight is saved for the
    /// next launch.
    func beginBackgroundTask() {
        guard backgroundTaskToken == nil, mode == .main else { return }
        let token = BackgroundTaskToken(application: env.application)
        backgroundTaskToken = token
        let expectedGeneration = generation
        let engine = WeakEngine(self)
        env.application.beginBackgroundTask(name: "SallaPush.flush", expiration: {
            token.expired()
            guard let current = engine.value else { return }
            current.queue.async {
                guard current.phase != .stopped, current.generation == expectedGeneration else { return }
                current.backgroundExpired(token)
            }
        }, started: { identifier in
            if let identifier {
                token.attach(identifier)
            } else {
                token.expired()
            }
        })
    }

    private func backgroundExpired(_ token: BackgroundTaskToken) {
        guard backgroundTaskToken === token else { return }
        backgroundTaskToken = nil
        if let current = inFlight {
            current.handle?.cancel()
            inFlight = nil
            applyTransientFailure(APIError(kind: .cancelled, route: route(of: current.kind), detail: "background time expired"),
                                  to: current.kind, now: env.clock.now())
        }
        persist()
        logger.log(.lifecycleBackgroundExpired,
                   "Background time expired; pending work was saved and resumes on the next launch.")
        logStatusIfChanged()
    }

    func endBackgroundTask() {
        backgroundTaskToken?.end()
        backgroundTaskToken = nil
    }

    /// Ends the background task once nothing is in flight and nothing is ready to send.
    func endBackgroundTaskIfIdle() {
        guard backgroundTaskToken != nil, inFlight == nil else { return }
        endBackgroundTask()
    }
}
