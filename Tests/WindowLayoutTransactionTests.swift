import Foundation
import CoreGraphics

@MainActor
private final class SimulatedLayoutWindow {
    let initial: CGRect
    var frame: CGRect
    var ticks = 0
    var latency = 0
    var minimumWidth: CGFloat?
    var rejectSmallSize = false
    var rejectAll = false
    var rejectRollback = false
    var rejectPositions = false
    var identityValid = true
    var writes = 0
    var writtenSizes: [CGSize] = []
    var writtenPositions: [CGPoint] = []
    var writeBeforeSave = false
    var saved = false
    var onTick: (() -> Void)?
    private var pendingSize: (Int, CGSize)?
    private var pendingPosition: (Int, CGPoint)?
    init(_ frame: CGRect) { initial = frame; self.frame = frame }
    func size(_ value: CGSize) throws {
        writtenSizes.append(value)
        writes += 1; writeBeforeSave = writeBeforeSave || !saved
        guard !rejectAll, !(rejectRollback && value == initial.size) else { throw SystemControlError.message("模拟尺寸拒绝") }
        var accepted = value
        if let minimumWidth, value.width < minimumWidth {
            if rejectSmallSize { throw SystemControlError.message("模拟整个 CGSize 被最小宽度拒绝") }
            accepted.width = minimumWidth
        }
        if latency == 0 { frame.size = accepted }
        else { pendingSize = (ticks + latency, accepted) }
    }
    func position(_ value: CGPoint) throws {
        writtenPositions.append(value)
        writes += 1; writeBeforeSave = writeBeforeSave || !saved
        guard !rejectAll, !rejectPositions, !(rejectRollback && value == initial.origin) else { throw SystemControlError.message("模拟位置拒绝") }
        if latency == 0 { frame.origin = value }
        else { pendingPosition = (ticks + latency, value) }
    }
    func tick() {
        ticks += 1
        if let pendingSize, ticks >= pendingSize.0 { frame.size = pendingSize.1; self.pendingSize = nil }
        if let pendingPosition, ticks >= pendingPosition.0 { frame.origin = pendingPosition.1; self.pendingPosition = nil }
        onTick?()
    }
    func validate() throws { guard identityValid else { throw SystemControlError.message("模拟原捕获窗口已失效") } }
}

