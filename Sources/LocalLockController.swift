import AppKit
import ApplicationServices
import Carbon
import Combine
import Darwin

/// Official sources checked 2026-11-02:
/// https://support.apple.com/en-us/102650 (Control-Command-Q locks the screen)
/// https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
/// https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)
/// https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification
/// https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
/// The public CoreGraphics SDK CGSession.h describes the console/login/user
/// dictionary keys used below. No undocumented screen-lock state key is read.
@MainActor enum LocalLockSystemActions {
    static func safetyReason(for action: LocalLockAction) -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid() else {
            return "当前不是已确认的本人本机控制台会话，已暂停锁屏和屏保请求。"
        }
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return "当前会话主显示器正在睡眠，已暂停执行。" }
        if action == .lockScreen {
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                return "锁屏需要已授予的辅助功能／事件发送权限；请在权限页按需授权后恢复。"
            }
            guard !IsSecureEventInputEnabled() else { return "系统处于安全输入状态，已暂停提交锁屏快捷键。" }
        }
        return nil
    }

    /// This is a real request through the app's existing public input APIs,
    /// rather than a fake presence state, a private lock symbol or a black overlay.
    /// CGEvent.post has no success acknowledgement for system session locking.
    static func perform(_ action: LocalLockAction) throws {
        if let reason = safetyReason(for: action) { throw LocalLockError.message(reason) }
        switch action {
        case .lockScreen: try SystemActions.perform(id: "system.lock")
        case .screenSaver: try EnhancedSystemControls.perform(.screenSaver)
        }
    }
}

@MainActor final class LocalLockController: ObservableObject {
    @Published private(set) var state: LocalLockState = .disabled
    @Published private(set) var events: [LocalLockEvent] = []
    var busyReason: () -> String?
    var onEvent: (LocalLockEvent) -> Void
    var configuration: LocalLockConfiguration { policy.configuration }
    private var policy: LocalLockPolicy!
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var started = false
    private var sleeping = false
    private var displaysSleeping = false
    private var inactiveSession = false

    init(configuration: LocalLockConfiguration = .init(), busyReason: @escaping () -> String? = { nil },
         event: @escaping (LocalLockEvent) -> Void = { _ in }) {
        self.busyReason = busyReason; self.onEvent = event
        policy = LocalLockPolicy(configuration: configuration,
            now: { ProcessInfo.processInfo.systemUptime },
            // kCGAnyInputEventType is UINT32_MAX in the public CGEventTypes.h.
            // .null is a different event type and is not a keyboard/mouse idle clock.
            idleSeconds: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) },
            safetyReason: { [weak self] action in
                guard let self else { return "闲置策略已停止。" }
                if let reason = self.busyReason() { return reason }
                if self.sleeping { return "系统正在睡眠，已暂停闲置策略。" }
                if self.displaysSleeping { return "显示器正在睡眠，已暂停闲置策略。" }
                if self.inactiveSession { return "当前用户会话不在前台，已暂停闲置策略。" }
                return LocalLockSystemActions.safetyReason(for: action)
            }, perform: LocalLockSystemActions.perform,
            event: { [weak self] value in self?.record(value) })
        state = policy.state
    }

    func updateConfiguration(_ configuration: LocalLockConfiguration) throws {
        try policy.updateConfiguration(configuration)
        state = policy.state
        refreshTimer()
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.willSleepNotification) { value in
            value.sleeping = true
            value.systemEvent("系统即将睡眠，旧闲置倒计时已取消；这不是锁屏结果确认。")
        }
        observe(center, NSWorkspace.didWakeNotification) { value in
            value.sleeping = false
            value.systemEvent("系统已唤醒，从新的完整闲置周期开始观察；不会自动解锁。")
        }
        observe(center, NSWorkspace.screensDidSleepNotification) { value in
            value.displaysSleeping = true
            value.systemEvent("显示器已睡眠，旧倒计时已取消；黑屏不能作为锁定证明。")
        }
        observe(center, NSWorkspace.screensDidWakeNotification) { value in
            value.displaysSleeping = false
            value.systemEvent("显示器已唤醒，重新观察闲置；未读取或确认系统锁定状态。")
        }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { value in
            value.inactiveSession = true
            value.systemEvent("当前用户会话已离开前台，已取消旧闲置倒计时。")
        }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { value in
            value.inactiveSession = false
            value.systemEvent("当前用户会话已回到前台，重新观察；该通知不作为本人认证证明。")
        }
        policy.recordSystemEvent("本机闲置监测已启动；不会恢复上次运行的倒计时。")
        refreshTimer()
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observations.forEach { center.removeObserver($0) }; observations.removeAll()
        policy.pauseForSafety("闲置监测已停止，请明确恢复后继续。")
        state = policy.state
    }

    func requestNow(_ action: LocalLockAction = .lockScreen) throws {
        defer { state = policy.state }
        try policy.requestNow(action)
    }
    func cancelPending() { policy.cancelPending(); state = policy.state }
    func pauseForSafety(_ reason: String) { policy.pauseForSafety(reason); state = policy.state }
    func resume() { policy.resume(); state = policy.state }

    private func refreshTimer() {
        timer?.invalidate(); timer = nil
        guard started, configuration.enabled else { state = policy.state; return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }
    private func poll() {
        guard started else { return }
        policy.tick(); state = policy.state
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         handle: @escaping @MainActor (LocalLockController) -> Void) {
        observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.started { handle(self) } }
        })
    }
    private func systemEvent(_ message: String) {
        policy.recordSystemEvent(message)
        poll(); state = policy.state
    }
    private func record(_ value: LocalLockEvent) {
        events.append(value)
        if events.count > 80 { events.removeFirst(events.count - 80) }
        onEvent(value)
    }
}
