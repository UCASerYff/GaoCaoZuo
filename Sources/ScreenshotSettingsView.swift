import SwiftUI
import AppKit
import AVFoundation

struct ScreenshotSettingsView: View {
    @ObservedObject var model: ScreenshotAppModel
    @ObservedObject private var store: ScreenshotLocalStore
    @State private var migrationPlan: ScreenshotMigrationPlan?
    @State private var migrationBusy = false
    @State private var migrationMessage: String?
    @State private var recoveryMigrationID = ""
    init(model: ScreenshotAppModel) { self.model = model; store = model.store }
    var body: some View {
        Form {
            migrationSection
            Section("截图后") {
                Picker("默认动作", selection: $store.settings.captureStrategy) { Text("进入标注").tag("标注"); Text("复制").tag("复制"); Text("保存到所选目录").tag("保存") }
                HStack { Text(store.settings.saveDirectory == nil ? "保存目录未选择" : "已选择保存目录"); Button("选择目录…") { chooseDirectory() } }
                HStack { Text(store.settings.editorPath == nil ? "编辑 App 未选择" : "已选择编辑 App"); Button("选择 App…") { chooseEditor() } }
            }.disabled(!store.writable || migrationBusy || model.moduleBackupActive)
            Section("OCR 与私密资料") {
                TextField("语言（逗号分隔）", text: Binding(get: { store.settings.languages.joined(separator: ",") }, set: { store.settings.languages = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }))
                Toggle("静默截图 OCR 完成后复制文字", isOn: $store.settings.silentOCRCopies)
                Toggle("主动启用截图历史", isOn: $store.settings.historyEnabled)
                Stepper("历史保留 \(store.settings.historyDays) 天", value: $store.settings.historyDays, in: 1...3650)
                Stepper("历史容量 \(store.settings.historyCapacityMB) MiB", value: $store.settings.historyCapacityMB, in: 16...16384, step: 16)
                Button("删除截图历史…", role: .destructive) { deleteHistory() }
            }.disabled(!store.writable || migrationBusy || model.moduleBackupActive)
            Section("权限") {
                Text("屏幕捕获：\(CGPreflightScreenCaptureAccess() ? "已获权" : "未获权")；麦克风：\(microphoneStatus)")
                Button("打开屏幕录制设置") { model.screenSettings() }
                Button("复制本次权限状态") { model.copyPermissionStatus() }
                Button("请求长截图滚动权限") { let granted = ScreenshotPermissionService.requestScrolling(); model.message = granted ? "已允许用户主动触发的长截图滚动。" : "请在系统辅助功能设置中确认授权；也可继续手动滚动逐帧捕获。" }
                Text("屏幕、系统声音与麦克风仅在明确操作后采集。辅助功能用于长截图滚动；快捷键由搞操作统一配置。").font(.caption)
                Text("外接屏幕与外置音频设备专项验收不做（用户取消）。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存截图设置") { guard model.canBeginOperation()else{return};do { try store.saveSettings(); model.message = "截图设置已保存。" } catch { model.fail(error) } }.disabled(!store.writable || migrationBusy || model.moduleBackupActive)
                Spacer()
                Text("搞操作 V\(ScreenshotAppVersion.version) / build \(ScreenshotAppVersion.build)").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
    @ViewBuilder private var migrationSection: some View {
        Section("截图资料与迁移") {
            if let issue = store.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            Text(store.writable ? "截图资料已在搞操作的独立目录中保护。历史采集仍按原开关执行。" : "资料未完成初始化时保持只读；先预览来源与冲突，再明确迁移或初始化。不能将无法读取的旧资料当作空白。").font(.callout)
            HStack {
                Button("预览截图资料迁移") { previewMigration() }
                Button("确认备份并迁移…") { applyMigration() }.disabled(migrationPlan == nil || migrationPlan?.conflicts.isEmpty == false)
                if !store.writable { Button("无旧资料时初始化…") { initializeFresh() } }
            }.disabled(migrationBusy)
            if migrationBusy { ProgressView().controlSize(.small) }
            if let migrationPlan {
                Text("迁移编号：\(migrationPlan.migrationID)").font(.caption).textSelection(.enabled)
                Text("来源摘要：\(migrationPlan.sourceSHA256)").font(.caption).textSelection(.enabled)
                Text("\(migrationPlan.fileCount) 个文件 · \(migrationPlan.totalBytes) 字节").font(.caption)
                if !migrationPlan.conflicts.isEmpty { ForEach(migrationPlan.conflicts, id: \.self) { Text("冲突：" + $0).foregroundStyle(.red).textSelection(.enabled) } }
                if !migrationPlan.retainedOnly.isEmpty { DisclosureGroup("仅保留归档的来源内容") { ForEach(migrationPlan.retainedOnly, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } } }
            }
            DisclosureGroup("中断迁移恢复") {
                TextField("已记录的迁移编号",text:$recoveryMigrationID)
                HStack {
                    Button("恢复该次迁移…"){recoverMigration()}.disabled(recoveryMigrationID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || migrationBusy)
                    Button("显示迁移归档位置"){NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:store.migrationConfiguration.archiveRoot.path)}
                }
                Text("仅恢复明确指定且通过摘要核验的本模块事务；不会恢复整份宿主数据库或自动重放旧请求。").font(.caption).foregroundStyle(.secondary)
            }
            if let migrationMessage { Text(migrationMessage).font(.callout).textSelection(.enabled) }
        }
    }
    private func ensureIdle() -> Bool {
        if let reason=model.operationBlockingReason?(){migrationMessage=reason;return false}
        if let reason = model.terminationBlockReason { migrationMessage = reason; return false }
        return true
    }
    private func previewMigration() {
        guard ensureIdle() else { return }
        migrationBusy=true;model.moduleMigrationActive=true
        let configuration=store.migrationConfiguration,work=model.beginAuxiliaryWork("核验截图迁移来源")
        Task{@MainActor in
            defer{migrationBusy=false;model.moduleMigrationActive=false;model.endAuxiliaryWork(work)}
            do{let plan=try await Task.detached(priority:.userInitiated){try ScreenshotMigration(configuration:configuration).preview()}.value;migrationPlan=plan;recoveryMigrationID=plan.migrationID;migrationMessage="预览只核对来源、摘要与冲突，未修改来源资料。";model.message=migrationMessage ?? ""}
            catch{migrationPlan=nil;migrationMessage=error.localizedDescription;model.message=error.localizedDescription}
        }
    }
    private func applyMigration() {
        guard ensureIdle(), let plan = migrationPlan, plan.conflicts.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "备份并迁移已预览的截图资料？"; alert.informativeText = "将再次核对来源摘要，完整备份并迁移到搞操作。来源资料、附件、历史归档与原钥匙串保留。来源改变或出现冲突时停止。"; alert.addButton(withTitle: "确认备份并迁移"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,ensureIdle() else { return }
        migrationBusy = true;model.moduleMigrationActive=true
        let work = model.beginAuxiliaryWork("备份并迁移截图资料"),configuration=store.migrationConfiguration
        Task { @MainActor in
            defer { store.reloadAfterMigration();model.exchange.reloadStore();migrationBusy=false;model.moduleMigrationActive=false;model.endAuxiliaryWork(work) }
            do { _ = try await Task.detached(priority:.userInitiated){try ScreenshotMigration(configuration:configuration).apply(plan,approvedDigest:plan.approvalDigest)}.value;migrationPlan=nil;migrationMessage="资料迁移完成并已重新核验。来源与完整备份保留。";model.message=migrationMessage ?? "" }
            catch { migrationMessage=error.localizedDescription;model.message=error.localizedDescription }
        }
    }
    private func recoverMigration() {
        guard ensureIdle() else{return}
        let id=recoveryMigrationID.trimmingCharacters(in:.whitespacesAndNewlines)
        let alert=NSAlert();alert.messageText="恢复指定的截图资料迁移？";alert.informativeText="只核验并恢复迁移编号 "+id+" 的本模块事务。来源、完整备份与宿主其他资料保留。";alert.addButton(withTitle:"核验并恢复迁移");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn,ensureIdle() else{return}
        migrationBusy=true;model.moduleMigrationActive=true;let work=model.beginAuxiliaryWork("恢复截图资料迁移"),configuration=store.migrationConfiguration
        Task{@MainActor in
            defer{store.reloadAfterMigration();model.exchange.reloadStore();migrationBusy=false;model.moduleMigrationActive=false;model.endAuxiliaryWork(work)}
            do{_ = try await Task.detached(priority:.userInitiated){try ScreenshotMigration(configuration:configuration).recover(migrationID:id)}.value;migrationPlan=nil;migrationMessage="指定迁移已恢复并重新核验；来源与归档保留。";model.message=migrationMessage ?? ""}catch{migrationMessage=error.localizedDescription;model.message=error.localizedDescription}
        }
    }
    private func initializeFresh() {
        guard ensureIdle() else { return }
        let alert = NSAlert(); alert.messageText = "仅在确无旧截图资料时初始化？"; alert.informativeText = "程序会检查旧资料、备份与偏好。发现任何来源或无法读取的内容都会停止；不会用空白设置覆盖。"; alert.addButton(withTitle: "检查并初始化"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,ensureIdle() else { return }
        migrationBusy=true;model.moduleMigrationActive=true;let work=model.beginAuxiliaryWork("初始化截图资料"),configuration=store.migrationConfiguration
        Task{@MainActor in
            defer{store.reloadAfterMigration();model.exchange.reloadStore();migrationBusy=false;model.moduleMigrationActive=false;model.endAuxiliaryWork(work)}
            do{try await Task.detached(priority:.userInitiated){try ScreenshotMigration(configuration:configuration).initializeFresh()}.value;migrationMessage="已明确初始化截图资料；不会自动采集屏幕、声音、剪贴板或历史。";model.message=migrationMessage ?? ""}catch{migrationMessage=error.localizedDescription;model.message=error.localizedDescription}
        }
    }
    private var microphoneStatus: String { switch ScreenshotPermissionService.microphoneStatus { case .authorized: return "已获权"; case .denied: return "拒绝"; case .restricted: return "受限"; default: return "未申请" } }
    private func chooseDirectory() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { store.settings.saveDirectory = panel.url?.path } }
    private func chooseEditor() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; if panel.runModal() == .OK { store.settings.editorPath = panel.url?.path } }
    private func deleteHistory() { guard ensureIdle(),model.canBeginOperation() else{return};let alert = NSAlert(); alert.messageText = "删除本应用保存的截图历史？"; alert.informativeText = "原用户文件不受影响；内部恢复副本会保留在 DeletedHistory。"; alert.addButton(withTitle: "删除历史"); alert.addButton(withTitle: "取消"); if alert.runModal() == .alertFirstButtonReturn { do { try store.deleteHistory() } catch { model.fail(error) } } }
}
