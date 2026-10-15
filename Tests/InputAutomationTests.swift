import Foundation
import ApplicationServices

/// Deterministic rule/feedback/trigger tests. Does not install observers, select a TIS source or show a HUD.
func runInputAutomationTests() throws {
    var checks = 0
    func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw InputAutomationError.invalid("输入自动化测试失败：" + label) }; checks += 1
    }
    func rejects(_ body: () throws -> Void, _ label: String) throws {
        do { try body() } catch { checks += 1; return }
        throw InputAutomationError.invalid("输入自动化测试未拒绝：" + label)
    }
    let decoder = JSONDecoder(), encoder = JSONEncoder()
    var auto = AutoInputConfiguration(), fly = FlyKeyConfiguration()
    try expect(!auto.enabled && !fly.enabled, "新增自动化默认关闭")
    try expect(try decoder.decode(AutoInputConfiguration.self, from: encoder.encode(auto)) == auto, "自动输入法配置持久往返")
    try expect(try decoder.decode(FlyKeyConfiguration.self, from: encoder.encode(fly)) == fly, "FlyKey配置持久往返")
    let oldConfiguration = Data("{\"schemaVersion\":1,\"enabled\":false,\"manualOverrideSeconds\":5,\"rules\":[]}".utf8)
    let oldConfigured = try decoder.decode(AutoInputConfiguration.self, from: oldConfiguration)
    try expect(oldConfigured.manualPrimarySourceID == nil && oldConfigured.manualSecondarySourceID == nil, "旧配置不默认选择手动源")
    auto.manualPrimarySourceID = "source.explicit"; try auto.validate(); checks += 1
    auto.manualSecondarySourceID = "source.explicit"; try rejects({ try auto.validate() }, "成对源不得相同")
    auto.manualSecondarySourceID = "source.missing-but-preserved"
    try expect(try decoder.decode(AutoInputConfiguration.self, from: encoder.encode(auto)) == auto, "缺失手动源ID保留不替换")
    auto = .init()
    auto.schemaVersion = 2; try rejects({ try auto.validate() }, "未来自动输入法schema")
    auto = .init(); auto.manualOverrideSeconds = .infinity; try rejects({ try auto.validate() }, "无限暂缓时间")
    fly.schemaVersion = 2; try rejects({ try fly.validate() }, "未来FlyKey schema")
    fly = .init(); fly.doubleTapInterval = 0; try rejects({ try fly.validate() }, "零双击间隔")
    let fixedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let old = Data("{\"id\":\"\(fixedID.uuidString)\",\"appBundleID\":\"a.app\",\"appName\":\"A\",\"targetSourceID\":\"source.a\",\"targetSourceName\":\"A\",\"enabled\":true}".utf8)
    let legacy = try decoder.decode(InputSourceRule.self, from: old)
    try expect(legacy.priority == 0 && legacy.focusedRole == nil && legacy.id == fixedID, "旧规则保留身份及默认优先级")
    let oldDescriptor = Data("{\"id\":\"com.apple.keylayout.ABC\",\"name\":\"ABC\",\"isSelectCapable\":true,\"isEnabled\":true,\"category\":\"keyboard\",\"shortLabel\":\"ABC\"}".utf8)
    try expect(!(try decoder.decode(InputSourceDescriptor.self, from: oldDescriptor)).isInputMethod, "旧源描述兼容")
    let global = InputSourceRule(appBundleID: "*", targetSourceID: "source.global", priority: 1000)
    let app = InputSourceRule(appBundleID: "a.app", targetSourceID: "source.app")
    let area = InputSourceRule(appBundleID: "a.app", targetSourceID: "source.area", priority: -1000, focusedRole: "AXTextArea")
    try expect(InputSourceRulePolicy.resolve([global, app, area], bundleID: "a.app", focusedRole: "AXTextArea") == .rule(area.id), "App区域最高具体度")
    try expect(InputSourceRulePolicy.resolve([global, app, area], bundleID: "a.app", focusedRole: "AXTextField") == .rule(app.id), "App规则高于全局高优先级")
    try expect(InputSourceRulePolicy.resolve([global, app], bundleID: "b.app", focusedRole: nil) == .rule(global.id), "仅显式全局回退")
    var conflict = app; conflict.id = UUID(); conflict.targetSourceID = "source.other"
    try expect(InputSourceRulePolicy.resolve([app, conflict], bundleID: "a.app", focusedRole: nil) == .conflict([app.id, conflict.id]), "同级冲突禁止隐式选择")
    conflict.priority = 1
    try expect(InputSourceRulePolicy.resolve([app, conflict], bundleID: "a.app", focusedRole: nil) == .rule(conflict.id), "显式优先级")
    conflict.enabled = false
    try expect(InputSourceRulePolicy.resolve([conflict], bundleID: "a.app", focusedRole: nil) == .none, "暂停规则不执行")
    auto = .init(); auto.rules = [app, app]; try rejects({ try auto.validate() }, "重复规则身份")
    auto.rules = [app]; auto.rules[0].focusedRole = "AXSecureTextField"; try rejects({ try auto.validate() }, "密码区域不可配置")
    auto.rules[0].focusedRole = nil; auto.rules[0].targetSourceID = ""; try rejects({ try auto.validate() }, "不得隐式选择任意输入源")
    var changes = InputSourceChangeTracker(observedID: "source.a")
    changes.expect("source.b", now: 10)
    try expect(changes.observe("source.b", now: 10.2) == .automated && changes.lastExternalChange == nil, "延迟自动切源通知不启动手动冷却")
    try expect(changes.observe("source.b", now: 10.3) == .unchanged, "重复TIS通知无反馈循环")
    try expect(changes.observe("source.c", now: 11) == .external && changes.lastExternalChange == 11, "实际外部切源启动暂缓")
    changes.expect("source.d", now: 12)
    try expect(changes.observe("source.e", now: 12.1) == .external, "不同的手动切源不吞掉")
    changes.expect("source.f", now: 13)
    try expect(changes.observe("source.f", now: 15) == .external, "过期自动回执不可信")
    func decision(enabled: Bool = true, secure: Bool = false, lastManual: Double? = nil, lastTyping: Double? = nil,
                  composition: InputSourceSwitchPolicy.Composition = .clear, ime: Bool = false, editable: Bool = true) -> InputSourceSwitchPolicy.Decision {
        InputSourceSwitchPolicy.decide(enabled: enabled, secure: secure, now: 100, lastManual: lastManual, grace: 5,
                                       lastTyping: lastTyping, composition: composition, sourceIsIME: ime, editable: editable)
    }
    try expect(decision(enabled: false) == .disabled, "关闭即不切源")
    try expect(decision(secure: true) == .secure, "安全输入保护")
    try expect(decision(lastManual: 98) == .manualOverride, "手动冷却实际应用")
    try expect(decision(lastManual: 90) == .allow, "过期冷却可恢复")
    try expect(decision(lastTyping: 99.8) == .typing, "近期键入延后")
    try expect(decision(composition: .active) == .composition, "IME未提交组合保护")
    try expect(decision(composition: .unknown, ime: true) == .unknownComposition, "未公开组合态不当空白")
    try expect(decision(composition: .unknown, ime: false) == .allow, "键盘布局不虚构IME组合")
    try expect(decision(composition: .unknown, ime: true, editable: false) == .allow, "非编辑区域不阻碍App规则")
    try expect(AXMenuItemModifiers.shift.rawValue == 1 && AXMenuItemModifiers.option.rawValue == 2
               && AXMenuItemModifiers.control.rawValue == 4 && AXMenuItemModifiers.noCommand.rawValue == 8, "本机SDK AX修饰位")
    try expect(FlyKeyShortcutFormatter.format(character: "a", modifiers: 0) == "⌘A", "AX默认Command")
    try expect(FlyKeyShortcutFormatter.format(character: "a", modifiers: 1) == "⇧⌘A", "AX Shift")
    try expect(FlyKeyShortcutFormatter.format(character: "a", modifiers: 2) == "⌥⌘A", "AX Option")
    try expect(FlyKeyShortcutFormatter.format(character: "a", modifiers: 4) == "⌃⌘A", "AX Control")
    try expect(FlyKeyShortcutFormatter.format(character: "a", modifiers: 8) == "A", "AX NoCommand")
    try expect(FlyKeyShortcutFormatter.format(character: "x", modifiers: 15) == "⌃⌥⇧X", "完整AX修饰位")
    try expect(FlyKeyShortcutFormatter.format(character: "x", modifiers: 16).isEmpty, "未知AX修饰位不猜测")
    var taps = FlyKeyTapDetector()
    func tap(_ key: UInt16 = 55, down: Double, release: Double, flags: UInt64 = 1 << 20, secure: Bool = false) -> Bool {
        _ = taps.flagsChanged(key: key, flags: flags, now: down, modifier: .command, interval: 0.35, secure: secure)
        return taps.flagsChanged(key: key, flags: 0, now: release, modifier: .command, interval: 0.35, secure: secure)
    }
    try expect(!tap(down: 1, release: 1.05), "第一次独立Command不触发")
    try expect(tap(down: 1.15, release: 1.2), "两次短按释放才触发")
    try expect(!tap(down: 2, release: 2.05) && !tap(down: 2.5, release: 2.55), "间隔过长不触发")
    taps.reset(); _ = tap(down: 3, release: 3.05)
    try expect(!tap(54, down: 3.1, release: 3.15), "左右Command混按不触发")
    taps.reset(); _ = tap(down: 4, release: 4.05)
    try expect(!tap(down: 4.1, release: 4.8), "长按第二次不触发")
    taps.reset(); _ = tap(down: 5, release: 5.05)
    try expect(!tap(down: 5.1, release: 5.15, flags: (1 << 20) | (1 << 17)), "原App组合键不触发")
    taps.reset(); _ = tap(down: 6, release: 6.05)
    try expect(!tap(down: 6.1, release: 6.15, secure: true), "安全输入中清空触发器")
    taps.reset(); _ = tap(down: 7, release: 7.05); taps.reset()
    try expect(!tap(down: 7.1, release: 7.15), "其他输入显式打断探测")
    print("输入法规则、TIS反馈与FlyKey纯逻辑回归通过：\(checks)项；未切换系统输入源或启动GUI。")
}
