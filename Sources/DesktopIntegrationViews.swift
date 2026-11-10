import AppKit
import SwiftUI

extension OperationStore {
    func applyLegacyDesktopImport(_ plan: LegacyDesktopImportPlan) throws -> LegacyDesktopImportResult {
        guard dataHealthy else { throw DataFailure.message("资料保护模式下不能迁移。") }
        do {
            let result = try LegacyDesktopMigrationImporter(targetData: data).applyConfirmed(plan: plan, currentSettings: settings, approvedPlanDigest: plan.approvalDigest)
            adoptCommittedDesktopSettings(result.settings)
            return result
        } catch let committed as LegacyDesktopCommittedImportError {
            adoptCommittedDesktopSettings(committed.committedSettings)
            throw committed
        } catch {
            // A rename may have committed settings before journal fsync failed.
            // Reload the actual guarded file; never write the old in-memory value.
            do {
                guard let actual = try data.load("settings.json", as: OperationSettings.self) else {
                    throw DataFailure.message("迁移后设置缺失，已停止写入。")
                }
                adoptCommittedDesktopSettings(actual)
            } catch { data.block(error.localizedDescription) }
            throw error
        }
    }
    func adoptLegacyOverviewHotkey(_ offer: LegacyDesktopHotkeyOffer) throws {
        guard dataHealthy else { throw DataFailure.message("资料保护模式下不能启用快捷键。") }
        let candidate = InputBinding(actionID: "windows.overview", keyCode: offer.keyCode, modifiers: offer.targetModifiers)
        if settings.bindings.contains(where: { $0.enabled && $0.actionID == "windows.overview" && InputRules.signature($0) == InputRules.signature(candidate) }) { return }
        let conflicts = settings.bindings.filter { $0.enabled && $0.trigger == .hotkey && $0.keyCode == candidate.keyCode && ($0.modifiers & InputRules.modifierMask) == (candidate.modifiers & InputRules.modifierMask) }
        let advanced = settings.inputEnhancements.rules.contains { rule in
            rule.enabled && [.keyDown, .keyUp, .keyHold, .keyReplacement].contains(rule.trigger) && rule.keyCode == candidate.keyCode && (rule.modifiers & InputRules.modifierMask) == (candidate.modifiers & InputRules.modifierMask)
        }
        guard conflicts.isEmpty && !advanced else { throw DataFailure.message("原总览快捷键与现有规则冲突；请在快捷键与手势中选择新组合，原规则没有被覆盖。") }
        var next = settings; next.bindings.append(candidate)
        try data.save(next, name: "settings.json")
        adoptCommittedDesktopSettings(next)
    }
}

struct IntegratedDesktopSettingsView: View {
    @ObservedObject var store: OperationStore
    @State private var plan: LegacyDesktopImportPlan?
    @State private var adoptSource = false
    @State private var message: String?
    @State private var records: [LegacyDesktopMigrationRecord] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("桌面与窗口总览").font(.title2.bold())
                Text("窗口列表、搜索和聚焦使用辅助功能；内容预览仅在总览里由你主动授权并生成一次。关闭总览后清除预览，不保存窗口标题和像素。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开窗口总览") { _ = store.openDesktopAction("windows.overview") }
                Divider()
                if records.contains(where: { $0.sourceRetirement != nil }) {
                    Text("搞桌面设置已迁入").font(.headline)
                    Text("来源证据已封存；迁入后的窗口偏好和快捷键选择继续使用，下方保留来源身份与处理事实。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Text("从搞桌面导入").font(.headline)
                Toggle("采用来源窗口总览设置", isOn: $adoptSource).onChange(of: adoptSource) { _, _ in plan = nil }
                Text("先核对来源设置、初始化依据和摘要。现有偏好优先；原热键始终单独确认，不自动抢占。来源工作区、外观与旧能力记录不会成为目标的目录授权或验收依据。来源退役后，仅保留迁入标识、来源身份摘要和处理事实。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("读取来源并预览迁移") {
                    do {
                        plan = try LegacyDesktopMigrationImporter(targetData: store.data).preview(source: .standard, currentSettings: store.settings, adoptSourceOverview: adoptSource)
                        message = nil
                    } catch { plan = nil; message = error.localizedDescription }
                }.disabled(!store.dataHealthy)
                if let plan {
                    Text("搞桌面 V\(plan.identity.appVersion) · schema \(plan.identity.schemaVersion) · 第 \(plan.identity.generation) 代设置").font(.caption)
                    Text("来源总览快捷键：\(plan.hotkeyOffer.displayName)，导入不会自动启用。")
                    ForEach(plan.conflicts) { conflict in Text(conflict.field + "：" + conflict.reason).font(.caption).foregroundStyle(.orange) }
                    Button("确认合并，保留现有冲突设置") {
                        do {
                            let result = try store.applyLegacyDesktopImport(plan)
                            message = result.alreadyApplied ? "这份设置已经迁入，未重复写入。" : "已合并并核验；来源程序与资料仍保留，退役由协调流程处理。"
                            self.plan = nil; reloadRecords()
                        } catch { message = error.localizedDescription }
                    }.disabled(!store.dataHealthy)
                }
                }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
                ForEach(records.filter { $0.phase == .committed }) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已迁入设置：\(record.source.appVersion) / generation \(record.source.generation)").font(.caption)
                        if record.sourceEvidence == nil {
                            Text("来源证据已封存为不可恢复摘要；当前偏好和迁入快捷键选择继续保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if record.hotkeyOffer.enabledInSource {
                            Button("单独启用原总览快捷键 " + record.hotkeyOffer.displayName) {
                                do { try store.adoptLegacyOverviewHotkey(record.hotkeyOffer); message = "已保存总览快捷键；注册结果见快捷键与手势页，系统占用时不会取代其他规则。" }
                                catch { message = error.localizedDescription }
                            }.disabled(!store.dataHealthy)
                        }
                    }
                }
                Divider()
                DesktopProviderHistoryView(provider: store.desktopProvider, open: store.openDesktopAction)
            }.padding(12)
        }.onAppear { reloadRecords() }
    }
    private func reloadRecords() {
        do { records = try LegacyDesktopMigrationImporter(targetData: store.data).records(currentSettings: store.settings) }
        catch { message = error.localizedDescription }
    }
}

