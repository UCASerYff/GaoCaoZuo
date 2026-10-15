import ApplicationServices
import Foundation

enum CleanerRescuePolicy {
    // Synthetic application-originated events cannot serve as a rescue rehearsal.
    // This is an event-channel check, not authentication against malicious peers.
    static func canVerify(sourcePID:Int64,repeated:Bool)->Bool {sourcePID == 0 && !repeated}
}

/// The existing input tap is the only interceptor. This independent lease may
/// disable it from a watchdog queue if the main run loop stops making progress.
final class CleanerInputSafety: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var activeTap = false
    private var deadline: TimeInterval?
    private var heartbeat: TimeInterval = 0
    private var failed = false
    private var testHealth: (() -> Bool)?
    private var testRelease: (() -> Void)?

    init() {}
    init(health: @escaping () -> Bool, release: @escaping () -> Void) {
        testHealth = health; testRelease = release
    }
    func bind(_ tap: CFMachPort?, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if deadline != nil { tripLocked() }
        self.tap = tap; activeTap = active
    }
    private func healthyLocked() -> Bool {
        if let testHealth { return testHealth() }
        guard activeTap, let tap, CFMachPortIsValid(tap) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    var healthy: Bool { lock.lock(); defer { lock.unlock() }; return healthyLocked() }
    func begin(now: TimeInterval, duration: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, duration.isFinite, duration >= 30, duration <= 180, healthyLocked() else { return false }
        deadline = now + duration; heartbeat = now; failed = false
        return true
    }
    func pulse(now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if deadline != nil, !failed { heartbeat = now }
    }
    func permitsInterception(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let deadline, !failed else { return false }
        guard now < deadline, now >= heartbeat, now - heartbeat <= 1,
              healthyLocked() else { tripLocked(); return false }
        return true
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        deadline = nil; failed = false
    }
    private func tripLocked() {
        failed = true; deadline = nil
        if let testRelease { testRelease() }
        else if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
    }
}
