import Foundation

enum LocalLockAction: String, Codable, CaseIterable, Identifiable {
    case lockScreen, screenSaver
    var id: String { rawValue }
    var title: String { self == .lockScreen ? "锁定屏幕" : "启动屏幕保护程序" }
    var requestMessage: String {
        self == .lockScreen
            ? "已提交系统锁屏快捷键请求；系统是否已锁定尚未确认。"
            : "已提交屏保启动请求；屏保不等于锁定屏幕，是否要求密码由系统设置决定。"
    }
}

/// Persist this inside the existing guarded settings document. No credentials,
/// trusted-device records, old countdowns or session assertions are persisted.
struct LocalLockConfiguration: Codable, Equatable {
    var schema = 1
    var enabled = false
    var idleSeconds: Double = 300
    var warningSeconds: Double = 15
    var action: LocalLockAction = .lockScreen

    init() {}
    private enum CodingKeys: String, CodingKey { case schema, enabled, idleSeconds, warningSeconds, action }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        idleSeconds = try values.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? 300
        warningSeconds = try values.decodeIfPresent(Double.self, forKey: .warningSeconds) ?? 15
        action = try values.decodeIfPresent(LocalLockAction.self, forKey: .action) ?? .lockScreen
        try validate()
    }

    func validate() throws {
        guard schema == 1 else { throw LocalLockError.message("闲置策略格式过新或无效，已停止执行并保留原配置。") }
        guard idleSeconds.isFinite, (30...86_400).contains(idleSeconds),
              warningSeconds.isFinite, (5...120).contains(warningSeconds) else {
            throw LocalLockError.message("闲置时限须为 30 秒至 24 小时，执行前提醒须为 5 至 120 秒。")
        }
    }
}

enum LocalLockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum LocalLockState: Equatable {
    case disabled, observing, countdown(Int), paused(String), waitingForActivity, failed(String)

    var title: String {
        switch self {
        case .disabled: return "自动闲置策略已关闭"
        case .observing: return "正在观察本机闲置"
        case .countdown(let seconds): return "将在 \(seconds) 秒后执行"
        case .paused: return "已安全暂停"
        case .waitingForActivity: return "已请求，等待新的本机活动"
        case .failed: return "执行失败，已暂停"
        }
    }
    var detail: String {
        switch self {
        case .disabled: return "手动锁屏和手动屏保仍可按需使用。"
        case .observing: return "达到闲置时限后先提醒；键鼠活动、任务忙碌或会话变化会取消本次倒计时。"
        case .countdown: return "移动鼠标、按键或取消均会停止本次倒计时。"
        case .paused(let reason), .failed(let reason): return reason
        case .waitingForActivity: return "请求不代表锁定结果已确认；不会在同一闲置周期重复执行，也不会自动解锁。"
        }
    }
    var remainingSeconds: Int? { if case .countdown(let seconds) = self { return seconds }; return nil }
}

struct LocalLockEvent: Identifiable, Equatable {
    enum Kind: String { case configuration, countdown, cancelled, paused, resumed, requested, failed, system }
    let id = UUID()
    let date: Date
    let kind: Kind
    let message: String
    let action: LocalLockAction?
}

/// Pure, injected policy. This type imports no GUI, event-posting, hardware or
/// permission APIs. The caller serializes access (the app uses the main actor).
/// Tests use an injected monotonic clock and an action closure that only records.
@MainActor final class LocalLockPolicy {
    private(set) var configuration: LocalLockConfiguration
    private(set) var state: LocalLockState = .disabled
    private let now: () -> Double
    private let idleSeconds: () -> Double
    private let safetyReason: (LocalLockAction) -> String?
    private let perform: (LocalLockAction) throws -> Void
    private let event: (LocalLockEvent) -> Void
    private let date: () -> Date
    private var resetAt: Double?
    private var lastPollAt: Double?
    private var lastActivityAt: Double?
    private var deadline: Double?
    private var explicitPause: String?
    private var failure: String?
    private var needsActivity = false
    private var inputSettlingUntil: Double?
    private var awaitingPostRequestBaseline = false
    private var executing = false
    private var revision: UInt64 = 0

