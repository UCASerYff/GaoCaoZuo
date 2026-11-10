import AppKit
import SwiftUI
import Combine

/// Owns screenshot work inside the operation host. Merely constructing this bridge
/// does not open legacy data, register hot keys, acquire a source or create windows.
@MainActor
final class ScreenshotHostController: ObservableObject {
    private let data: LocalData
    private let onShowWorkspace: () -> Void
    private let onHideHost: () -> Void
    private var modelStorage: ScreenshotAppModel?
    private var modelSubscription: AnyCancellable?
    var operationBlockingReason: (() -> String?)?
    var onBeginExclusiveInput: (() -> Void)?
    var captureInputExclusive: Bool { modelStorage?.captureInputExclusive ?? false }

    init(data: LocalData, onShowWorkspace: @escaping () -> Void, onHideHost: @escaping () -> Void) {
        self.data = data; self.onShowWorkspace = onShowWorkspace; self.onHideHost = onHideHost
    }
    var model: ScreenshotAppModel {
        if let modelStorage { return modelStorage }
        let root = data.directory.appendingPathComponent("Screenshot", isDirectory: true)
        let backups = data.directory.deletingLastPathComponent().appendingPathComponent("GaoCaoZuo-Backups/Screenshot", isDirectory: true)
        let configuration = ScreenshotMigrationConfiguration.standard(targetRoot: root, backupRoot: backups)
        let store = ScreenshotLocalStore(root: root, backupRoot: backups, migrationConfiguration: configuration)
        let value = ScreenshotAppModel(store: store, onShowWorkspace: onShowWorkspace, onHideHost: onHideHost, operationBlockingReason: { [weak self] in self?.operationBlockingReason?() })
        value.willBeginExclusiveInput = { [weak self] in self?.onBeginExclusiveInput?() }
        value.recording.onWillStart = { [weak self] in self?.onBeginExclusiveInput?() }
        value.recording.startBlockingReason = { [weak value] in value?.recordingStartBlockingReason }
        modelStorage = value
        modelSubscription = value.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return value
    }
    var workspaceView: some View { ScreenshotMainView(model: model) }
    var settingsView: some View { ScreenshotSettingsView(model: model) }
    var terminationBlockReason: String? { modelStorage?.terminationBlockReason }
    var busy: Bool {
        guard let modelStorage else { return false }
        return modelStorage.busy || modelStorage.recording.isActive || modelStorage.ocr.isRunning || modelStorage.translationIsRunning || modelStorage.exchangeIsExecuting || !modelStorage.activeAuxiliaryWork.isEmpty
    }
    func showWorkspace(tab: String? = nil) { if let tab { model.tab = tab }; onShowWorkspace() }
    func receive(_ urls: [URL]) async { await model.receive(urls) }
    func cancelActiveWork() { modelStorage?.cancelActiveWork() }
    func cleanupAfterApprovedTermination() { modelStorage?.cleanupAfterApprovedTermination() }

    /// Host actions stay in this process. File input uses the original validated
    /// image/PDF/OCR paths; an empty input only presents the corresponding page.
    @discardableResult
    func performAction(_ action: String, files: [URL] = []) async throws -> Bool {
        switch action {
        case "screenshot.workspace", "workspace": showWorkspace()
        case "capture.region": model.captureRegion()
        case "capture.window": model.captureWindow()
        case "capture.display": model.captureDisplay()
        case "screenshot.long", "capture.long": model.startLongCapture()
        case "ocr.files":
            showWorkspace(tab: "OCR")
            if !files.isEmpty {
                guard files.count<=ScreenshotGaoActionContract.maximumItems else{throw ScreenshotAppIssue.message("OCR 文件过多，请分批处理。")}
                guard !model.busy,!model.exchangeIsExecuting,!model.ocr.isRunning,model.externalAnnotation==nil,model.externalTranslation==nil else{throw ScreenshotAppIssue.message("请先完成或取消截图工作台的当前任务。")}
                if model.prepareToReplaceOCR(){model.ocr.start(urls:files,options:model.ocrOptions)}
            }
        case "images.annotate":
            showWorkspace(tab: "标注")
            if !files.isEmpty {
                guard files.count==1 else{throw ScreenshotAppIssue.message("标注动作每次接收一张图像。多文件识别请使用 OCR。")}
                guard !model.busy,!model.exchangeIsExecuting,model.externalAnnotation==nil else{throw ScreenshotAppIssue.message("请先完成或取消截图工作台的当前任务。")}
                if model.prepareToReplaceAnnotation(){model.annotation=ScreenshotAnnotationDocument(image:try ScreenshotReadImage(files[0]));model.markAnnotationSaved()}
            }
        case "images.pin":
            guard model.canBeginOperation()else{return true}
            guard !model.busy, !model.exchangeIsExecuting, !model.recording.isActive, model.externalAnnotation == nil else { throw ScreenshotAppIssue.message("请先完成或取消截图工作台的当前任务。") }
            if files.isEmpty { showWorkspace(tab: "标注") }
            else {
                guard files.count == 1 else { throw ScreenshotAppIssue.message("贴图动作每次接收一张图像。") }
                let images = try files.map { try ScreenshotReadImage($0) }
                for image in images { model.pins.show(image: image, onEdit: { [weak model = modelStorage] image in model?.editPinnedImage(image) }) }
            }
        case "text.translate":
            guard model.canBeginOperation()else{return true}
            showWorkspace(tab: "翻译")
            if !files.isEmpty {
                guard files.count==1 else{throw ScreenshotAppIssue.message("翻译动作每次接收一个 UTF-8 文本文件。")}
                let bytes=try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(files[0]),maximum:ScreenshotGaoActionContract.maximumTextBytes)
                guard let text=String(data:bytes,encoding:.utf8),!text.isEmpty else{throw ScreenshotLocalTranslationError.emptyText}
                guard text.count<=100_000 else{throw ScreenshotLocalTranslationError.tooLong}
                model.setTranslationInput(text)
            }
        case "screenshot.recording", "recording": showWorkspace(tab: "录制")
        case "screenshot.pins.restore", "pins.restore": model.restorePins()
        case "screenshot.settings", "settings": showWorkspace()
        case "screenshot.ocr.clipboard": model.ocrClipboard()
        case "screenshot.translate.clipboard": model.translateClipboard()
        case "screenshot.ocr.capture": model.captureRegion(silentOCR: true)
        case "screenshot.translate.capture": model.captureRegion(translateOCR: true)
        default: return false
        }
        return true
    }
}
