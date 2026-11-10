import Foundation

@MainActor private final class LocalLockFixture {
    var time: Double = 1_000
    var lastInput: Double = 1_000
    var idleOverride: Double?
    var blocked: String?
    var failure: Error?
    var idleReads = 0
    var safetyReads = 0
    var actions: [LocalLockAction] = []
    var events: [LocalLockEvent] = []
    var onSafety: (() -> Void)?
    var onPerform: (() throws -> Void)?
    var onEvent: ((LocalLockEvent) -> Void)?
    var policy: LocalLockPolicy!

    init(enabled: Bool = true, action: LocalLockAction = .lockScreen) {
        var config = LocalLockConfiguration()
        config.enabled = enabled; config.idleSeconds = 30; config.warningSeconds = 5; config.action = action
        policy = LocalLockPolicy(configuration: config, now: { [unowned self] in self.time },
            idleSeconds: { [unowned self] in self.idleReads += 1; return self.idleOverride ?? (self.time - self.lastInput) },
            safetyReason: { [unowned self] _ in self.safetyReads += 1; self.onSafety?(); return self.blocked },
            perform: { [unowned self] action in
                if let failure = self.failure { throw failure }
                self.actions.append(action)
                try self.onPerform?()
            }, date: { [unowned self] in Date(timeIntervalSince1970: self.time) },
            event: { [unowned self] value in self.events.append(value); self.onEvent?(value) })
        policy.tick()
    }
    func advance(_ seconds: Int) {
        for _ in 0..<seconds { time += 1; policy.tick() }
    }
    func input() { lastInput = time; policy.tick() }
}

