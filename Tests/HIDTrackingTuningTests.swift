import Foundation

@MainActor func runHIDTrackingTuningTests() throws {
    struct TestFailure: LocalizedError {let errorDescription: String?}
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        checks += 1;if !condition() {throw TestFailure(errorDescription: "逐设备事务：" + text)}
    }
    final class Fixture {
        var persisted: HIDTrackingTuning.Document?
        var storageFailure = false
        var failSaveNumber: Int?
        var saveNumber = 0
        var writeNumber = 0
        var rejectWrite: Int?
        var clampWrite: Int?
        var disconnected = false
        var missingOriginal = false
        var bootSession: String?
        var values = HIDTrackingValues(accelerationKey: "HIDMouseAcceleration", resolution: 26214400, acceleration: 32768)
        var writeJournalWasReady = true
        var writtenBindings: [HIDTrackingBinding] = []
        @MainActor var persistence: HIDTrackingTuning.Persistence {
            .init(load:{[self] in persisted}, save:{[self] value in
                saveNumber += 1
                if storageFailure || failSaveNumber == saveNumber {throw TestFailure(errorDescription: "synthetic storage refusal")}
                // Serialize, rather than keeping an alias to live transaction data.
                persisted = try JSONDecoder().decode(HIDTrackingTuning.Document.self, from: JSONEncoder().encode(value))
            })
        }
        @MainActor var backend: HIDTrackingBackend {
            .init(read:{[self] binding in
                guard !disconnected, binding.serviceID == 101, !missingOriginal else {throw TestFailure(errorDescription: "synthetic unavailable original")}
                return values
            }, write:{[self] binding, key, value in
                writeNumber += 1;writtenBindings.append(binding)
                writeJournalWasReady = writeJournalWasReady && (persisted?.entries.contains{$0.binding == binding && $0.needsRecovery} ?? false)
                if rejectWrite == writeNumber {return false}
                let number = clampWrite == writeNumber ? value + 7 : value
                values = .init(accelerationKey: values.accelerationKey,
                               resolution: key == HIDTrackingValues.resolutionKey ? number : values.resolution,
                               acceleration: key == values.accelerationKey ? number : values.acceleration)
                return true
            },currentBootSession:{[self] in bootSession})
        }
        @MainActor func controller() -> HIDTrackingTuning {.init(backend: backend, persistence: persistence)}
    }
    let binding = HIDTrackingBinding(deviceID: "hid-v2:" + String(repeating: "a", count: 64), serviceID: 101)
    let original = HIDTrackingValues(accelerationKey: "HIDMouseAcceleration", resolution: 26214400, acceleration: 32768)
    let profile = UUID()
    func request(_ speed: Double = 2, _ acceleration: Double = 1) -> HIDTrackingTuning.Request {
        .init(profileID: profile, binding: binding, speed: speed, acceleration: acceleration)
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()])
        try check(f.writeJournalWasReady && f.writeNumber == 2, "每次真实后端边界写入前，已存在可恢复原值日志")
        try check(f.values.resolution == 13107200 && f.values.acceleration == 65536 && c.appliedBindings == [binding], "固定16.16编码和相对原值速度已读回")
        c.reconcile([request()]);try check(f.writeNumber == 2, "重复轮询不重复写入")
        c.reconcile([request(4)]);try check(f.values.resolution == 6553600, "重新配置先恢复原值，速度倍率不叠乘")
        c.stop();try check(f.values == original && c.appliedBindings.isEmpty, "停用时逐值恢复真实原值并读回")
        try check(f.persisted?.entries.allSatisfy{$0.state == "restored"} == true, "恢复后完整原值历史继续保留")
    }
    do {
        let f = Fixture();f.rejectWrite = 2
        let c = f.controller();c.reconcile([request()])
        try check(f.values == original && c.appliedBindings.isEmpty && f.writeNumber == 3, "第二项写入拒绝后恢复第一项，不能假成功")
        try check(f.persisted?.entries.first?.state == "restored", "失败恢复结果已落盘")
    }
    do {
        let f = Fixture();f.storageFailure = true
        let c = f.controller();c.reconcile([request()])
        try check(f.writeNumber == 0 && f.values == original, "原值无法持久备份时零写入")
    }
    do {
        let f = Fixture();f.failSaveNumber = 2
        let c = f.controller();c.reconcile([request()])
        try check(f.values == original && c.appliedBindings.isEmpty, "写入后活动状态落盘失败，仍用prepared日志恢复真实原值")
        try check(f.persisted?.entries.first?.state == "restored", "落盘失败后的恢复结论可再次持久化")
    }
    do {
        let f = Fixture();f.missingOriginal = true
        let c = f.controller();c.reconcile([request()])
        try check(f.writeNumber == 0 && f.persisted == nil, "原值不可读时绝不当作零或默认值")
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()])
        let crashImage = f.persisted!
        let recovered = f.controller();recovered.recover()
        try check(f.values == original && crashImage.entries.first?.state == "active", "进程重新创建可从真实原值日志恢复活动事务")
        try check(f.persisted?.entries.first?.state == "restored", "崩溃恢复完成结果持久化")
    }
    do {
        let f = Fixture()
        f.persisted = .init(entries:[.init(id:UUID(), profileID:profile, binding:binding, original:original,
            requested:try original.requested(speed:2, acceleration:1), created:Date(), state:"prepared")])
        f.values = .init(accelerationKey:original.accelerationKey,resolution:13107200,acceleration:32768)
        let recovered = f.controller();recovered.recover()
        try check(f.values == original, "写入与读回之间崩溃，prepared日志也能恢复部分修改")
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()]);f.disconnected = true;c.stop()
        try check(f.persisted?.entries.first?.state == "restoring", "断开时无法读写，保留待恢复原值而非标记通过")
        let writes = f.writeNumber
        c.reconcile([.init(profileID:UUID(),binding:.init(deviceID:binding.deviceID,serviceID:202),speed:2,acceleration:1)])
        try check(f.writeNumber == writes && !f.writtenBindings.contains{$0.serviceID == 202}, "断开恢复绝不转投替代设备服务")
        f.disconnected = false;c.stop();try check(f.values == original, "同一精确接口重新可读时完成待恢复事务")
    }
    do {
        let f=Fixture(),c=f.controller();c.reconcile([request()]);f.missingOriginal=true;c.reconcile([request()])
        try check(c.appliedBindings.isEmpty && f.persisted?.entries.first?.needsRecovery == true, "活动读回失效后不继续宣称已应用，原值恢复记录保留")
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()])
        f.values = .init(accelerationKey:original.accelerationKey,resolution:12345678,acceleration:65536)
        c.stop()
        try check(f.values.resolution == 12345678 && f.values.acceleration == original.acceleration, "外部更改的速度保留，只恢复仍归本应用的加速度")
        try check(f.persisted?.entries.first?.state == "conflict", "外部更改记录作为冲突保留")
        let writes = f.writeNumber;c.reconcile([request()])
        try check(f.writeNumber == writes, "暂停/重启不隐式授权覆盖外部变化")
        c.reconcile([]);try check(f.persisted?.entries.first?.state == "released", "明确关闭该配置才解除冲突暂停")
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()]);f.values = original
        c.reconcile([request()]);let writes = f.writeNumber
        try check(f.persisted?.entries.first?.state == "conflict", "外部重置到原值也持久标记暂停")
        let restarted = f.controller();restarted.reconcile([request()])
        try check(f.writeNumber == writes, "重启不会覆盖外部恢复的原值")
    }
    do {
        let f = Fixture();f.clampWrite = 2
        let c = f.controller();c.reconcile([request()])
        try check(f.values.resolution == original.resolution && f.values.acceleration == 65543 && c.appliedBindings.isEmpty, "不一致读回停止成功状态、保留未知新值、恢复已知自有值")
    }
    do {
        let f = Fixture(), c = f.controller();c.reconcile([request()]);c.reconcile([request(),request(3)])
        try check(f.values == original && c.appliedBindings.isEmpty, "重复调校配置先恢复旧修改后拒绝执行")
    }
    do {
        let f = Fixture();f.persisted = .init(schema:2)
        let c = f.controller();c.reconcile([request()]);try check(f.writeNumber == 0 && f.persisted?.schema == 2, "过新恢复资料不作为空白覆盖")
        for speed in [Double.nan, .infinity, 0, 9] {
            do {_ = try original.requested(speed:speed,acceleration:1);throw TestFailure(errorDescription:"invalid speed accepted")}
            catch is HIDTrackingFailure {checks += 1}
        }
    }
    do {
        let f = Fixture();f.bootSession="new-boot"
        let oldBinding=HIDTrackingBinding(deviceID:binding.deviceID,serviceID:101,bootSession:"old-boot")
        f.persisted = .init(entries:[.init(id:UUID(),profileID:profile,binding:oldBinding,original:original,
            requested:try original.requested(speed:2,acceleration:1),created:Date(),state:"active")])
        f.disconnected=true
        let c=f.controller();c.recover()
        try check(f.writeNumber == 0 && f.persisted?.entries.first?.state == "retired", "已证明系统重启后，旧接口只保留原值证据，不追到新设备")
        try check(c.status.contains("未向新设备写入"), "重启失效不会假报旧硬件原值已恢复")
    }
    print("PASS: \(checks)项逐设备调校事务、持久备份、读回、失败/停用/断开及崩溃恢复定向检查；仅合成后端，未写入真实系统参数、未启动GUI或冒烟")
}
