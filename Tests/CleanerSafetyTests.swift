import Foundation

@MainActor func runCleanerSafetyTests() throws {
    var health=true
    var releases=0
    let safety=CleanerInputSafety(health:{health},release:{releases += 1})
    func check(_ ok:Bool,_ name:String) throws {if !ok {throw DataFailure.message("清洁安全回归失败："+name)}}
    try check(CleanerRescuePolicy.canVerify(sourcePID:0,repeated:false),"系统来源可用于演练")
    try check(!CleanerRescuePolicy.canVerify(sourcePID:123,repeated:false) && !CleanerRescuePolicy.canVerify(sourcePID:0,repeated:true),"合成和重复不能作为演练")
    try check(!safety.permitsInterception(now:10),"未开始不拦截")
    try check(!safety.begin(now:10,duration:29) && !safety.begin(now:10,duration:181),"时限边界")
    try check(!safety.begin(now:.nan,duration:30),"拒绝无效时钟")
    health=false;try check(!safety.begin(now:10,duration:30),"无健康通道不能开始")
    health=true;try check(safety.begin(now:10,duration:30),"可用通道租约")
    try check(safety.permitsInterception(now:10.9),"心跳有效")
    safety.pulse(now:10.9);try check(safety.permitsInterception(now:11.8),"续租")
    try check(!safety.permitsInterception(now:12) && releases == 1,"主线程无心跳释放")
    try check(!safety.permitsInterception(now:12.1) && releases == 1,"失效不重复释放")
    safety.finish();try check(safety.begin(now:20,duration:30),"全新会话")
    health=false;try check(!safety.permitsInterception(now:20.1) && releases == 2,"通道丢失释放")
    health=true;safety.finish();try check(safety.begin(now:30,duration:30),"重新开始")
    safety.pulse(now:59.9);try check(!safety.permitsInterception(now:60) && releases == 3,"硬截止不可续租越界")
    safety.finish();try check(safety.begin(now:70,duration:30),"重建前租约")
    safety.bind(nil,active:false);try check(!safety.permitsInterception(now:70.1) && releases == 4,"通道重建使原租约失效")
    safety.finish();try check(!safety.permitsInterception(now:70.2),"退出即放行")
    print("清洁模式租约与故障释放定向检查通过；未创建遮罩、事件通道或发送按键。")
}

private final class CleanerWatchdogTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseCount = 0
    private var backgroundCheckCount = 0
    let released = DispatchSemaphore(value: 0)
    let backgroundChecked = DispatchSemaphore(value: 0)
    func noteBackgroundCheck() {
        lock.lock(); backgroundCheckCount += 1; lock.unlock()
        backgroundChecked.signal()
    }
    func release() {
        lock.lock(); releaseCount += 1; lock.unlock()
        released.signal()
    }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return releaseCount }
    var backgroundChecks: Int { lock.lock(); defer { lock.unlock() }; return backgroundCheckCount }
}

