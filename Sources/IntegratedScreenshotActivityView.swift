import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct IntegratedScreenshotActivityView: View {
    @ObservedObject var model: ScreenshotAppModel
    @State private var index: ScreenshotMigratedActivityIndex?
    @State private var working = false
    @State private var notice: String?
    @State private var detail: String?

    var body: some View {
        GroupBox("迁入的恢复文件与历史交接") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("读取迁入记录") { reload() }
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("原身份与状态保留；历史交接不执行、不回送").font(.caption).foregroundStyle(.secondary)
                }
                if let index {
                    if index.entries.isEmpty { Text("没有迁入的活动记录。").foregroundStyle(.secondary) }
                    else {
                        List(index.entries) { entry in row(entry) }
                            .frame(minHeight: 160, maxHeight: 300)
                    }
                    if !index.blockers.isEmpty {
                        DisclosureGroup("尚不能退役：\(index.blockers.count) 项待处理") {
                            ForEach(index.blockers, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }.foregroundStyle(.red)
                    }
                    if let warnings = index.integrityWarnings, !warnings.isEmpty {
                        DisclosureGroup("历史完整性说明：\(warnings.count) 项") {
                            Text("获批保留的不完整历史仍保留缺失说明；批准仅影响指定的退役阻断项，不代表原事务完成。")
                                .font(.caption)
                            ForEach(warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }.foregroundStyle(.orange)
                    }
                } else { Text("读取后可查看原记录、导出附件，或明确打开恢复稿；不会重新执行原任务。").font(.caption) }
                if let notice { Text(notice).font(.caption).textSelection(.enabled) }
            }.disabled(working)
        }
        .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("原始只读记录").font(.headline)
                ScrollView { Text(detail ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("关闭") { detail = nil }
            }.padding(20).frame(minWidth: 600, minHeight: 380)
        }
    }

    @ViewBuilder private func row(_ entry: ScreenshotMigratedActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entryTitle(entry)).lineLimit(1)
                Spacer()
                Text("原状态：" + statusTitle(entry.status)).font(.caption).foregroundStyle(.secondary)
            }
            if let disposition = entry.historyDisposition {
                Text(dispositionTitle(disposition)).font(.caption).foregroundStyle(.orange)
            }
            Text(entry.handlingPath).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("查看原记录") { showRecord(entry) }
                Button("另存记录…") { saveRecord(entry) }
                if !entry.attachmentPaths.isEmpty {
                    Menu("导出附件") {
                        ForEach(entry.attachmentPaths, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) { exportAttachment(entry, path: path) }
                        }
                    }
                }
                if entry.kind == "ocr-recovery" { Button("打开 OCR 恢复稿") { openOCR(entry) } }
                if entry.kind == "recording-recovery" { Button("检查并另存录制恢复…") { recoverRecording(entry) } }
            }.controlSize(.small)
        }.padding(.vertical, 4)
    }

    private func statusTitle(_ raw: String) -> String {
        ["received":"已接收", "approved":"已确认", "executing":"执行中", "pending":"等待处理", "request":"请求记录", "completed":"已完成", "partial":"部分完成", "cancelled":"已取消", "failed":"失败", "unsupported":"不支持", "idle":"空闲，恢复待核验", "preparing":"准备中", "recording":"录制中", "paused":"已暂停", "stopping":"正在停止"][raw] ?? raw
    }
    private func dispositionTitle(_ raw: String) -> String {
        switch raw {
        case "approved-incomplete-history":
            return "历史记录不完整 · 已批准只读保留；原状态未变，缺失资料未补造"
        case "approved-no-continuation":
            return "已批准不接续 · 保留原状态与现有附件，不重放、不回送"
        default:
            return "历史处置：" + raw
        }
    }
    private func entryTitle(_ entry: ScreenshotMigratedActivityEntry) -> String {
        guard let action = entry.originalIdentity.action else { return entry.label }
        let names = ["capture.region":"区域截图", "capture.window":"窗口截图", "capture.display":"屏幕截图", "ocr.files":"文件文字识别", "images.annotate":"图片标注", "images.pin":"图片贴图", "text.translate":"文字翻译", "documents.open":"打开文档", "documents.newText":"新建文稿", "research.importDocuments":"研究文档导入"]
        let prefix = ["exchange-request":"历史请求", "exchange-result":"历史结果", "exchange-state":"历史交接状态"][entry.kind]
        guard let prefix else { return entry.label }
        return prefix + " · " + (names[action] ?? action)
    }
    private func begin(_ title: String, exclusive: Bool = false) -> UUID? {
        guard !working, model.canBeginOperation() else { return nil }
        guard !model.busy, !model.ocr.isRunning, !model.recording.isActive, !model.exchangeIsExecuting,
              model.externalAnnotation == nil, model.externalTranslation == nil, model.activeAuxiliaryWork.isEmpty else {
            notice = "请先完成当前截图工作，再处理迁入记录。"; return nil
        }
        if exclusive { model.willBeginExclusiveInput?() }
        working = true; notice = nil; model.importedActivityWorkActive = true
        return model.beginAuxiliaryWork(title, exclusiveInput: exclusive)
    }
    private func finish(_ work: UUID) { model.endAuxiliaryWork(work); model.importedActivityWorkActive = false; working = false }
    private func failed(_ error: Error) { notice = error.localizedDescription; model.message = error.localizedDescription }
    private func succeeded(_ text: String) { notice = text; model.message = text }

    private func reload() {
        guard let work = begin("核验迁入活动资料") else { return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                index = try await Task.detached(priority: .userInitiated) { try ScreenshotMigrationActivity.validate(root: root) }.value
                succeeded("迁入记录及附件已核对，未执行历史任务。")
            } catch { index = nil; failed(error) }
        }
    }
    private func showRecord(_ entry: ScreenshotMigratedActivityEntry) {
        guard let work = begin("读取迁入记录") else { return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                detail = try await Task.detached(priority: .userInitiated) {
                    let data = try ScreenshotMigrationActivity.readRecord(root: root, entryID: entry.id)
                    let prefix = String(decoding: data.prefix(65_536), as: UTF8.self)
                    return prefix + (data.count > 65_536 ? "\n\n仅预览前64KiB；可另存完整原记录。" : "")
                }.value
            } catch { failed(error) }
        }
    }
    private func saveRecord(_ entry: ScreenshotMigratedActivityEntry) {
        guard let work = begin("导出迁入记录", exclusive: true) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "迁入记录.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let output = panel.url, output.pathExtension.lowercased() != "gaoaction" else { finish(work); return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ScreenshotMigrationActivity.exportRecord(root: root, entryID: entry.id, to: output)
                }.value
                succeeded("已另存原始记录；没有生成或发送新交接。")
            } catch { failed(error) }
        }
    }
    private func exportAttachment(_ entry: ScreenshotMigratedActivityEntry, path: String) {
        guard let work = begin("导出迁入附件", exclusive: true) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        guard panel.runModal() == .OK, let output = panel.url else { finish(work); return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                try await Task.detached(priority: .userInitiated) { try ScreenshotMigrationActivity.exportAttachment(root: root, entryID: entry.id, relativePath: path, to: output) }.value
                succeeded("已导出所选附件，迁入原件保持不变。")
            } catch { failed(error) }
        }
    }
    private func openOCR(_ entry: ScreenshotMigratedActivityEntry) {
        guard let work = begin("读取 OCR 恢复稿") else { return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                let restored = try await Task.detached(priority: .userInitiated) { try IntegratedScreenshotRecovery.readOCR(root: root, entryID: entry.id) }.value
                // The internal replacement confirmation must pass its own module gate.
                // Its unsaved-review guard still blocks reentrant user operations.
                model.importedActivityWorkActive = false
                let approved = model.prepareToReplaceOCR()
                model.importedActivityWorkActive = true
                guard approved else { return }
                try await model.ocr.restore(restored.snapshot, sourceURLs: restored.sourceURLs)
                model.ocrCorrectionDrafts = [:]; model.markOCRSaved(restored.snapshot.document); model.tab = "OCR"
                succeeded("已打开保存的 OCR 恢复稿与原件；未重新识别，也不会向旧请求回送结果。")
            } catch { failed(error) }
        }
    }
    private func recoverRecording(_ entry: ScreenshotMigratedActivityEntry) {
        guard let work = begin("检查并恢复迁入录制", exclusive: true) else { return }
        let root = model.store.root
        Task { @MainActor in
            defer { finish(work) }
            do {
                let journal = try await Task.detached(priority: .userInitiated) { try ScreenshotMigrationActivity.recordingJournalURL(root: root, entryID: entry.id) }.value
                let inspection = try await ScreenshotRecordingRecovery.inspect(journal: journal)
                let alert = NSAlert(); alert.messageText = "迁入录制恢复检查"; alert.informativeText = inspection.reason
                alert.addButton(withTitle: inspection.canRecover ? "另存恢复副本" : "保留现用恢复文件"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard inspection.canRecover else { succeeded("现用恢复说明和媒体保持原样；未报告恢复成功。" ); return }
                let panel = NSSavePanel(); panel.nameFieldStringValue = "恢复录制." + inspection.mediaURL.pathExtension
                guard panel.runModal() == .OK, let output = panel.url else { return }
                _ = try await ScreenshotRecordingRecovery.recover(journal: journal, to: output)
                succeeded("已另存可解码的恢复副本，请完整回放核对；现用原件仍保留。")
            } catch { failed(error) }
        }
    }
}