    init(configuration: LocalLockConfiguration = .init(), now: @escaping () -> Double,
         idleSeconds: @escaping () -> Double, safetyReason: @escaping (LocalLockAction) -> String? = { _ in nil },
         perform: @escaping (LocalLockAction) throws -> Void, date: @escaping () -> Date = Date.init,
         event: @escaping (LocalLockEvent) -> Void = { _ in }) {
        self.configuration = configuration
        self.now = now; self.idleSeconds = idleSeconds; self.safetyReason = safetyReason
        self.perform = perform; self.date = date; self.event = event
        do { try configuration.validate(); state = configuration.enabled ? .observing : .disabled }
        catch { failure = error.localizedDescription; state = .failed(error.localizedDescription) }
    }

    func updateConfiguration(_ value: LocalLockConfiguration) throws {
        try value.validate()
        guard configuration != value else { return }
        configuration = value
        failure = nil; explicitPause = nil
        resetObservation(at: now())
        state = value.enabled ? .observing : .disabled
        emit(.configuration, value.enabled ? "本机闲置策略已开启，将从新的完整闲置周期开始观察。" : "本机闲置策略已关闭，待执行请求已取消。")
    }

    func cancelPending() {
        let hadCountdown = deadline != nil
        resetObservation(at: now())
        state = currentRestingState
        if hadCountdown { emit(.cancelled, "本次闲置倒计时已取消；如继续启用，将重新等待完整闲置时限。") }
    }

    func pauseForSafety(_ reason: String) {
        let reason = reason.isEmpty ? "已暂停，请确认安全后恢复。" : reason
        let changed = explicitPause != reason || deadline != nil
        explicitPause = reason
        resetObservation(at: now())
        state = configuration.enabled ? .paused(reason) : .disabled
        if changed { emit(.paused, reason) }
    }

    func resume() {
        explicitPause = nil; failure = nil
        resetObservation(at: now())
        state = configuration.enabled ? .observing : .disabled
        emit(.resumed, "已清除暂停并重新观察；不会恢复旧倒计时或自动解锁。")
    }

    /// Sleep, session activation and display events are observations only. They
    /// never establish that the screen is locked or that a user authenticated.
    func recordSystemEvent(_ message: String) {
        resetObservation(at: now(), preserveRequestLatch: true)
        state = currentRestingState
        emit(.system, message)
    }

    func tick() {
        guard !executing else { return }
        guard configuration.enabled else { state = .disabled; return }
        if let failure { state = .failed(failure); return }
        if let explicitPause { state = .paused(explicitPause); return }
        let time = now(), idle = idleSeconds()
        guard valid(time: time, idle: idle) else { fail("本机闲置时刻无法可靠读取，已暂停。请确认后恢复。"); return }
        if let previous = lastPollAt, time < previous {
            fail("单调时钟出现倒退，已取消倒计时。请确认后恢复。"); return
        }
        // A blocked run loop must not dispatch an expired countdown immediately
        // on return. Start a new observation window after a long sampling gap.
        if let previous = lastPollAt, time - previous > 5 {
            let hadCountdown = deadline != nil
            resetObservation(at: time, preserveRequestLatch: true)
            if hadCountdown {
                state = .observing
                emit(.cancelled, "闲置采样出现长间隔，已取消过期倒计时并重新观察。")
                return
            }
        }
        lastPollAt = time
        let activity = time - idle
        // Event posting itself can update the session idle clock. Establish a
        // post-request baseline and ignore activity occurring during the short
        // posting interval, so our own synthetic Q cannot rearm the same cycle.
        let canRearmFromActivity = !needsActivity ||
            (!awaitingPostRequestBaseline && activity > (inputSettlingUntil ?? -.infinity))
        if let previous = lastActivityAt, activity > previous + 0.25, canRearmFromActivity {
            let hadCountdown = deadline != nil
            resetObservation(at: time)
            lastPollAt = time
            if hadCountdown { emit(.cancelled, "检测到新的本机输入，本次闲置倒计时已取消。") }
        }
        lastActivityAt = activity
        awaitingPostRequestBaseline = false
        if resetAt == nil { resetAt = time }
        if let reason = safetyReason(configuration.action) {
            let changed = state != .paused(reason)
            resetObservation(at: time, preserveRequestLatch: true)
            lastPollAt = time; lastActivityAt = activity
            state = .paused(reason)
            if changed { emit(.paused, reason) }
            return
        }
        if case .paused = state {
            resetObservation(at: time, preserveRequestLatch: true)
            lastPollAt = time; lastActivityAt = activity
            emit(.resumed, "阻碍已解除，重新等待完整闲置时限。")
        }
        guard !needsActivity else { state = .waitingForActivity; return }
        let observedIdle = min(idle, max(0, time - (resetAt ?? time)))
        guard observedIdle >= configuration.idleSeconds else {
            deadline = nil; state = .observing; return
        }
        guard let deadline else {
            self.deadline = time + configuration.warningSeconds
            state = .countdown(Int(ceil(configuration.warningSeconds)))
            emit(.countdown, "闲置达到时限，将在 \(Int(ceil(configuration.warningSeconds))) 秒后\(configuration.action.title)。可用键鼠活动或取消停止。", action: configuration.action)
            return
        }
        if time < deadline { state = .countdown(max(1, Int(ceil(deadline - time)))); return }
        do { try execute(configuration.action, automatic: true) }
        catch { /* execute audits and pauses on the applicable failure or blocker. */ }
    }