@MainActor
func runWindowLayoutTransactionTests() async throws {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        guard value() else { throw SystemControlError.message("窗口布局交易测试：" + message) }
    }
    let original = CGRect(x: 150, y: 120, width: 1000, height: 500)
    let area = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let left = CGRect(x: 0, y: 25, width: 720, height: 850)
    func transaction(_ model: SimulatedLayoutWindow) -> WindowLayoutTransaction {
        WindowLayoutTransaction(pause: { model.tick(); await Task.yield() })
    }
    func run(_ engine: WindowLayoutTransaction, _ model: SimulatedLayoutWindow,
             desired: CGRect = left, restoring: Bool = false,
             validate: (() throws -> Void)? = nil, read: (() throws -> CGRect)? = nil,
             didRestore: @escaping () -> Void = {}) async throws -> WindowLayoutOutcome {
        try await engine.execute(requested: desired, original: model.frame, workArea: area, resize: true,
            allowConstrained: !restoring, validate: validate ?? model.validate, validateRollback: model.validate,
            read: read ?? { model.frame }, setSize: model.size, setPosition: model.position,
            saveOriginal: { model.saved = true }, didRestore: didRestore)
    }

    let delayed = SimulatedLayoutWindow(original); delayed.latency = 4
    let delayedEngine = transaction(delayed)
    let exact = try await run(delayedEngine, delayed)
    try check(exact.isExact && exact.actual == left, "延迟四次读回后才接受精确布局")
    try check(delayed.ticks >= 6, "旧帧短暂稳定不能提前误判为应用限制")
    try check(!delayed.writeBeforeSave && delayed.saved, "首次 AX 写入前已有原位置记录")
    try check(!delayedEngine.isBusy, "成功后释放串行占用")

    let clamped = SimulatedLayoutWindow(original); clamped.minimumWidth = 900
    let limited = try await run(transaction(clamped), clamped)
    try check(!limited.isExact && limited.actual.width == 900, "最小宽度钳制返回受限结果")
    try check(limited.actual.height == area.height && limited.actual.minY == area.minY, "宽度钳制仍铺满可用高度")
    try check(limited.actual.minX == area.minX, "左半屏受限时贴左边而非任意居中")
    try check(clamped.saved, "受限结果保留原位置记录")
    let gapFrame = WindowLayoutTransaction.fittedFrame(size: CGSize(width: 900,height: 830), requested: left.insetBy(dx: 10,dy: 10), workArea: area)
    try check(gapFrame.minX == 10 && gapFrame.minY == 35, "设置窗口间距后仍保留左侧及顶部锚点")

    let rejectedSize = SimulatedLayoutWindow(original)
    rejectedSize.minimumWidth = 900; rejectedSize.rejectSmallSize = true
    let rejectedOutcome = try await run(transaction(rejectedSize), rejectedSize)
    try check(!rejectedOutcome.isExact && rejectedOutcome.actual.width == original.width, "整个 CGSize 被拒绝时保留已允许宽度")
    try check(rejectedOutcome.actual.height == area.height && rejectedOutcome.actual.minX == area.minX,
              "独立高度请求不会再次被过窄宽度挡住")

    let right = CGRect(x: 720, y: 25, width: 720, height: 850)
    let rightModel = SimulatedLayoutWindow(original); rightModel.minimumWidth = 900
    let rightOutcome = try await run(transaction(rightModel), rightModel, desired: right)
    try check(rightOutcome.actual.maxX == area.maxX && rightOutcome.actual.width == 900, "右半屏按实际宽度贴右边")
    let interior = WindowLayoutTransaction.fittedFrame(size: CGSize(width: 900, height: 500), requested: CGRect(x: 360, y: 25, width: 720, height: 850), workArea: area)
    try check(interior.midX == area.midX && interior.minY == area.minY, "内部布局中心及顶部锚点保持")
    let oversized = WindowLayoutTransaction.fittedFrame(size: CGSize(width: 1800, height: 1000), requested: right, workArea: area)
    try check(oversized.origin == area.origin, "超出屏幕的应用最小尺寸仍保留可访问标题栏")

    let refused = SimulatedLayoutWindow(original); refused.rejectAll = true
    let refusedEngine = transaction(refused)
    var refusal: WindowLayoutFailure?
    do { _ = try await run(refusedEngine, refused) } catch { refusal = error as? WindowLayoutFailure }
    try check(refusal?.rollbackVerified == true, "完全拒绝不能报成功，且核验原帧未变")
    try check(refused.frame == original && refused.saved && !refused.writeBeforeSave, "完全拒绝保留恢复记录而不移动窗口")
    try check(!refusedEngine.isBusy, "失败回滚结束后释放占用")

    let positionRefused = SimulatedLayoutWindow(original)
    positionRefused.minimumWidth = 900; positionRefused.rejectPositions = true
    var positionFailure: WindowLayoutFailure?
    do { _ = try await run(transaction(positionRefused), positionRefused) } catch { positionFailure = error as? WindowLayoutFailure }
    try check(positionFailure?.rollbackVerified == true && positionRefused.frame == original,
              "尺寸已接受但最终贴边被拒绝不能当作受限成功，须确认回滚")
    try check(positionRefused.saved, "最终位置拒绝保留恢复记录")

    let restoreModel = SimulatedLayoutWindow(CGRect(x: 0, y: 25, width: 1300, height: 850))
    restoreModel.minimumWidth = 1200
    var journal: CGRect? = original
    var restoreFailure: WindowLayoutFailure?
    do { _ = try await run(transaction(restoreModel), restoreModel, desired: original, restoring: true, didRestore: { journal = nil }) }
    catch { restoreFailure = error as? WindowLayoutFailure }
    try check(restoreFailure?.rollbackVerified == true && journal == original, "受限恢复不清除记录且确认返回恢复前位置")
    try check(restoreModel.frame == restoreModel.initial, "恢复被拒绝时回滚完整尺寸和位置")
    restoreModel.minimumWidth = nil
    let restored = try await run(transaction(restoreModel), restoreModel, desired: original, restoring: true, didRestore: { journal = nil })
    try check(restored.isExact && restoreModel.frame == original && journal == nil, "只有精确恢复确认后才清除记录")

    let rollbackRefused = SimulatedLayoutWindow(original); rollbackRefused.rejectRollback = true
    var interrupt = false
    rollbackRefused.onTick = { if rollbackRefused.ticks == 2 { interrupt = true } }
    var rollbackFailure: WindowLayoutFailure?
    do {
        _ = try await run(transaction(rollbackRefused), rollbackRefused, validate: {
            if interrupt { throw SystemControlError.message("模拟用户切换应用") }
        })
    } catch { rollbackFailure = error as? WindowLayoutFailure }
    try check(rollbackFailure?.rollbackVerified == false && rollbackRefused.frame != original, "回滚也被拒绝时明确标明未确认恢复")
    try check(rollbackRefused.saved && rollbackFailure?.localizedDescription.contains("原位置记录已保留") == true, "失败后的原位置记录可供再次恢复")

    let lost = SimulatedLayoutWindow(original)
    lost.onTick = { if lost.ticks == 1 { lost.identityValid = false } }
    var lostFailure: WindowLayoutFailure?
    do { _ = try await run(transaction(lost), lost) } catch { lostFailure = error as? WindowLayoutFailure }
    try check(lostFailure?.rollbackVerified == false && lost.writes == 3, "捕获窗口失效后不再写入或转用别的窗口")
    try check(lost.saved, "失效窗口仍留恢复记录，不伪称回滚成功")

    let cancelled = SimulatedLayoutWindow(original)
    var cancelledTask: Task<WindowLayoutOutcome, Error>?
    cancelled.onTick = { if cancelled.ticks == 1 { cancelledTask?.cancel() } }
    let cancelledEngine = transaction(cancelled)
    cancelledTask = Task { try await run(cancelledEngine, cancelled) }
    var cancellation: WindowLayoutFailure?
    do { _ = try await cancelledTask!.value } catch { cancellation = error as? WindowLayoutFailure }
    try check(cancellation?.reason == "窗口操作已取消。" && cancellation?.rollbackVerified == true, "取消后仍等待并确认回滚")
    try check(cancelled.frame == original && cancelled.saved && !cancelledEngine.isBusy, "取消保留原帧并在回滚完成后解锁")

    let readLost = SimulatedLayoutWindow(original)
    var readLostCleared = false
    var readLostCount = 0
    var readLostFailure: WindowLayoutFailure?
    do {
        _ = try await run(transaction(readLost), readLost, restoring: true, read: {
            readLostCount += 1
            if readLostCount == 3 { readLost.identityValid = false }
            return readLost.frame // Correct frame does not make a lost AX identity safe.
        }, didRestore: { readLostCleared = true })
    } catch { readLostFailure = error as? WindowLayoutFailure }
    try check(readLostFailure?.rollbackVerified == false && !readLostCleared,
              "AX读返回正确帧但期间身份失效时不能成功或清恢复记录")
    try check(readLost.writes == 3 && readLost.saved, "读期间失效后不再写入其他目标且保留记录")

    let readSwitched = SimulatedLayoutWindow(original)
    var frontIsTarget = true, readSwitchedCount = 0, readSwitchedCleared = false
    var readSwitchedFailure: WindowLayoutFailure?
    do {
        _ = try await run(transaction(readSwitched), readSwitched, restoring: true, validate: {
            if !frontIsTarget { throw SystemControlError.message("模拟AX读期间前台切换") }
        }, read: {
            readSwitchedCount += 1
            if readSwitchedCount == 3 { frontIsTarget = false }
            return readSwitched.frame
        }, didRestore: { readSwitchedCleared = true })
    } catch { readSwitchedFailure = error as? WindowLayoutFailure }
    try check(readSwitchedFailure?.rollbackVerified == true && !readSwitchedCleared,
              "AX读期间切换前台时停止且不清恢复记录")
    try check(readSwitched.frame == original, "前台切换回滚只恢复原捕获窗口的完整帧")

    let readCancelled = SimulatedLayoutWindow(original)
    var readCancelledTask: Task<WindowLayoutOutcome, Error>?
    var readCancelledCount = 0, readCancelledCleared = false
    let readCancelledEngine = transaction(readCancelled)
    readCancelledTask = Task {
        try await run(readCancelledEngine, readCancelled, restoring: true, read: {
            readCancelledCount += 1
            if readCancelledCount == 3 { readCancelledTask?.cancel() }
            return readCancelled.frame
        }, didRestore: { readCancelledCleared = true })
    }
    var readCancellation: WindowLayoutFailure?
    do { _ = try await readCancelledTask!.value } catch { readCancellation = error as? WindowLayoutFailure }
    try check(readCancellation?.reason == "窗口操作已取消。" && readCancellation?.rollbackVerified == true && !readCancelledCleared,
              "AX读期间取消时不能以正确读帧宣布恢复成功")
    try check(readCancelled.frame == original && readCancelled.saved && !readCancelledEngine.isBusy,
              "读期间取消仍核验回滚并保留记录、释放占用")

    let validateCancelled = SimulatedLayoutWindow(original)
    var validateCancelledTask: Task<WindowLayoutOutcome, Error>?
    var validationCalls = 0
    validateCancelledTask = Task {
        try await run(transaction(validateCancelled), validateCancelled, validate: {
            validationCalls += 1
            if validationCalls == 2 { validateCancelledTask?.cancel() }
        })
    }
    var validateCancellation: WindowLayoutFailure?
    do { _ = try await validateCancelledTask!.value } catch { validateCancellation = error as? WindowLayoutFailure }
    try check(validateCancellation?.reason == "窗口操作已取消。" && validateCancellation?.rollbackVerified == true,
              "AX身份核验期间取消后立即停止主写入并确认回滚")
    try check(validateCancelled.writtenSizes.allSatisfy { $0 == original.size }
              && validateCancelled.writtenPositions.allSatisfy { $0 == original.origin },
              "核验期间取消后的写入只属于原帧回滚，不得写请求布局")

    let concurrent = SimulatedLayoutWindow(original)
    var gate: CheckedContinuation<Void, Never>?
    var firstPause = true
    let concurrentEngine = WindowLayoutTransaction(pause: {
        concurrent.tick()
        if firstPause {
            firstPause = false
            await withCheckedContinuation { gate = $0 }
        } else { await Task.yield() }
    })
    let first = Task { try await run(concurrentEngine, concurrent) }
    for _ in 0..<100 where gate == nil { await Task.yield() }
    try check(gate != nil && concurrentEngine.isBusy, "异步等待期间保持串行占用")
    let writeCount = concurrent.writes
    var concurrentRejected = false
    do { _ = try await run(concurrentEngine, concurrent, desired: right) } catch { concurrentRejected = true }
    try check(concurrentRejected && concurrent.writes == writeCount, "并发请求在任何 AX 写入之前被拒绝")
    gate?.resume(); gate = nil
    let firstResult = try await first.value
    try check(firstResult.isExact && concurrent.frame == left && !concurrentEngine.isBusy, "拒绝并发不破坏进行中的布局")

    var invalidSaved = false
    let invalid = WindowLayoutTransaction(pause: {})
    var invalidRejected = false
    do {
        _ = try await invalid.execute(requested: CGRect(x: 0,y: 0,width: -1,height: 400), original: original, workArea: area,
            resize: true, allowConstrained: true, validate: {}, validateRollback: {}, read: { original },
            setSize: { _ in }, setPosition: { _ in }, saveOriginal: { invalidSaved = true })
    } catch { invalidRejected = true }
    try check(invalidRejected && !invalidSaved && !invalid.isBusy, "非法布局不写入也不改恢复记录")
    print("PASS: \(count)项窗口异步稳定、最小尺寸适配、拒绝/回滚、恢复记录、取消与并发交易测试（仅模拟窗口）")
}