@MainActor func runLocalLockPolicyTests() throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw LocalLockError.message("本机闲置策略：" + message) }
    }
    func rejected(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
    let defaults = LocalLockConfiguration()
    try check(!defaults.enabled && defaults.idleSeconds == 300 && defaults.warningSeconds == 15, "全新配置默认关闭")
    let decoded = try JSONDecoder().decode(LocalLockConfiguration.self, from: Data("{}".utf8))
    try check(decoded == defaults, "旧配置缺少整个策略时安全补默认值")
    let roundTrip = try JSONDecoder().decode(LocalLockConfiguration.self, from: JSONEncoder().encode(defaults))
    try check(roundTrip == defaults, "策略配置可无损编码与读取")
    for json in ["{\"schema\":2}", "{\"idleSeconds\":29}", "{\"idleSeconds\":86401}", "{\"warningSeconds\":0}", "{\"action\":\"unlock\"}", "{\"enabled\":\"yes\"}"] {
        try check(rejected { _ = try JSONDecoder().decode(LocalLockConfiguration.self, from: Data(json.utf8)) }, "损坏、未知、危险策略拒绝而非空白覆盖：\(json)")
    }
    var invalid = defaults; invalid.idleSeconds = .nan
    try check(rejected { try invalid.validate() }, "内存非有限时限也拒绝")

    let off = LocalLockFixture(enabled: false)
    off.advance(600)
    try check(off.actions.isEmpty && off.idleReads == 0 && off.safetyReads == 0 && off.policy.state == .disabled, "默认关闭不采集闲置、不探权限、不提交动作")
    try off.policy.requestNow(.screenSaver)
    try check(off.actions == [.screenSaver] && off.policy.state == .disabled, "关闭自动策略时手动动作仍通过注入器提交")
    try check(off.events.last?.message.contains("屏保不等于锁定") == true, "屏保请求明确不证明会话锁定")

    let threshold = LocalLockFixture()
    threshold.advance(29)
    try check(threshold.actions.isEmpty && threshold.policy.state == .observing, "达到阈值前不执行")
    threshold.advance(1)
    try check(threshold.policy.state == .countdown(5) && threshold.actions.isEmpty, "阈值准确开始五秒提醒")
    threshold.advance(4)
    try check(threshold.policy.state == .countdown(1) && threshold.actions.isEmpty, "提醒尚未结束不执行")
    threshold.advance(1)
    try check(threshold.actions == [.lockScreen] && threshold.policy.state == .waitingForActivity, "提醒完成只提交一次真实适配意图")
    try check(threshold.events.last?.message.contains("尚未确认") == true, "提交动作不假称已锁定")
    threshold.advance(90)
    try check(threshold.actions.count == 1, "同一连续闲置周期不重入")
    threshold.time += 100; threshold.policy.tick(); threshold.advance(50)
    try check(threshold.actions.count == 1, "长采样间隙也不清除已请求周期的防重入闸门")
    threshold.policy.recordSystemEvent("测试唤醒观察"); threshold.advance(40)
    try check(threshold.actions.count == 1, "系统通知不能冒充用户返回或重复锁屏依据")
    threshold.input(); threshold.advance(35)
    try check(threshold.actions.count == 2, "检测到新的真实输入周期后重新等待完整时限")

    let synthetic = LocalLockFixture()
    synthetic.advance(35)
    synthetic.lastInput = synthetic.time + 0.5 // A delayed injected key, not a real system event.
    synthetic.advance(70)
    try check(synthetic.actions.count == 1 && synthetic.policy.state == .waitingForActivity, "自身合成快捷键更新闲置表不被误当作用户返回而重复锁屏")
    synthetic.input(); synthetic.advance(35)
    try check(synthetic.actions.count == 2, "提交稳定期后的新输入仍能开启下个完整周期")

    let startup = LocalLockFixture()
    startup.lastInput = startup.time - 500
    startup.policy.recordSystemEvent("新进程启动")
    startup.policy.tick(); startup.advance(29)
    try check(startup.actions.isEmpty && startup.policy.state == .observing, "启动时已闲置很久也须完整新观察周期")
    startup.advance(6)
    try check(startup.actions.count == 1, "新观察周期完成后才可执行")

    let input = LocalLockFixture()
    input.advance(33); input.input()
    try check(input.policy.state == .observing && input.events.last?.kind == .cancelled, "倒计时期间活动立即取消")
    input.advance(34)
    try check(input.actions.isEmpty, "活动重置完整闲置和提醒窗口")
    input.advance(1)
    try check(input.actions.count == 1, "新窗口完成后可执行")

    let cancel = LocalLockFixture()
    cancel.advance(32); cancel.policy.cancelPending(); cancel.advance(5)
    try check(cancel.actions.isEmpty && cancel.policy.state == .observing, "主动取消不延迟重放原请求")
    cancel.advance(29)
    try check(cancel.actions.isEmpty, "取消后新的完整时限仍保留提醒")
    cancel.advance(1)
    try check(cancel.actions.count == 1, "取消后须重新完成整个窗口")

    let busy = LocalLockFixture()
    busy.advance(34); busy.blocked = "正在压缩真实任务"; busy.advance(1)
    try check(busy.actions.isEmpty && busy.policy.state == .paused("正在压缩真实任务"), "实际任务忙碌阻止倒计时到期动作")
    busy.advance(100)
    try check(busy.actions.isEmpty, "长任务期间不会擅锁")
    let pauseCount = busy.events.filter { $0.kind == .paused }.count
    try check(pauseCount == 1, "相同忙碌原因不每秒重复刷审计")
    busy.blocked = nil; busy.advance(1); busy.advance(34)
    try check(busy.actions.isEmpty, "忙碌解除不补发积压锁屏请求")
    busy.advance(1)
    try check(busy.actions.count == 1, "忙碌解除后重新满足完整闲置加提醒")
    busy.blocked = "后续任务"; busy.advance(10); busy.blocked = nil; busy.advance(50)
    try check(busy.actions.count == 1, "已请求周期即使忙碌暂停恢复仍只请求一次")

    let paused = LocalLockFixture()
    paused.advance(31); paused.policy.pauseForSafety("人工安全暂停"); paused.advance(100)
    try check(paused.actions.isEmpty && paused.policy.state == .paused("人工安全暂停"), "明确安全暂停须主动恢复")
    paused.policy.resume(); paused.policy.tick(); paused.advance(34)
    try check(paused.actions.isEmpty, "主动恢复也不能恢复旧倒计时")
    paused.advance(1)
    try check(paused.actions.count == 1, "恢复后新的完整窗口可执行")

    let error = LocalLockFixture()
    error.failure = LocalLockError.message("注入失败，无系统动作")
    error.advance(35)
    if case .failed = error.policy.state { try check(true, "错误状态已锁存") }
    else { try check(false, "错误必须进入失败暂停") }
    error.failure = nil; error.advance(100); error.input(); error.advance(50)
    try check(error.actions.isEmpty && error.events.filter { $0.kind == .failed }.count == 1, "错误不自动重试，输入也不清除错误闸门")
    error.policy.resume(); error.policy.tick(); error.advance(35)
    try check(error.actions.count == 1, "本人恢复后才重新执行")

    let unsafe = LocalLockFixture(enabled: false)
    unsafe.blocked = "会话或权限不可用"
    try check(rejected { try unsafe.policy.requestNow() } && unsafe.actions.isEmpty, "手动请求也尊重会话、权限与任务安全闸门")
    try check(unsafe.events.last?.kind == .paused, "被拒绝手动请求有可见审计")

    let reentry = LocalLockFixture()
    var reentryRejected = false
    reentry.onPerform = {
        reentry.policy.tick()
        reentryRejected = rejected { try reentry.policy.requestNow(.screenSaver) }
    }
    reentry.advance(35)
    try check(reentryRejected && reentry.actions == [.lockScreen], "动作closure重入不能重复提交")
    reentry.onPerform = nil

    let lateInput = LocalLockFixture()
    lateInput.advance(34)
    var readsAtDeadline = 0
    lateInput.onSafety = {
        readsAtDeadline += 1
        if readsAtDeadline == 2 { lateInput.lastInput = lateInput.time }
    }
    lateInput.advance(1)
    try check(lateInput.actions.isEmpty && lateInput.policy.state == .observing, "最终提交前重新采样捕获新输入并取消")

    let lateBusy = LocalLockFixture()
    lateBusy.advance(34)
    var busyChecks = 0
    lateBusy.onSafety = { busyChecks += 1; if busyChecks == 2 { lateBusy.blocked = "提交前新任务启动" } }
    lateBusy.advance(1)
    try check(lateBusy.actions.isEmpty && lateBusy.policy.state == .paused("提交前新任务启动"), "最终提交前再核对忙碌状态")

    let sleep = LocalLockFixture()
    sleep.advance(34); sleep.policy.recordSystemEvent("系统即将睡眠"); sleep.policy.tick(); sleep.advance(5)
    try check(sleep.actions.isEmpty, "睡眠／会话事件废弃旧倒计时")
    sleep.advance(30)
    try check(sleep.actions.count == 1, "系统恢复后只有新完整窗口可执行")

    let samplingGap = LocalLockFixture()
    samplingGap.advance(34); samplingGap.time += 30; samplingGap.policy.tick()
    try check(samplingGap.actions.isEmpty && samplingGap.policy.state == .observing, "主线程长阻塞后不立即执行过期请求")
    samplingGap.advance(35)
    try check(samplingGap.actions.count == 1, "长阻塞后重新观察完整窗口")

    let corrupt = LocalLockFixture()
    corrupt.advance(31); corrupt.idleOverride = .nan; corrupt.advance(1)
    try check(corrupt.actions.isEmpty && corrupt.events.last?.kind == .failed, "闲置无法读取不当成可执行证据")
    let reverse = LocalLockFixture()
    reverse.advance(31); reverse.time -= 1; reverse.policy.tick()
    try check(reverse.actions.isEmpty && reverse.events.last?.kind == .failed, "时钟倒退取消待执行动作")

    let changed = LocalLockFixture()
    changed.advance(34)
    var disabled = changed.policy.configuration; disabled.enabled = false
    try changed.policy.updateConfiguration(disabled); changed.advance(50)
    try check(changed.actions.isEmpty && changed.policy.state == .disabled, "关闭策略同步撤销待执行请求")
    var bad = disabled; bad.warningSeconds = .infinity
    try check(rejected { try changed.policy.updateConfiguration(bad) } && changed.policy.configuration == disabled, "无效更新保留原配置")
    let saver = LocalLockFixture(action: .screenSaver)
    saver.advance(35)
    try check(saver.actions == [.screenSaver], "屏保策略与锁屏策略各自提交明确动作")

    print("PASS: \(checks) 项本机闲置策略隔离测试；注入单调时钟、闲置、任务和动作closure，未调用真实锁屏、休眠、GUI、硬件或权限接口")
}
