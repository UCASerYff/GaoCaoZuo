import AppKit
import UniformTypeIdentifiers
import Translation

/// A local result awaiting an explicit user send. The private package is the durable source of truth.
struct ScreenshotPendingActionResult: Identifiable {
    let request: ScreenshotGaoActionManifest
    var packageURL: URL
    var status: String
    var createdAt: Date
    var id: String { request.requestID }
    var requestID: String { request.requestID }
    var action: String { request.action }
    var sourceBundleID: String { request.sourceBundleID }
}

@MainActor
final class ScreenshotExchangeController {
    /// The host explicitly wires result validation/review. This is only reached
    /// after the user chooses Send; restoring a pending result never calls it.
    static var localResultReceiver: ((URL) async throws -> Void)?
    unowned let model: ScreenshotAppModel
    private var ledger: ScreenshotGaoProcessedRequestStore?
    private var active = false
    private var ocrCancellation: ScreenshotOCRCancellationToken?
    private var externalCapture: ScreenshotActionTaskHandle<ScreenshotCapturedFrame?>?
    private var sending = Set<String>()
    var isExecuting: Bool { active || !sending.isEmpty }
    var canCancelCurrentOperation: Bool {
        (externalCapture != nil && externalCapture?.isCancelled == false) ||
        (ocrCancellation != nil && ocrCancellation?.isCancelled == false) ||
        model.externalAnnotation != nil || model.externalTranslation != nil
    }

    init(model: ScreenshotAppModel) {
        self.model = model
        reloadStore()
    }

    /// Called after an explicit migration/fresh-store decision. Merely displaying
    /// a blocked module must not create Exchange or make historical data writable.
    func reloadStore() {
        guard !isExecuting, !canCancelCurrentOperation else { return }
        ledger = nil
        guard model.store.writable else { return }
        do {
            ledger = try ScreenshotGaoProcessedRequestStore(root: model.store.exchange)
            restorePendingResults()
        } catch { model.message = error.localizedDescription }
    }

