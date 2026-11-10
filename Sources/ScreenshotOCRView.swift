import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ScreenshotOCRView: View {
    @ObservedObject var model: ScreenshotAppModel
    @ObservedObject var controller: ScreenshotOCRController
    @State private var level = ScreenshotOCRRecognitionLevel.accurate
    @State private var contrast = false
    @State private var deskew = false
    @State private var isExporting = false
    @State private var exportProgress: ScreenshotOCRPDFExportProgress?
    @State private var exportCancellation: ScreenshotOCRCancellationToken?
    @State private var exportGeneration = UUID()
    @State private var showCorrections = false

    private var chosenOptions: ScreenshotOCROptions {
        var value = model.ocrOptions
        value.recognitionLevel = level
        value.enhanceContrast = contrast
        value.deskew = deskew
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputActions
            taskProgress
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let document = controller.document { documentContent(document) }
            else {
                ContentUnavailableView("选择文件开始识别", systemImage: "text.viewfinder", description: Text("Vision 在本机处理，原件不覆盖。复杂表格、数学、手写与阅读顺序须人工核对。"))
            }
            Text("当前策略实际支持语言：\(controller.supportedLanguages.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
        }
        .padding(24)
        .onChange(of: level) { controller.updateLanguages(for: level) }
        .onDisappear { exportCancellation?.cancel() }
        .sheet(isPresented: $showCorrections) { ScreenshotOCRCorrectionView(model:model,controller: controller) }
    }

    private var header: some View {
        HStack {
            Text("本机 OCR").font(.title)
            Spacer()
            Picker("策略", selection: $level) { ForEach(ScreenshotOCRRecognitionLevel.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 180)
            Toggle("增强对比", isOn: $contrast)
            Toggle("保守去倾斜", isOn: $deskew)
        }
        .disabled(controller.isRunning || isExporting)
    }

    private var inputActions: some View {
        HStack {
            Button("选择图像 / PDF 批次…", action: openFiles)
            Button("主动读取剪贴板图片", action: recognizeClipboard)
            Button("从当前图像识别", action: recognizeCurrentImage).disabled(model.annotation == nil)
            Button("重试未完成页") { if model.canBeginOperation(),model.prepareToReplaceOCR(){controller.retryFailed()} }
                .disabled(controller.document?.retryablePages.isEmpty != false)
        }
        .disabled(controller.isRunning || isExporting)
    }

    @ViewBuilder private var taskProgress: some View {
        if controller.isRunning, let progress = controller.progress {
            ProgressView(value: progress.fractionCompleted)
            HStack {
                Text("\(progress.completedPages)/\(progress.totalPages) 页 · 失败 \(progress.failedPages) · \(progress.sourceName)").font(.caption)
                Spacer(); Button("取消识别") { controller.cancel() }
            }
        } else if controller.isRunning {
            HStack { ProgressView().controlSize(.small); Text("检查原件、摘要和页面预算…"); Spacer(); Button("取消识别") { controller.cancel() } }
        }
        if isExporting {
            if let exportProgress { ProgressView(value: exportProgress.fractionCompleted); Text(exportProgress.description).font(.caption) }
            else { HStack { ProgressView().controlSize(.small); Text("检查原件并准备 PDF…") } }
            if exportCancellation != nil { Button("取消 PDF 导出") { exportCancellation?.cancel() } }
        }
    }

    private func documentContent(_ document: ScreenshotOCRDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("成功 \(document.successfulPages) / \(document.pages.count) 页\(document.isPartial ? " · 部分成功" : "")\(document.wasCancelled ? " · 已取消" : "")")
            if !document.retryablePages.isEmpty {
                DisclosureGroup("未完成页与原因（\(document.retryablePages.count)）") {
                    ForEach(document.retryablePages) { page in
                        Text("\(sourceName(page.sourceID, in: document)) · 第 \(page.pageNumber) 页：\(page.failureReason ?? page.status.rawValue)")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
            }
            ScrollView {
                Text(document.text.isEmpty ? "未识别出文字。" : document.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }.background(.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("复制文字") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(document.text, forType: .string) }.disabled(document.text.isEmpty)
                Button("逐行校正…") { showCorrections = true }.disabled(document.pages.allSatisfy { $0.lines.isEmpty })
                Menu("导出…") {
                    Button("纯文本") { export(.text) }
                    Button("Markdown") { export(.markdown) }
                    Button("结构化 JSON") { export(.json) }
                    Divider()
                    ForEach(document.sources) { source in Button("可搜索 PDF：\(source.displayName)") { exportPDF(source) }.disabled(source.sha256.isEmpty) }
                }
                Button("翻译结果") { model.setTranslationInput(document.text) }.disabled(document.text.isEmpty)
            }.disabled(controller.isRunning || isExporting)
        }
    }

    private func sourceName(_ id: UUID, in document: ScreenshotOCRDocument) -> String { document.sources.first { $0.id == id }?.displayName ?? "输入文件" }

    private func openFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .pdf]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, model.prepareToReplaceOCR() { controller.start(urls: panel.urls, options: chosenOptions) }
    }

    private func recognizeClipboard() {
        guard model.prepareToReplaceOCR()else{return}
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) else { model.message = "剪贴板没有可识别图像。"; return }
        controller.startImageData(data, options: chosenOptions)
    }

    private func recognizeCurrentImage() {
        guard let document = model.annotation,model.prepareToReplaceOCR() else { return }
        do { controller.startImageData(try ScreenshotPngData(document.flatten()), options: chosenOptions) }
        catch { model.fail(error) }
    }

    private func export(_ format: ScreenshotOCRExportFormat) {
        guard let document = controller.document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OCR." + (format == .text ? "txt" : format == .markdown ? "md" : "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true; exportProgress = nil; let generation = UUID(); exportGeneration = generation
        let work=model.beginAuxiliaryWork("导出 OCR")
        Task {
            defer { model.endAuxiliaryWork(work);if generation == exportGeneration { isExporting = false } }
            do { try await Task.detached(priority: .userInitiated) { try ScreenshotOCRExporter.export(document: document, format: format, to: url) }.value; model.markOCRSaved(document);model.message = "已导出并重新读取核验 OCR 结果。" }
            catch { model.fail(error) }
        }
    }

    private func exportPDF(_ source: ScreenshotOCRSource) {
        guard let document = controller.document, let original = controller.sourceURL(for: source.id) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "可搜索-\(URL(fileURLWithPath: source.displayName).deletingPathExtension().lastPathComponent).pdf"; panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cancellation = ScreenshotOCRCancellationToken(); exportCancellation = cancellation; exportProgress = nil; isExporting = true
        let generation = UUID(); exportGeneration = generation
        let work=model.beginAuxiliaryWork("导出可搜索 PDF",cancel:{cancellation.cancel()})
        Task {
            defer { model.endAuxiliaryWork(work);if generation == exportGeneration { isExporting = false; exportCancellation = nil } }
            do {
                let validation = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotOCRExporter.exportSearchablePDF(document: document, sourceID: source.id, sourceURL: original, to: url, cancellation: cancellation) { value in
                        Task { @MainActor in if generation == exportGeneration { exportProgress = value } }
                    }
                }.value
                let rebuilt = validation.rasterizedPages.isEmpty ? "" : "其中\(validation.rasterizedPages.count)页已按原页图像重建完整文字层；原件保留。"
                model.message = "已验证 \(validation.pageCount) 页、\(validation.verifiedTextLines) 行文本层、检索与页面位置。" + rebuilt
            } catch is CancellationError { model.message = "PDF 导出已取消；原件保留，未完成输出已清理。" }
            catch { model.fail(error) }
        }
    }
}