@MainActor func runCleanerWatchdogStartupTests() async throws {
    var checks = 0
    @MainActor func check(_ value: Bool, _ name: String) throws {
        checks += 1
        if !value { throw DataFailure.message("清洁启动时序检查失败：" + name) }
    }
    @MainActor func eventually(_ name: String, _ condition: @MainActor () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < limit {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(condition(), name)
    }
    @MainActor func fixture(_ name: String) -> (CleanerInputSafety, CleanerWatchdogSession, CleanerWatchdogTestProbe, DispatchQueue) {
        let queue = DispatchQueue(label: "cleaner-test." + name)
        let key = DispatchSpecificKey<Int>(); queue.setSpecific(key: key, value: 1)
        let probe = CleanerWatchdogTestProbe()
        let safety = CleanerInputSafety(health: {
            if DispatchQueue.getSpecific(key: key) == 1 { probe.noteBackgroundCheck() }
            return true
        }, release: { probe.release() })
        return (safety, CleanerWatchdogSession(safety: safety, queue: queue), probe, queue)
    }

    // Exercise the production timer while the overlay factory holds the main
    // actor. No real window or event tap is created by this factory.
    do {
        let (_, session, probe, _) = fixture("blocked-overlay")
        defer { session.cancel() }
        var overlays = 0, failures = 0
        var readyBeforeOverlay = false, releasedInsideOverlay = false
        var blockElapsed: TimeInterval = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: {
            overlays += 1; readyBeforeOverlay = probe.backgroundChecks > 0
            let began = ProcessInfo.processInfo.systemUptime
            releasedInsideOverlay = probe.released.wait(timeout: .now() + 2.5) == .success
            blockElapsed = ProcessInfo.processInfo.systemUptime - began
        }, failed: { failures += 1 }), "阻塞工厂开始租约")
        try await eventually("遮罩返回立即识别失效租约") { failures == 1 }
        try check(overlays == 1 && readyBeforeOverlay, "实际后台ready早于遮罩工厂")
        try check(releasedInsideOverlay && blockElapsed < 2.5, "主actor仍阻塞时后台已释放输入")
        try check(probe.releases == 1 && !session.isRunning, "失效只释放一次且不保留active启动")
    }
    // A queued timer that has not acknowledged startup must never show a mask.
    do {
        let (_, session, _, queue) = fixture("not-ready-cancelled")
        let queueEntered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        queue.async { queueEntered.signal(); gate.wait() }
        defer { gate.signal(); session.cancel() }
        try check(queueEntered.wait(timeout: .now() + 1) == .success, "隔离后台队列已占用")
        var overlays = 0, failures = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { overlays += 1 }, failed: { failures += 1 }), "未ready启动已登记")
        let token = session.currentToken
        try check(!session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { overlays += 1 }, failed: { failures += 1 }) && session.currentToken == token, "重复开始不替换原租约或token")
        try check(overlays == 0, "无后台ready不创建遮罩")
        session.cancel(); gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(overlays == 0 && failures == 0 && !session.isRunning, "取消未ready启动后不迟到遮罩或报错")
    }
    // Queue the old ready callback while this actor is occupied; a new token
    // must make that callback inert even though its lease once was healthy.
    do {
        let (_, session, probe, _) = fixture("late-ready")
        defer { session.cancel() }
        var oldOverlays = 0, newOverlays = 0, failures = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { oldOverlays += 1 }, failed: { failures += 1 }), "旧ready启动")
        try check(probe.backgroundChecked.wait(timeout: .now() + 1) == .success, "旧后台检查已到达")
        let oldToken = session.currentToken; session.cancel()
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { newOverlays += 1 }, failed: { failures += 1 }) && session.currentToken != oldToken, "新启动使用不同token")
        try await eventually("新ready正常创建一次模拟遮罩") { newOverlays == 1 }
        try check(oldOverlays == 0 && failures == 0 && session.isRunning, "迟到旧ready不能创建遮罩或释放新会话")
    }
    // An already active watchdog can fail while the actor is occupied. Its
    // queued cleanup must not cancel a subsequent healthy session.
    do {
        let (_, session, probe, _) = fixture("late-failure")
        defer { session.cancel() }
        var oldOverlays = 0, newOverlays = 0, failures = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { oldOverlays += 1 }, failed: { failures += 1 }), "旧活动会话开始")
        try await eventually("旧会话后台ready已提交遮罩") { oldOverlays == 1 }
        try check(probe.released.wait(timeout: .now() + 2.5) == .success, "主actor占用期间旧监护已释放输入")
        session.cancel()
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { newOverlays += 1 }, failed: { failures += 1 }), "旧失效回调处理前新会话开始")
        try await eventually("新会话通过自己的ready") { newOverlays == 1 }
        try check(failures == 0 && session.isRunning && probe.releases == 1, "旧监护迟到清理不触碰新租约")
    }
    do {
        let (_, session, _, _) = fixture("final-gate")
        defer { session.cancel() }
        var overlays = 0, failures = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { false }, present: { overlays += 1 }, failed: { failures += 1 }), "ready之前已取得租约")
        try await eventually("ready后的最终权限与验证门拒绝") { failures == 1 }
        try check(overlays == 0 && !session.isRunning, "最终门失效不创建遮罩")
    }
    do {
        let queue = DispatchQueue(label: "cleaner-test.unhealthy-first-check")
        let key = DispatchSpecificKey<Int>(); queue.setSpecific(key: key, value: 1)
        let probe = CleanerWatchdogTestProbe()
        let safety = CleanerInputSafety(health: { DispatchQueue.getSpecific(key: key) != 1 }, release: { probe.release() })
        let session = CleanerWatchdogSession(safety: safety, queue: queue)
        defer { session.cancel() }
        var overlays = 0, failures = 0
        try check(session.start(now: ProcessInfo.processInfo.systemUptime, duration: 30, canPresent: { true }, present: { overlays += 1 }, failed: { failures += 1 }), "初始健康门通过")
        try await eventually("实际后台首次检查拒绝") { failures == 1 }
        try check(overlays == 0 && probe.releases == 1 && !session.isRunning, "首次ready失败释放且不创建遮罩")
    }
    print("PASS: \(checks) cleaner watchdog startup checks; production timer/ready/cancel paths reused, no windows, event taps or input events created")
}

@MainActor func runProductionActionCatalogTests() throws {
    let actions=OperationAction.all
    guard Set(actions.map(\.id)).count == actions.count else {throw DataFailure.message("生产动作目录存在重复ID")}
    let registry=ActionRegistry()
    for action in actions {
        guard registry.descriptor(for:action.id) != nil else {throw DataFailure.message("动作未接入统一注册表："+action.id)}
    }
    for id in ["cleaner.start","flykey.show","inputsource.settings","snippet.manager.show","selection.uppercase","selection.clipboard.show","clipboard.stack.push"] {
        guard actions.contains(where:{$0.id == id}) else {throw DataFailure.message("生产面板未暴露动作："+id)}
    }
    print("生产动作与统一描述表覆盖检查通过（\(actions.count)项）；未执行系统或应用动作。")
}
