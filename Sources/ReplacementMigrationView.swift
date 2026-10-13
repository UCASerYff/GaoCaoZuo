import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct ReplacementMigrationView: View {
    @ObservedObject var store: OperationStore
    @State private var receipt: ReplacementMigrationReceipt?
    @State private var error: String?
    var body: some View {
        Section("原软件配置迁移") {
            Text("从已核验的安全备份导入文件模板、菜单与输入规则。迁移保留当前资料和后续修改；未确认的项目继续保留原软件。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导入已核验的迁移文件…") { importFile() }.disabled(!store.dataHealthy)
                Button("刷新迁移状态") { refresh() }
            }
            if let receipt {
                LabeledContent("配置迁移",value:receipt.state == "complete" ? "已提交" : receipt.state == "restored" ? "已恢复迁移前配置" : "尚未提交")
                Text(String(format:L10n.text("模板 %d · 图标 %d · 应用 %d"),receipt.templateCount,receipt.iconCount,receipt.appCount)).font(.caption)
                Text(String(format:L10n.text("输入规则：新增 %d · 升级 %d · 保留 %d · 待核验 %d"),receipt.rulesAdded,receipt.rulesUpgraded,receipt.rulesPreserved,receipt.rulesBlocked)).font(.caption)
                if receipt.verifiedEmptyPasswordBooks {Text("旧压缩密码本已核验为空；原钥匙串凭据保留。").font(.caption).foregroundStyle(.secondary)}
                Text("原软件继续保留，待全部替代功能和实机验收通过后再卸载。").font(.callout).foregroundStyle(.orange)
                if !receipt.retainedUserChanges.isEmpty { Text("已保留迁移后的用户修改。").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("迁移详情与待验项目") {
                    ForEach(Array(receipt.notes.enumerated()),id:\.offset) {_,note in Text(note).font(.caption).textSelection(.enabled)}
                }
            }
            if let error {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
        }.onAppear{refresh()}
    }
    private func refresh() {
        do { receipt=try store.data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self);error=nil }
        catch {self.error=error.localizedDescription}
    }
    private func importFile() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.propertyList];panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
        do {try store.importReplacementSettings(url);refresh()} catch {self.error=error.localizedDescription}
    }
}