@MainActor
private struct ScreenshotOCRCorrectionView: View {
    @ObservedObject var model:ScreenshotAppModel
    @ObservedObject var controller: ScreenshotOCRController
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("校正识别文字").font(.title2)
            Text("尚未应用的草稿在本次会话中保留，退出前须应用或明确放弃。每行点击“应用”才写入当前 OCR 文档。原识别文字、Vision 置信度、原件 SHA 与坐标保留；导出使用已应用的文字，原图不改。").font(.callout).foregroundStyle(.secondary)
            Text("校正或原生文字层不完整的 PDF 页会按安全像素预算保留为页面图像并重建完整文字层，避免旧文字冲突或扫描正文不可检索；原 PDF 保留。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let document = controller.document {
                        ForEach(document.pages.filter { !$0.lines.isEmpty }) { page in
                            Text("\(document.sources.first { $0.id == page.sourceID }?.displayName ?? "输入文件") · 第 \(page.pageNumber) 页").font(.headline)
                            ForEach(page.lines) { line in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        TextField("识别行", text: Binding(get: { model.ocrCorrectionDrafts[line.id] ?? line.text }, set: { model.ocrCorrectionDrafts[line.id] = $0 == line.text ? nil : $0 })).textFieldStyle(.roundedBorder)
                                        Button("应用") {
                                            do { try controller.correctLine(id: line.id, text: model.ocrCorrectionDrafts[line.id] ?? line.text); model.ocrCorrectionDrafts[line.id] = nil; message = "已应用该行校正。" }
                                            catch { message = error.localizedDescription }
                                        }.disabled(model.ocrCorrectionDrafts[line.id] == nil || model.ocrCorrectionDrafts[line.id] == line.text)
                                    }
                                    Text("原识别置信度 \(Int(line.confidence * 100))%\(line.userEdited ? " · 用户已校正" : "")").font(.caption).foregroundStyle(.secondary)
                                    if let original = line.originalText { Text("Vision 原识别：\(original)").font(.caption).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            HStack { if !model.ocrCorrectionDrafts.isEmpty{Button("放弃未应用草稿…"){let alert=NSAlert();alert.messageText="放弃尚未应用的 OCR 校正草稿？";alert.informativeText="已应用的校正与原识别结果保留。";alert.addButton(withTitle:"放弃未应用草稿");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn{model.ocrCorrectionDrafts=[:]}}};Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 760, minHeight: 500)
    }
}