struct IntegratedLockSettingsView: View {
    @ObservedObject var store: OperationStore
    @ObservedObject private var controller: LocalLockController
    @State private var confirmManual = false
    @State private var manualAction: LocalLockAction = .lockScreen
    init(store: OperationStore) { self.store = store; controller = store.localLock }
    private func setting<T>(_ path: WritableKeyPath<LocalLockConfiguration, T>) -> Binding<T> {
        Binding(get: { store.settings.localLock[keyPath: path] }, set: { value in store.update { $0.localLock[keyPath: path] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("本机锁屏与闲置策略").font(.title2.bold())
                Text("锁屏提交系统 Control-Command-Q 请求，需要辅助功能。屏保不等于锁屏，是否要求密码仍由系统设置决定；本应用不保存密码、不自动解锁，也不改变系统安全策略。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("手动锁屏…") { manualAction = .lockScreen; confirmManual = true }
                    Button("启动屏保…") { manualAction = .screenSaver; confirmManual = true }
                }
                Divider()
                Toggle("启用本机闲置策略（默认关闭）", isOn: setting(\.enabled)).disabled(!store.dataHealthy)
                Stepper(value: setting(\.idleSeconds), in: 30...86400, step: 30) { Text("闲置 \(Int(store.settings.localLock.idleSeconds)) 秒后预告") }.disabled(!store.dataHealthy)
                Stepper(value: setting(\.warningSeconds), in: 5...120, step: 5) { Text("预告 \(Int(store.settings.localLock.warningSeconds)) 秒") }.disabled(!store.dataHealthy)
                Picker("闲置动作", selection: setting(\.action)) { ForEach(LocalLockAction.allCases) { value in Text(value.title).tag(value) } }.disabled(!store.dataHealthy)
                Text(controller.state.title).font(.headline)
                Text(controller.state.detail).foregroundStyle(.secondary)
                HStack {
                    Button("取消本次倒计时") { controller.cancelPending() }
                    Button("恢复观察") { controller.resume() }
                }
                Text("文件、压缩、粘贴核对或交接进行时暂停；睡眠、显示器睡眠或会话切换后重新等待完整闲置周期。硬件在场、蓝牙锁定及自动解锁不做（用户取消）。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("本次运行记录（退出后清除）").font(.headline)
                ForEach(controller.events.reversed()) { event in Text(event.message).font(.caption) }
            }.padding(20)
        }.confirmationDialog(manualAction.title + "？", isPresented: $confirmManual) {
            Button("确认" + manualAction.title) {
                do { try controller.requestNow(manualAction) }
                catch { store.notify(error.localizedDescription, failed: true) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("锁屏请求可能立即结束当前交互，请先保存工作。系统结果未确认前不会显示已经锁定。") }
    }
}