    /// Manual actions remain available while the automatic policy is disabled.
    /// They still respect actual task/session/input safety and reject reentry.
    func requestNow(_ action: LocalLockAction = .lockScreen) throws {
        try execute(action, automatic: false)
    }

    private func execute(_ action: LocalLockAction, automatic: Bool) throws {
        guard !executing else { throw LocalLockError.message("锁屏或屏保请求正在提交，请勿重复执行。") }
        if let reason = safetyReason(action) {
            if automatic {
                resetObservation(preserveRequestLatch: true); state = .paused(reason)
            }
            emit(.paused, reason)
            throw LocalLockError.message(reason)
        }
        if automatic {
            guard configuration.enabled, explicitPause == nil, failure == nil else { return }
            // Re-read idle immediately before dispatch, including changes made
            // while safety/session checks ran. Any new input cancels the action.
            let time = now(), idle = idleSeconds()
            guard valid(time: time, idle: idle), let deadline, time >= deadline,
                  min(idle, max(0, time - (resetAt ?? time))) >= configuration.idleSeconds,
                  lastActivityAt.map({ time - idle <= $0 + 0.25 }) ?? false else {
                cancelPending(); return
            }
        }
        executing = true
        defer { executing = false }
        deadline = nil; needsActivity = true
        let operationRevision = revision
        do {
            try perform(action)
            // An injected callback can change/disable the policy. Never restore
            // a pre-cancellation state after such a callback returns.
            if revision == operationRevision {
                inputSettlingUntil = now() + 2
                awaitingPostRequestBaseline = true
                state = configuration.enabled ? .waitingForActivity : .disabled
            }
            emit(.requested, action.requestMessage, action: action)
        } catch {
            fail("\(action.title)请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    private var currentRestingState: LocalLockState {
        if !configuration.enabled { return .disabled }
        if let failure { return .failed(failure) }
        if let explicitPause { return .paused(explicitPause) }
        return .observing
    }
    private func valid(time: Double, idle: Double) -> Bool {
        time.isFinite && time >= 0 && idle.isFinite && idle >= 0 && idle <= time + 1
    }
    private func resetObservation(at time: Double? = nil, preserveRequestLatch: Bool = false) {
        let latch = needsActivity, activity = lastActivityAt
        let settlingUntil = inputSettlingUntil, awaitingBaseline = awaitingPostRequestBaseline
        revision &+= 1
        resetAt = time; lastPollAt = nil; lastActivityAt = nil
        deadline = nil; needsActivity = false
        inputSettlingUntil = nil; awaitingPostRequestBaseline = false
        if preserveRequestLatch {
            needsActivity = latch; lastActivityAt = activity
            inputSettlingUntil = settlingUntil; awaitingPostRequestBaseline = awaitingBaseline
        }
    }
    private func fail(_ message: String) {
        failure = message; resetObservation(); state = .failed(message)
        emit(.failed, message)
    }
    private func emit(_ kind: LocalLockEvent.Kind, _ message: String, action: LocalLockAction? = nil) {
        event(LocalLockEvent(date: date(), kind: kind, message: message, action: action))
    }
}