    func receive(_ url: URL) async {
        do {
            // Migration may retain a readable store object while atomically replacing
            // its directory. Check the host/module gate before transport creates staging.
            guard model.canBeginOperation() else { return }
            guard let ledger, model.store.writable else { throw ScreenshotAppIssue.message("交接资料不可写，已停止接收。") }
            let package = try ScreenshotGaoActionTransport.receive(packageURL: url, exchangeRoot: model.store.exchange)
            switch try ledger.receive(package) {
            case .duplicate(let old):
                if old.resultPackageName != nil {
                    try restoreStoredResult(old, originalRequest: package.manifest)
                    model.message = "该请求已处理：\(old.phase.rawValue)。已有结果已恢复到待发送列表，没有再次执行。"
                } else { model.message = "该请求处于 \(old.phase.rawValue)。未重放动作；请复核未完成任务，必要时创建新请求。" }
                model.tab = "历史"; model.showMain(); return
            case .new: break
            }
            let manifest = package.manifest
            if manifest.kind == "result" { model.message = "收到交接结果：\(manifest.status ?? "unknown")。"; return }
            guard ScreenshotGaoActionContract.supportedActions.contains(manifest.action) else {
                try finish(package, status: "unsupported", error: "unsupportedAction", provenance: [:]); return
            }
            guard !active, !model.busy, !model.recording.isActive, !model.ocr.isRunning,
                  !model.translationIsRunning, model.externalAnnotation == nil, model.externalTranslation == nil else {
                try finish(package, status: "failed", error: "providerBusy", provenance: [:]); return
            }
            // Reserve the provider before the modal confirmation can run a nested event loop.
            active = true; defer { active = false }
            model.showMain()
            let alert = NSAlert(); alert.messageText = "确认执行外部请求：\(manifest.action)？"
            alert.informativeText = "来源声明：\(manifest.sourceBundleID)（未认证）\n输入：\(package.stagedItems.map { $0.url.lastPathComponent }.joined(separator: "、"))\n\(manifest.action.hasPrefix("capture.") ? "接下来由你选择实际屏幕、窗口或区域。" : "只处理本机核验副本，原件不修改。")"
            alert.addButton(withTitle: "确认启动"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { try finish(package, status: "cancelled", provenance: [:]); return }
            try ScreenshotGaoActionContract.validate(manifest, expectedTargetBundleID: ScreenshotGaoActionContract.bundleID, now: Date())
            _ = try ledger.transition(requestID: manifest.requestID, to: .approved)
            _ = try ledger.transition(requestID: manifest.requestID, to: .executing)
            do { try await execute(package) }
            catch {
                let status: String
                let code: String
                if case ScreenshotOCRError.unsupportedLanguages = error { status = "unsupported"; code = "unsupportedLanguages" }
                else if error is CancellationError { status = "cancelled"; code = "userCancelled" }
                else { status = "failed"; code = (error as? ScreenshotGaoActionIssue)?.code ?? "executionFailed" }
                try finish(package, status: status, error: code, provenance: ["reason": .string(error.localizedDescription)])
                model.message = "交接结果：\(status)。结果已保留，可主动发送。"
            }
        } catch { model.fail(error) }
    }

    private func execute(_ package: ScreenshotGaoValidatedPackage) async throws {
        let manifest = package.manifest
        switch manifest.action {
        case "capture.region", "capture.window", "capture.display":
            guard model.prepareToReplaceAnnotation() else { try finish(package, status: "cancelled", error: "userCancelled", provenance: [:]); return }
            let inputWork = model.beginAuxiliaryWork("外部截图", exclusiveInput: true)
            defer { model.endAuxiliaryWork(inputWork) }
            let oldDelay = model.delay
            defer { model.delay = oldDelay; model.showMain() }
            model.delay = manifest.parameters["delaySeconds"]?.numberValue ?? 0
            let operation = ScreenshotActionTaskHandle<ScreenshotCapturedFrame?>(requestID: manifest.requestID) { [model] in try await model.performCapture(manifest.action) }
            externalCapture = operation
            defer { if externalCapture === operation { externalCapture = nil } }
            model.message = "外部捕获已确认；可取消交接，取消后的迟到画面不会保存或回送。"
            guard let frame = try await operation.value() else { try finish(package, status: "cancelled", provenance: [:]); return }
            let url = try output(package, name: "capture.png", data: ScreenshotPngData(frame.image))
            try finish(package, status: "completed", files: [.init(url: url, uti: "public.png")], provenance: ["pixelWidth": .number(Double(frame.image.width)), "pixelHeight": .number(Double(frame.image.height)), "scale": .number(Double(frame.scale)), "colorSpace": .string(frame.colorSpaceName), "source": .string(frame.sourceDescription)])
            model.annotation = ScreenshotAnnotationDocument(image: frame.image); model.tab = "标注"; model.showMain()
        case "images.pin":
            let image = try ScreenshotReadImage(package.stagedItems[0].url)
            model.pins.show(image: image, onEdit: { [weak model] image in
                guard let model, !model.busy, !model.exchangeIsExecuting, model.externalAnnotation == nil else { model?.message = "请先完成或取消当前捕获与交接。"; return }
                guard model.prepareToReplaceAnnotation() else { return }
                model.annotation = ScreenshotAnnotationDocument(image: image); model.tab = "标注"; model.showMain()
            })
            try finish(package, status: "completed", provenance: ["workflowState": .string("opened"), "sourceItemID": .string(manifest.items[0].id), "sourceSHA256": .string(manifest.items[0].sha256)])
        case "images.annotate":
            guard model.prepareToReplaceAnnotation() else { try finish(package, status: "cancelled", error: "userCancelled", provenance: [:]); return }
            model.annotation = ScreenshotAnnotationDocument(image: try ScreenshotReadImage(package.stagedItems[0].url))
            model.externalAnnotation = package; model.tab = "标注"
            try sendPending(package, workflow: "awaitingUser")
            model.message = "外部标注请求已打开；另存最终图像后才生成完成结果，可取消交接。"
        case "text.translate":
            let bytes = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(package.stagedItems[0].url), maximum: ScreenshotGaoActionContract.maximumTextBytes)
            guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty else { throw ScreenshotLocalTranslationError.emptyText }
            guard text.count <= 100_000 else { throw ScreenshotLocalTranslationError.tooLong }
            if #unavailable(macOS 15.0) { try finish(package, status: "unsupported", error: "requiresMacOS15", provenance: ["provider": .string("Apple Translation"), "networkUsed": .bool(false)]); return }
            if #available(macOS 15.0, *) {
                let source = manifest.parameters["sourceLanguage"]?.stringValue ?? "auto"
                let target = Locale.Language(identifier: manifest.parameters["targetLanguage"]?.stringValue ?? "en")
                let status: LanguageAvailability.Status
                if source == "auto" { status = try await LanguageAvailability().status(for: text, to: target) }
                else { status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: target) }
                guard status != .unsupported else { try finish(package, status: "unsupported", error: "unsupportedLanguagePair", provenance: ["provider": .string("Apple Translation"), "networkUsed": .bool(false)]); return }
            }
            guard model.prepareToReplaceTranslation() else { try finish(package, status: "cancelled", error: "userCancelled", provenance: [:]); return }
            model.translationResult = nil
            model.translationText = text
            model.translationSource = manifest.parameters["sourceLanguage"]?.stringValue ?? "auto"
            model.translationTarget = manifest.parameters["targetLanguage"]?.stringValue ?? "en"
            model.translationOperationID = UUID()
            model.externalTranslation = package; model.tab = "翻译"
            try sendPending(package, workflow: "awaitingUser")
        case "ocr.files": try await performOCR(package)
        default: try finish(package, status: "unsupported", error: "unsupportedAction", provenance: [:])
        }
    }

    private func performOCR(_ package: ScreenshotGaoValidatedPackage) async throws {
        let manifest = package.manifest
        var options = model.ocrOptions
        if let languages = manifest.parameters["languages"]?.arrayValue { options.languages = languages.compactMap(\.stringValue) }
        var seen = Set<String>()
        let formats = (manifest.parameters["outputs"]?.arrayValue?.compactMap(\.stringValue) ?? ["text", "json"]).filter { seen.insert($0).inserted }
        guard formats.count * package.stagedItems.count <= ScreenshotGaoActionContract.maximumItems else { throw ScreenshotGaoActionContract.reject("resultItemLimit", "请求输出将超过256份结果附件，请减少输入文件或输出格式后分批。") }
        let cancellation = ScreenshotOCRCancellationToken(); ocrCancellation = cancellation
        defer { ocrCancellation = nil }
        model.message = "交接 OCR 正在检查原件；“取消交接”可取消本批任务。"
        let document = try await ScreenshotOCRService().recognize(urls: package.stagedItems.map(\.url), options: options, cancellation: cancellation) { [weak model] progress in
            Task { @MainActor in model?.message = "交接 OCR：\(progress.completedPages)/\(progress.totalPages) 页；可取消交接。" }
        }
        // Keep completed work before a cancellable PDF export. It is local recovery, not a new requested output.
        var recoveryURL: URL?
        if formats.contains("searchablePDF") || document.isPartial || document.wasCancelled {
            let url = try outputURL(package, name: "OCR-recovery.json")
            let mappings = zip(document.sources, package.stagedItems).map { ScreenshotOCRRecoverySource(sourceID: $0.0.id, sourceItemID: $0.1.item.id, sourceSHA256: $0.1.item.sha256) }
            _ = try await Task.detached(priority: .userInitiated) { try ScreenshotOCRRecoveryStore.save(document: document, requestID: manifest.requestID, sources: mappings, to: url) }.value
            recoveryURL = url
        }
        var files: [ScreenshotGaoOutgoingFile] = []
        var failures: [String] = []
        var sourceRecords: [ScreenshotGaoJSONValue] = []
        var outputRecords: [ScreenshotGaoJSONValue] = []
        for (index, source) in document.sources.enumerated() {
            let staged = package.stagedItems[index]
            var sourceDocument = document
            sourceDocument.sources = [source]
            sourceDocument.pages = document.pages.filter { $0.sourceID == source.id }
            sourceDocument.wasCancelled = sourceDocument.pages.contains { $0.status == .cancelled }
            var outputIDs: [ScreenshotGaoJSONValue] = []
            for format in formats {
                do {
                    let file: ScreenshotGaoOutgoingFile
                    if format == "searchablePDF" {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let url = try outputURL(package, name: "OCR-\(index + 1).pdf")
                        _ = try await Task.detached(priority: .userInitiated) { [self] in
                            try ScreenshotOCRExporter.exportSearchablePDF(document: sourceDocument, sourceID: source.id, sourceURL: staged.url, to: url, cancellation: cancellation) { value in
                                Task { @MainActor [weak self] in self?.model.message = "交接 OCR PDF：\(value.description)；可取消交接。" }
                            }
                        }.value
                        file = .init(url: url, uti: "com.adobe.pdf")
                    } else {
                        guard let exportFormat = ScreenshotOCRExportFormat(rawValue: format) else { throw ScreenshotGaoActionContract.reject("unsupportedOutput", "OCR 输出格式不支持。") }
                        let ext = format == "markdown" ? "md" : format == "json" ? "json" : "txt"
                        let url = try outputURL(package, name: "OCR-\(index + 1)." + ext)
                        try await Task.detached(priority: .userInitiated) { try ScreenshotOCRExporter.export(document: sourceDocument, format: exportFormat, to: url) }.value
                        file = .init(url: url, uti: format == "json" ? "public.json" : format == "markdown" ? "net.daringfireball.markdown" : "public.utf8-plain-text")
                    }
                    files.append(file); outputIDs.append(.string(file.id))
                    outputRecords.append(.object(["sourceID": .string(source.id.uuidString), "sourceItemID": .string(staged.item.id), "sourceSHA256": .string(staged.item.sha256), "resultItemID": .string(file.id), "format": .string(format)]))
                } catch is CancellationError { failures.append("第\(index + 1)项可搜索PDF已取消；已完成识别页保留。") }
                catch { failures.append("第\(index + 1)项\(format)：\(error.localizedDescription)") }
            }
            sourceRecords.append(.object([
                "sourceID": .string(source.id.uuidString),
                "sourceItemID": .string(staged.item.id),
                "sourceSHA256": .string(staged.item.sha256),
                "outputItemIDs": .array(outputIDs),
                "pages": .array(sourceDocument.pages.map { page in .object([
                    "pageNumber": .number(Double(page.pageNumber)), "status": .string(page.status.rawValue),
                    "elapsedSeconds": .number(page.elapsedSeconds), "lineCount": .number(Double(page.lines.count)),
                    "failureReason": page.failureReason.map(ScreenshotGaoJSONValue.string) ?? .null
                ]) })
            ]))
        }
        let status: String
        if document.wasCancelled || cancellation.isCancelled { status = document.successfulPages == 0 ? "cancelled" : "partial" }
        else if document.successfulPages == 0 { status = "failed" }
        else { status = document.isPartial || !failures.isEmpty ? "partial" : "completed" }
        let errorCode = status == "completed" ? nil : status == "cancelled" ? "userCancelled" : "pageOrExportFailed"
        var provenance: [String: ScreenshotGaoJSONValue] = ["sources": .array(sourceRecords), "outputs": .array(outputRecords), "engine": .string(document.engine), "engineRevision": .number(Double(document.engineRevision)), "networkUsed": .bool(false), "exportFailures": .array(failures.map(ScreenshotGaoJSONValue.string))]
        if recoveryURL != nil, status != "completed" { provenance["localRecovery"] = .object(["available": .bool(true), "filename": .string("OCR-recovery.json"), "requestID": .string(manifest.requestID)]) }
        try finish(package, status: status, files: files, error: errorCode, provenance: provenance)
        if let recoveryURL, status == "completed" { try? FileManager.default.removeItem(at: recoveryURL) }
    }

    func completeAnnotation(_ package: ScreenshotGaoValidatedPackage, url: URL) throws {
        let canonicalSourceSHA = ScreenshotFileSafety.digest(try ScreenshotPngData(ScreenshotReadImage(package.stagedItems[0].url)))
        guard model.annotation?.originalSHA256 == canonicalSourceSHA else { throw ScreenshotGaoActionContract.reject("annotationInputChanged", "当前标注原图与批准输入不一致，不能关联原件摘要；请复核或取消交接。") }
        try finish(package, status: "completed", files: [.init(url: url, uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.png")], provenance: ["sourceItemID": .string(package.manifest.items[0].id), "sourceSHA256": .string(package.manifest.items[0].sha256), "flattened": .bool(true)])
    }

    func translationCompleted(_ result: ScreenshotLocalTranslationResult, operationID: UUID, requestID: String?) {
        let identity = ScreenshotTranslationOperationIdentity(operationID: operationID, requestID: requestID)
        guard identity.matches(operationID: model.translationOperationID, requestID: model.externalTranslation?.manifest.requestID),
              let package = model.externalTranslation, requestID == package.manifest.requestID else { return }
        do {
            // A completed result must correspond to the approved original input and requested language.
            let original = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(package.stagedItems[0].url), maximum: ScreenshotGaoActionContract.maximumTextBytes)
            guard String(data: original, encoding: .utf8) == result.sourceText else { throw ScreenshotGaoActionContract.reject("translationInputChanged", "译文对应的原文与批准输入不一致，请取消后重新交接。") }
            let expectedTarget = package.manifest.parameters["targetLanguage"]?.stringValue ?? "en"
            guard Locale.Language(identifier: expectedTarget).isEquivalent(to: Locale.Language(identifier: result.targetLanguage)) else { throw ScreenshotGaoActionContract.reject("translationTargetChanged", "译文目标语言与请求不一致，请取消后重新交接。") }
            let expectedSource = package.manifest.parameters["sourceLanguage"]?.stringValue ?? "auto"
            guard expectedSource == "auto" || Locale.Language(identifier: expectedSource).isEquivalent(to: Locale.Language(identifier: result.sourceLanguage)) else { throw ScreenshotGaoActionContract.reject("translationSourceChanged", "译文原语言与请求不一致，请取消后重新交接。") }
            let url = try output(package, name: "translation.txt", data: Data(result.translatedText.utf8))
            try finish(package, status: "completed", files: [.init(url: url, uti: "public.utf8-plain-text")], provenance: ["provider": .string(result.provider), "networkUsed": .bool(result.networkUsed), "contentSentToCloud": .bool(result.contentSentToCloud), "languagePackageDownloadRequested": .bool(result.languagePackageDownloadRequested), "sourceItemID": .string(package.manifest.items[0].id), "sourceSHA256": .string(package.manifest.items[0].sha256), "sourceLanguage": .string(result.sourceLanguage), "requestedSourceLanguage": .string(expectedSource), "sourceLanguageMode": .string(expectedSource == "auto" ? "automatic" : "explicit"), "targetLanguage": .string(result.targetLanguage)])
            model.externalTranslation = nil
        } catch { model.fail(error) }
    }

    /// The host's capture-only menu must also cancel a confirmed Exchange capture,
    /// without ending unrelated OCR, annotation or translation work.
    func cancelExternalCapture() {
        guard let operation = externalCapture else { return }
        operation.cancel(); model.selection.cancel()
        if model.choiceContinuation != nil { model.choose(nil) }
        model.message = "正在取消外部捕获；不会保存或回送取消后的画面。"
    }

    func cancelPending() {
        cancelExternalCapture()
        if let ocrCancellation { ocrCancellation.cancel(); model.message = "正在取消外部 OCR；已完成页将保留为部分结果。" }
        cancelAnnotation()
        if let package = model.externalTranslation { cancelTranslation(operationID: model.translationOperationID, requestID: package.manifest.requestID) }
    }

    func cancelTranslation(operationID: UUID, requestID: String?) {
        let identity = ScreenshotTranslationOperationIdentity(operationID: operationID, requestID: requestID)
        guard identity.matches(operationID: model.translationOperationID, requestID: model.externalTranslation?.manifest.requestID) else { return }
        // The local panel already stopped its own attempt; it has no external request to finish.
        guard let package = model.externalTranslation, requestID == package.manifest.requestID else { return }
        model.translationOperationID = UUID()
        do { try finish(package, status: "cancelled", error: "userCancelled", provenance: [:]); model.externalTranslation = nil }
        catch { model.fail(error) }
    }

    func cancelAnnotation(requestID: String? = nil) {
        guard let package = model.externalAnnotation, requestID == nil || requestID == package.manifest.requestID else { return }
        do { try finish(package, status: "cancelled", error: "userCancelled", provenance: [:]); model.externalAnnotation = nil }
        catch { model.fail(error) }
    }

    private func outputURL(_ package: ScreenshotGaoValidatedPackage, name: String) throws -> URL {
        let directory = model.store.exchange.appendingPathComponent("Derived/" + package.manifest.requestID)
        _ = try ScreenshotGaoPrivateIO.directory(directory, create: true, requirePrivate: true)
        return directory.appendingPathComponent(name)
    }
    private func output(_ package: ScreenshotGaoValidatedPackage, name: String, data: Data) throws -> URL {
        let url = try outputURL(package, name: name)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
    private func sendPending(_ package: ScreenshotGaoValidatedPackage, workflow: String) throws {
        let url = try ScreenshotGaoActionWriter.writeResult(inReplyTo: package.manifest, status: "pending", provenance: ["workflowState": .string(workflow)], exchangeRoot: model.store.exchange)
        queue(ScreenshotPendingActionResult(request: package.manifest, packageURL: url, status: "pending", createdAt: Date()))
    }
    private func finish(_ package: ScreenshotGaoValidatedPackage, status: String, files: [ScreenshotGaoOutgoingFile] = [], error: String? = nil, provenance: [String: ScreenshotGaoJSONValue]) throws {
        let url = try ScreenshotGaoActionWriter.writeResult(inReplyTo: package.manifest, status: status, items: files, errorCode: error, provenance: provenance, exchangeRoot: model.store.exchange)
        if let phase = ScreenshotGaoRequestPhase(rawValue: status) { _ = try ledger?.transition(requestID: package.manifest.requestID, to: phase, resultPackageName: url.lastPathComponent, errorCode: error) }
        queue(ScreenshotPendingActionResult(request: package.manifest, packageURL: url, status: status, createdAt: Date()))
        model.message = "交接结果：\(status)。已保存在私有目录，请在“历史与交接”主动发送。"
    }
    private func queue(_ result: ScreenshotPendingActionResult) {
        if let index = model.pendingResults.firstIndex(where: { $0.id == result.id }) {
            guard result.status != "pending" || model.pendingResults[index].status == "pending" else { return }
            model.pendingResults[index] = result
        }
        else { model.pendingResults.insert(result, at: 0) }
    }

    /// Explicit send always revalidates the saved result and creates a fresh 120-second envelope.
    /// Historical time is used only to inspect our own stored result; no historical request can execute.
    func sendResult(_ result: ScreenshotPendingActionResult) {
        guard model.canBeginOperation() else { return }
        guard sending.insert(result.id).inserted else { return }
        let exchangeRoot = model.store.exchange
        model.message = "正在核验并重新包装所选结果，原业务不会再次执行。"
        Task { [self] in
            defer { sending.remove(result.id) }
            do {
                let savedManifest = try storedManifest(at: result.packageURL)
                guard savedManifest.kind == "result", savedManifest.sourceBundleID == ScreenshotGaoActionContract.bundleID,
                      savedManifest.inReplyTo == result.requestID, savedManifest.targetBundleID == result.sourceBundleID,
                      savedManifest.action == result.action, savedManifest.status == result.status,
                      let created = ScreenshotGaoActionContract.date(savedManifest.createdAt) else { throw ScreenshotGaoActionContract.reject("resultChanged", "已保存结果的关联信息发生变化，停止发送。") }
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    let checked = try ScreenshotGaoActionTransport.receive(packageURL: result.packageURL, exchangeRoot: exchangeRoot, expectedTargetBundleID: result.sourceBundleID, now: created)
                    defer { try? FileManager.default.removeItem(at: checked.stagingURL) }
                    let files = checked.stagedItems.map { ScreenshotGaoOutgoingFile(url: $0.url, uti: $0.item.uti, id: $0.item.id) }
                    return try ScreenshotGaoActionWriter.writeResult(inReplyTo: result.request, status: result.status, items: files, references: checked.manifest.references, errorCode: checked.manifest.errorCode, provenance: checked.manifest.provenance ?? [:], exchangeRoot: exchangeRoot, now: Date())
                }.value
                queue(ScreenshotPendingActionResult(request: result.request, packageURL: refreshed, status: result.status, createdAt: Date()))
                if result.sourceBundleID == ScreenshotGaoActionContract.bundleID {
                    guard let receiver = Self.localResultReceiver else { model.message = "结果包已保留；宿主接收入口尚未就绪，未递送。"; return }
                    try await receiver(refreshed)
                    model.message = "已交给搞操作核验结果；仍需在交接记录中复核导入。"
                    return
                }
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: result.sourceBundleID), Bundle(url: app)?.bundleIdentifier == result.sourceBundleID else { model.message = "来源应用未安装。已重新生成有效结果包，可在私有目录导出；未重执行动作。"; return }
                NSWorkspace.shared.open([refreshed], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.model.message = "结果包已保留，打开来源应用失败：\(error.localizedDescription)" }
                        else { self.model.message = "已请求来源应用打开结果包；对方仍需核验与确认导入。" }
                    }
                }
            } catch { model.fail(error) }
        }
    }

    private func storedManifest(at url: URL) throws -> ScreenshotGaoActionManifest {
        let outgoing = model.store.exchange.appendingPathComponent("Outgoing", isDirectory: true).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == outgoing, url.pathExtension == "gaoaction" else { throw ScreenshotGaoActionContract.reject("invalidResultPath", "结果包不属于本应用私有发送目录。") }
        let directory = try ScreenshotGaoPrivateIO.directory(url, requirePrivate: true)
        let data = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regular(directory, components: ["manifest.json"]), maximum: Int64(ScreenshotGaoActionContract.maximumManifestBytes))
        return try ScreenshotGaoActionTransport.decodeManifest(data)
    }

    private func restoreStoredResult(_ record: ScreenshotGaoProcessedRequest, originalRequest: ScreenshotGaoActionManifest? = nil) throws {
        guard record.kind == "request", let name = record.resultPackageName else { return }
        let url = model.store.exchange.appendingPathComponent("Outgoing/" + name)
        let result = try storedManifest(at: url)
        guard result.kind == "result", result.sourceBundleID == ScreenshotGaoActionContract.bundleID,
              result.inReplyTo == record.requestID, result.targetBundleID == record.sourceBundleID,
              result.action == record.action, result.status == record.phase.rawValue,
              let created = ScreenshotGaoActionContract.date(result.createdAt) else { throw ScreenshotGaoActionContract.reject("resultChanged", "已保存交接结果与历史记录不一致。") }
        try ScreenshotGaoActionContract.validate(result, expectedTargetBundleID: record.sourceBundleID, now: created)
        // Only metadata needed to re-envelope a result, never a replayable request.
        let request = originalRequest ?? ScreenshotGaoActionManifest(kind: "request", requestID: record.requestID, sourceBundleID: record.sourceBundleID, targetBundleID: ScreenshotGaoActionContract.bundleID, action: record.action, createdAt: result.createdAt, expiresAt: result.expiresAt, nonce: result.nonce, items: [], references: [], parameters: result.parameters)
        queue(ScreenshotPendingActionResult(request: request, packageURL: url, status: record.phase.rawValue, createdAt: created))
    }

    func restorePendingResults() {
        guard let ledger else { return }
        var unavailable = 0
        for record in ledger.allRecords().prefix(256) where record.kind == "request" && record.phase.isTerminal && record.resultPackageName != nil {
            do { try restoreStoredResult(record) } catch { unavailable += 1 }
        }
        if unavailable > 0 { model.message = "有\(unavailable)份历史交接结果缺失或无效，已保留历史且未重放；请复核或新建请求。" }
    }
}
