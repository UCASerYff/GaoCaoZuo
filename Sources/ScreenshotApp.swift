import SwiftUI
import AppKit
import Carbon
import AVFoundation
import UniformTypeIdentifiers
import Combine

@MainActor final class ScreenshotAppModel: ObservableObject {
    let store:ScreenshotLocalStore
    private let onShowWorkspace:()->Void
    private let onHideHost:()->Void
    var operationBlockingReason:(()->String?)?
    var willBeginExclusiveInput:(()->Void)?
    let capture=ScreenshotCaptureService();let selection=ScreenshotCaptureSelectionController();let pins=ScreenshotPinnedImageController()
    let recording=ScreenshotRecordingController();let ocr=ScreenshotOCRController()
    @Published var tab="截图";@Published var annotation:ScreenshotAnnotationDocument? { didSet { annotationCheckpoint=nil; annotationSubscription=annotation?.objectWillChange.sink{[weak self] in self?.objectWillChange.send()} } };@Published var message="选择一个动作开始，屏幕与剪贴板不会自动采集。"
    @Published var busy=false;@Published var delay=0.0;@Published var cursor=false;@Published var shadow=false
    @Published var translationText="";@Published var translationSource="auto";@Published var translationTarget="en"
    @Published var translationOperationID=UUID()
    @Published var captureCatalog:ScreenshotCaptureCatalog?;@Published var chooser=false;@Published var chooserMode="屏幕";@Published var selectedWindows:Set<CGWindowID>=[]
    @Published var pendingResults:[ScreenshotPendingActionResult]=[]
    let sessionTemporaryDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Screenshot-session-"+UUID().uuidString)
    @Published var exportQuality=0.9;@Published var exportMaximumDimension=0
    let longPanel=ScreenshotLongCapturePanelController()
    var captureTask:Task<Void,Never>?
    @Published var longCaptureOperation:ScreenshotLongCaptureOperation?
    var canCancelCaptureWork:Bool { captureTask != nil || longCaptureOperation?.isActive == true }
    var captureCancellation=ScreenshotOCRCancellationToken()
    var choiceContinuation:CheckedContinuation<ScreenshotCaptureSource?,Never>?
    @Published var externalAnnotation:ScreenshotGaoValidatedPackage?;@Published var externalTranslation:ScreenshotGaoValidatedPackage?
    private var exchangeStorage:ScreenshotExchangeController?
    var exchange:ScreenshotExchangeController { if let exchangeStorage{return exchangeStorage};let value=ScreenshotExchangeController(model:self);exchangeStorage=value;return value }
    var exchangeIsExecuting:Bool { exchangeStorage?.isExecuting ?? false }
    var canCancelExchange:Bool { exchangeStorage?.canCancelCurrentOperation ?? false }
    var canCancelAuxiliaryWork:Bool { !auxiliaryCancellation.isEmpty }
    @Published private(set) var activeAuxiliaryWork:[UUID:String]=[:]
    private var auxiliaryCancellation:[UUID:()->Void]=[:]
    private var exclusiveInputWork:Set<UUID>=[]
    var captureInputExclusive:Bool { busy || canCancelCaptureWork || chooser || recording.isActive || !exclusiveInputWork.isEmpty }
    private var annotationSubscription:AnyCancellable?
    private var unsavedReviewActive=false
    private var annotationCheckpoint:ScreenshotAnnotationState?
    private var ocrCheckpoint:String?
    @Published var ocrCorrectionDrafts:[UUID:String]=[:]
    private var translationCheckpoint:String=""
    @Published var translationResult:ScreenshotLocalTranslationResult?
    @Published var translationIsRunning=false
    @Published var moduleMigrationActive=false
    @Published var moduleBackupActive=false
    @Published var importedActivityWorkActive=false
    var annotationHasUnsavedChanges:Bool { guard let annotation else{return false};return annotationCheckpoint != annotation.state }
    private func ocrDigest(_ document:ScreenshotOCRDocument)->String { let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];guard let bytes=try? encoder.encode(document)else{return "unencodable-"+document.id.uuidString};return ScreenshotFileSafety.digest(bytes) }
    private var currentOCRSignature:String?
    private var ocrSignature:String? { currentOCRSignature }
    var ocrHasUnsavedChanges:Bool { !ocrCorrectionDrafts.isEmpty || (ocrSignature != nil && ocrSignature != ocrCheckpoint) }
    private var translationSignature:String { translationText+"\u{0}"+translationSource+"\u{0}"+translationTarget+"\u{0}"+(translationResult?.translatedText ?? "") }
    var translationHasUnsavedChanges:Bool { (!translationText.isEmpty || translationResult != nil) && translationSignature != translationCheckpoint }
    var terminationBlockReason:String? {
        if unsavedReviewActive{return "请先处理截图工作台当前的未保存内容确认。"}
        if recording.isActive{return "截图工作台仍在录屏或录音，请先停止并完成，或取消并保留恢复材料。"}
        if busy || canCancelCaptureWork{return "截图工作台正在捕获或处理，请等待完成或取消。"}
        if ocr.isRunning{return "OCR 正在识别，请等待或取消并保留已完成结果。"}
        if translationIsRunning{return "本机翻译正在处理，请先完成或取消。"}
        if let work=activeAuxiliaryWork.values.sorted().first{return "截图工作台正在"+work+(canCancelAuxiliaryWork ? "，请先等待完成或取消。":"，请等待该步骤结束后再退出。")}
        if exchangeIsExecuting || externalAnnotation != nil || externalTranslation != nil{return "截图工作台仍有未完成的外部交接，请先完成或明确取消。"}
        if annotationHasUnsavedChanges || ocrHasUnsavedChanges || translationHasUnsavedChanges{return "截图工作台有未保存的标注、OCR 或翻译内容，请先保留当前工作，或明确结束当前工作。"}
        if pins.count>0{return "仍有截图贴图窗口，请先保存需要的贴图并明确关闭。"}
        return nil
    }
    @discardableResult func beginAuxiliaryWork(_ title:String,cancel:(()->Void)?=nil,exclusiveInput:Bool=false)->UUID { let id=UUID();activeAuxiliaryWork[id]=title;auxiliaryCancellation[id]=cancel;if exclusiveInput{exclusiveInputWork.insert(id)};return id }
    func endAuxiliaryWork(_ id:UUID){activeAuxiliaryWork[id]=nil;auxiliaryCancellation[id]=nil;exclusiveInputWork.remove(id)}
    func markAnnotationSaved(){annotationCheckpoint=annotation?.state;objectWillChange.send()}
    func markOCRSaved(_ document:ScreenshotOCRDocument?=nil){ocrCheckpoint=document.map{ocrDigest($0)} ?? ocrSignature;objectWillChange.send()}
    func markTranslationSaved(){translationCheckpoint=translationSignature;objectWillChange.send()}
    func updateTranslationDraft(text:String,source:String,target:String){if text != translationText || source != translationSource || target != translationTarget{translationResult=nil};translationText=text;translationSource=source;translationTarget=target}
    func translationCompleted(_ result:ScreenshotLocalTranslationResult,operationID:UUID,requestID:String?){guard operationID==translationOperationID else{return};translationResult=result;exchange.translationCompleted(result,operationID:operationID,requestID:requestID)}
    func prepareToReplaceAnnotation()->Bool { guard canBeginOperation()else{return false};return confirmUnsaved(annotationHasUnsavedChanges,title:"替换当前标注？",save:{self.saveAnnotation(editable:true);return !self.annotationHasUnsavedChanges},discard:{self.markAnnotationSaved()}) }
    func prepareToReplaceOCR()->Bool { guard canBeginOperation()else{return false};return confirmUnsaved(ocrHasUnsavedChanges,title:"替换当前 OCR 结果？",save:{self.saveSessionWork();return !self.ocrHasUnsavedChanges},discard:{self.ocrCorrectionDrafts=[:];self.markOCRSaved()}) }
    func prepareToReplaceTranslation()->Bool { guard canBeginOperation()else{return false};return confirmUnsaved(translationHasUnsavedChanges,title:"替换当前翻译内容？",save:{self.saveSessionWork();return !self.translationHasUnsavedChanges},discard:{self.markTranslationSaved()}) }
    var operationStartBlockingReason:String? {
        if unsavedReviewActive{return "请先处理截图工作台当前的未保存内容确认。"}
        if importedActivityWorkActive{return "正在核验或恢复迁入记录，请等待该步骤完成。"}
        if moduleBackupActive{return "截图资料正在后台完整备份与核验，请等待完成；此步骤不可取消。"}
        if moduleMigrationActive{return "截图资料正在核验或迁移，请等待完成；本模块生产操作已暂停。"}
        if let reason=operationBlockingReason?(){return reason}
        guard store.writable else{return store.issue ?? "截图资料未就绪，请在搞操作的截图设置中显式迁移或初始化。"}
        return nil
    }
    var recordingStartBlockingReason:String? {
        if let reason=operationStartBlockingReason{return reason}
        if busy || ocr.isRunning || exchangeIsExecuting || translationIsRunning || !activeAuxiliaryWork.isEmpty || externalAnnotation != nil || externalTranslation != nil{return "请先完成或取消截图工作台的当前任务，再开始录制。"}
        return nil
    }
    @discardableResult func canBeginOperation()->Bool {if let reason=operationStartBlockingReason{message=reason;showMain();return false};return true}
    private func confirmUnsaved(_ dirty:Bool,title:String,save:()->Bool,discard:()->Void)->Bool {
        guard dirty else{return true};guard !unsavedReviewActive else{return false};unsavedReviewActive=true;defer{unsavedReviewActive=false};showMain();let alert=NSAlert();alert.messageText=title;alert.informativeText="当前会话内容尚未保存。保留工作后继续，或明确放弃当前内容。";alert.addButton(withTitle:"保留工作…");alert.addButton(withTitle:"放弃并继续");alert.addButton(withTitle:"取消")
        switch alert.runModal(){case .alertFirstButtonReturn:return save();case .alertSecondButtonReturn:discard();return true;default:return false}
    }
    func cancelActiveWork(){cancelCaptureWork();ocr.cancel();for cancel in auxiliaryCancellation.values{cancel()};if canCancelExchange{exchangeStorage?.cancelPending()};if translationIsRunning{translationOperationID=UUID();translationIsRunning=false};if recording.isActive{Task{await recording.cancel()}}}
    func cleanupAfterApprovedTermination(){guard terminationBlockReason==nil else{return};selection.cancel();longPanel.cancel();pins.closeAll();try? FileManager.default.removeItem(at:sessionTemporaryDirectory)}
    @Published var longSession:ScreenshotLongScreenshotSession?;var longSource:ScreenshotCaptureSource?
    private var subscriptions=Set<AnyCancellable>()
    init(store:ScreenshotLocalStore,onShowWorkspace:@escaping()->Void,onHideHost:@escaping()->Void,operationBlockingReason:(()->String?)?=nil){self.operationBlockingReason=operationBlockingReason;self.store=store;self.onShowWorkspace=onShowWorkspace;self.onHideHost=onHideHost;pins.persistenceDirectory=store.root;pins.onNotice={[weak self]text in self?.message=text}
        recording.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
        ocr.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
        ocr.$document.sink{[weak self] document in guard let self else{return};self.currentOCRSignature=document.map{self.ocrDigest($0)}}.store(in:&subscriptions)
        store.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}.store(in:&subscriptions)
    }
    var options:ScreenshotCaptureOptions { var o=ScreenshotCaptureOptions();o.delaySeconds=delay;o.showsCursor=cursor;o.includesShadow=shadow;return o }
    func showMain(){onShowWorkspace()}
    func hideMain(){onHideHost()}
    func fail(_ error:Error){message=error.localizedDescription;showMain()}
    func setTranslationInput(_ text:String,sourceLanguage:String="auto",targetLanguage:String="en") {
        guard externalTranslation==nil else{message="请先完成或取消正在等待的翻译交接。";showMain();return}
        guard prepareToReplaceTranslation()else{return}
        translationOperationID=UUID();translationIsRunning=false;translationResult=nil;translationText=text;translationSource=sourceLanguage;translationTarget=targetLanguage;tab="翻译";showMain()
    }
    func requestScreen(){_ = CGRequestScreenCaptureAccess();message=CGPreflightScreenCaptureAccess() ? "当前程序已取得屏幕录制权限。":"请在系统设置中允许搞操作的屏幕与系统音频录制，然后重新打开应用。"}
    func screenSettings(){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
    func openFiles(){guard externalAnnotation==nil else{message="请先完成或取消正在等待的标注交接。";return};let p=NSOpenPanel();p.allowedContentTypes=[.image,.pdf];p.allowsMultipleSelection=true;if p.runModal() == .OK{Task{await receive(p.urls)}}}
    func receive(_ urls:[URL]) async {
        guard canBeginOperation()else{return}
        guard !busy,!recording.isActive,!ocr.isRunning else{message="请先完成或取消截图工作台的当前任务。";showMain();return}
        for url in urls {
            if url.pathExtension=="gaoaction"{await exchange.receive(url);continue}
            if externalAnnotation != nil{message="请先完成或取消正在等待的标注交接。";continue}
            if url.pathExtension=="gaoannotation" {guard prepareToReplaceAnnotation()else{continue};do{annotation=try ScreenshotAnnotationDocument.loadEditable(url);markAnnotationSaved();tab="标注"}catch{fail(error)};continue}
            if url.pathExtension.lowercased()=="pdf" || urls.count>1 { guard prepareToReplaceOCR()else{break};tab="OCR";ocr.start(urls:urls,options:ocrOptions);break }
            guard prepareToReplaceAnnotation()else{continue}
            do{annotation=ScreenshotAnnotationDocument(image:try ScreenshotReadImage(url));markAnnotationSaved();tab="标注"}catch{fail(error)}
        };showMain()
    }
    var ocrOptions:ScreenshotOCROptions{var o=ScreenshotOCROptions();o.languages=store.settings.languages;return o}
    func adopt(_ frame:ScreenshotCapturedFrame) throws {
        annotation=ScreenshotAnnotationDocument(image:frame.image)
        message="\(frame.image.width) × \(frame.image.height) px · \(frame.colorSpaceName) · 首帧 \(Int(frame.elapsedMilliseconds)) ms"
        try store.remember(image:frame.image,source:frame.sourceDescription,scale:Double(frame.scale))
        switch store.settings.captureStrategy {
        case "复制":NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([NSImage(cgImage:frame.image,size:.zero)])
        case "保存":if let path=store.settings.saveDirectory {let url=URL(fileURLWithPath:path).appendingPathComponent("截图-"+UUID().uuidString+".png");try ScreenshotCaptureImageExport.write(frame.image,to:url);markAnnotationSaved();message="已保存到所选目录。"}else{tab="标注";message+="；先在设置选择保存目录。"}
        default:tab="标注"
        };showMain()
    }
    func captureRegion(silentOCR:Bool=false,translateOCR:Bool=false){
        guard canBeginOperation(),!translateOCR || prepareToReplaceTranslation()else{return}
        guard !busy,!exchangeIsExecuting,!recording.isActive,externalAnnotation==nil,(!translateOCR || externalTranslation==nil)else{return}
        guard (silentOCR || translateOCR) || prepareToReplaceAnnotation() else{return}
        busy=true;captureCancellation=ScreenshotOCRCancellationToken();let cancellation=captureCancellation
        captureTask=Task { [self] in
            defer{busy=false;captureTask=nil;showMain()}
            do {
                guard let frame=try await performCapture("capture.region")else{message="已取消截图。";showMain();return}
                try Task.checkCancellation()
                if silentOCR || translateOCR {
                    _ = try ScreenshotGaoPrivateIO.directory(sessionTemporaryDirectory,create:true,requirePrivate:true)
                    let url=sessionTemporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
                    try ScreenshotPngData(frame.image).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                    defer{try? FileManager.default.removeItem(at:url)}
                    let document=try await ScreenshotOCRService().recognize(urls:[url],options:ocrOptions,cancellation:cancellation,progress:{[weak self]progress in Task{@MainActor in self?.message="截图 OCR：\(progress.completedPages)/\(progress.totalPages) 页"}})
                    try Task.checkCancellation()
                    guard !cancellation.isCancelled,document.successfulPages>0 else{throw ScreenshotAppIssue.message("截图 OCR 已取消或没有可用结果。")}
                    if translateOCR{setTranslationInput(document.text);message="截图 OCR 完成，请选择本机翻译语言并开始。"}
                    else{if store.settings.silentOCRCopies{NSPasteboard.general.clearContents();NSPasteboard.general.setString(document.text,forType:.string)};message="截图 OCR 完成，\(document.text.count) 字。";NSSound.beep()}
                } else {try adopt(frame)}
            }catch{fail(error)}
        }
    }
    func cancelCaptureWork(){
        if let operation=longCaptureOperation {
            guard finishLongCapture(operation,cleanup:{selection.cancel();longPanel.cancel()}) else{return}
            message="已取消长截图。";showMain();return
        }
        captureCancellation.cancel();captureTask?.cancel();selection.cancel();if choiceContinuation != nil{choose(nil)}
    }
    func captureWindow(){captureAction("capture.window")}
    func captureDisplay(){captureAction("capture.display")}
    func captureAction(_ action:String){guard canBeginOperation(),!busy,!exchangeIsExecuting,!recording.isActive,externalAnnotation==nil,prepareToReplaceAnnotation()else{return};busy=true;captureTask=Task{defer{busy=false;captureTask=nil;showMain()};do{if let frame=try await performCapture(action){try Task.checkCancellation();try adopt(frame)}else{message="已取消。";showMain()}}catch{fail(error)}}}
    func performCapture(_ action:String) async throws -> ScreenshotCapturedFrame? {
        if let reason=operationStartBlockingReason{throw ScreenshotAppIssue.message(reason)}
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess()else{throw ScreenshotCaptureFailure.permissionRequired}
        willBeginExclusiveInput?()
        if action=="capture.region"{hideMain();guard let region=await selection.selectRegion()else{return nil};try Task.checkCancellation();return try await capture.captureDesktopRegion(region.desktopRect,options:options)}
        if action=="capture.window"{let catalog=try await capture.refreshCatalog();try Task.checkCancellation();hideMain();guard let id=await selection.selectWindow(from:catalog.windows)else{return nil};try Task.checkCancellation();return try await capture.capture(.window(id),options:options)}
        let catalog=try await capture.refreshCatalog()
        try Task.checkCancellation()
        if catalog.displays.count==1,let d=catalog.displays.first{hideMain();return try await capture.capture(.display(d.id),options:options)}
        captureCatalog=catalog;chooserMode="屏幕";showMain();let source=await withCheckedContinuation{choiceContinuation=$0;chooser=true};try Task.checkCancellation();guard let source else{return nil};hideMain();return try await capture.capture(source,options:options)
    }
    func choose(_ source:ScreenshotCaptureSource?){chooser=false;choiceContinuation?.resume(returning:source);choiceContinuation=nil}
    func multiWindow(){guard canBeginOperation(),!busy,!exchangeIsExecuting,!recording.isActive,externalAnnotation==nil,prepareToReplaceAnnotation()else{return};busy=true;captureTask=Task{defer{busy=false;captureTask=nil};do{captureCatalog=try await capture.refreshCatalog();try Task.checkCancellation();willBeginExclusiveInput?();chooserMode="多窗口";selectedWindows=[];chooser=true}catch{fail(error)}}}
    func finishMulti(){
        guard !busy,!exchangeIsExecuting,!recording.isActive,externalAnnotation==nil,prepareToReplaceAnnotation()else{return}
        willBeginExclusiveInput?();chooser=false;busy=true
        let ids=Array(selectedWindows)
        captureTask=Task{defer{busy=false;captureTask=nil;showMain()};do{hideMain();let frame=try await capture.captureWindows(ids,options:options);try Task.checkCancellation();try adopt(frame)}catch{fail(error)}}
    }
    func ocrClipboard(){guard let data=NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff),let image=NSImage(data:data)?.cgImage(forProposedRect:nil,context:nil,hints:nil)else{message="剪贴板没有可识别图像。";return};ocrImage(image)}
    func ocrImage(_ image:CGImage){guard prepareToReplaceOCR()else{return};do{let dir=sessionTemporaryDirectory;_ = try ScreenshotGaoPrivateIO.directory(dir,create:true,requirePrivate:true);let url=dir.appendingPathComponent(UUID().uuidString+".png");try ScreenshotPngData(image).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);tab="OCR";ocr.start(urls:[url],options:ocrOptions);showMain()}catch{fail(error)}}
    func translateClipboard(){setTranslationInput(NSPasteboard.general.string(forType:.string) ?? "")}
    func copyImage(){guard let image=try? annotation?.flatten()else{return};NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([NSImage(cgImage:image,size:.zero)]);message="已复制最终栅格图像。"}
    func pinImage(){guard canBeginOperation()else{return};guard let image=try? annotation?.flatten()else{return};pins.show(image:image,onEdit:{[weak self]image in self?.editPinnedImage(image)})}
    func saveAnnotation(editable:Bool=false,framed:Bool=false,wallpaper:Bool=false,shell:Bool=true,openEditor:Bool=false){guard let doc=annotation else{return};let p=NSSavePanel();p.nameFieldStringValue=editable ? "标注.gaoannotation":"截图.png";p.allowedContentTypes=editable ? []:[.png,.jpeg,.tiff,.heic];guard p.runModal() == .OK,let url=p.url else{return};do{if editable{try doc.saveEditable(to:url);markAnnotationSaved()}else{let image=try doc.flatten();var backdrop:CGImage?;if wallpaper{guard let screen=NSScreen.main,let path=NSWorkspace.shared.desktopImageURL(for:screen)else{throw ScreenshotAppIssue.message("当前桌面壁纸不可读取，请改用普通带壳导出。")};backdrop=try ScreenshotReadImage(path)};let final=framed ? try ScreenshotCaptureImageExport.framed(image,wallpaper:backdrop,shell:shell):image;let ext=url.pathExtension.lowercased();let format=ScreenshotCaptureImageExport.Format(rawValue:ext=="jpg" ? "jpeg":ext=="tif" ? "tiff":ext) ?? .png;try ScreenshotCaptureImageExport.write(final,to:url,format:format,quality:exportQuality,maximumDimension:exportMaximumDimension>0 ? exportMaximumDimension:nil);markAnnotationSaved();if let request=externalAnnotation{try exchange.completeAnnotation(request,url:url);externalAnnotation=nil};if openEditor{guard let path=store.settings.editorPath else{throw ScreenshotAppIssue.message("请先在设置选择默认编辑 App。")};NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration(),completionHandler:{_,_ in})}};message="已导出并回读校验。"}catch{fail(error)}}
    func sampleColor(){guard canBeginOperation()else{return};willBeginExclusiveInput?();let work=beginAuxiliaryWork("系统取色",exclusiveInput:true);Task{defer{endAuxiliaryWork(work);showMain()};if let color=await ScreenshotCaptureColorSampler.sampleSystemColor(),let rgb=color.usingColorSpace(.sRGB){message=String(format:"sRGB  #%02X%02X%02X · RGB %d %d %d",Int(round(rgb.redComponent*255)),Int(round(rgb.greenComponent*255)),Int(round(rgb.blueComponent*255)),Int(round(rgb.redComponent*255)),Int(round(rgb.greenComponent*255)),Int(round(rgb.blueComponent*255)));showMain()}}}
}
