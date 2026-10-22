import Foundation

/// The timer checks the lease without requiring the main actor to make progress.
/// Cancellation waits for any in-flight check, so an old timer cannot inspect a
/// new lease on the same CleanerInputSafety instance.
private final class CleanerLeaseWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let safety: CleanerInputSafety
    private let clock: () -> TimeInterval
    private let onReady: (Bool) -> Void
    private let onFailure: () -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceTimer?
    private var stopped = false
    private var readySent = false

    init(safety: CleanerInputSafety, queue: DispatchQueue,
         clock: @escaping () -> TimeInterval,
         onReady: @escaping (Bool) -> Void, onFailure: @escaping () -> Void) {
        self.safety = safety; self.queue = queue; self.clock = clock
        self.onReady = onReady; self.onFailure = onFailure
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, source == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.checkLease() }
        source = timer
        timer.resume()
    }
    private func checkLease() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let permitted = safety.permitsInterception(now: clock())
        let firstCheck = !readySent
        readySent = true
        if !permitted {
            stopped = true; source?.cancel(); source = nil
        }
        lock.unlock()
        if firstCheck { onReady(permitted) }
        else if !permitted { onFailure() }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; source?.cancel(); source = nil
    }
    deinit { cancel() }
}

/// Owns one cleaner startup/active lease. Window construction stays on the main
/// actor; permission and physical rescue checks remain the controller's job.
@MainActor final class CleanerWatchdogSession {
    private struct Session {
        let token: UUID
        let watchdog: CleanerLeaseWatchdog
        let canPresent: () -> Bool
        let present: () -> Void
        let failed: () -> Void
    }
    private let safety: CleanerInputSafety
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private var session: Session?
    var currentToken: UUID? { session?.token }
    var isRunning: Bool { session != nil }

    init(safety: CleanerInputSafety,
         queue: DispatchQueue = DispatchQueue(label: "com.gaoseries.GaoCaoZuo.cleaner-watchdog", qos: .userInteractive),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.safety = safety; self.queue = queue; self.clock = clock
    }
    @discardableResult
    func start(now: TimeInterval, duration: TimeInterval,
               canPresent: @escaping () -> Bool, present: @escaping () -> Void,
               failed: @escaping () -> Void) -> Bool {
        guard session == nil, safety.begin(now: now, duration: duration) else { return false }
        let token = UUID()
        let watchdog = CleanerLeaseWatchdog(safety: safety, queue: queue, clock: clock,
            onReady: { [weak self] healthy in
                Task { @MainActor [weak self] in self?.ready(token: token, healthy: healthy) }
            }, onFailure: { [weak self] in
                Task { @MainActor [weak self] in self?.fail(token: token) }
            })
        session = Session(token: token, watchdog: watchdog, canPresent: canPresent,
                          present: present, failed: failed)
        watchdog.start()
        return true
    }
    private func ready(token: UUID, healthy: Bool) {
        guard let current = session, current.token == token else { return }
        guard healthy, current.canPresent(), session?.token == token,
              safety.permitsInterception(now: clock()), session?.token == token else {
            fail(token: token); return
        }
        // The real background handler has already run before any overlay work.
        current.present()
        guard session?.token == token else { return }
        // The overlay factory may have blocked while the watchdog released the
        // tap. Never leave that expired startup presented as a healthy session.
        if !safety.permitsInterception(now: clock()) { fail(token: token) }
    }
    private func fail(token: UUID) {
        guard let current = session, current.token == token else { return }
        session = nil
        current.watchdog.cancel()
        safety.finish()
        current.failed()
    }
    func cancel() {
        let old = session; session = nil
        old?.watchdog.cancel()
        safety.finish()
    }
}
