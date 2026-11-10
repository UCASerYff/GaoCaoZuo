import AppKit
import SwiftUI

extension ScreenshotAppModel {
    func editPinnedImage(_ image:CGImage){guard prepareToReplaceAnnotation()else{return};guard externalAnnotation==nil else{message="请先完成或取消正在等待的标注交接。";showMain();return};annotation=ScreenshotAnnotationDocument(image:image);tab="标注";showMain()}
    func copyPermissionStatus(){do{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(ScreenshotPermissionService.snapshot());guard let text=String(data:data,encoding:.utf8)else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string);message="已复制本次运行程序的权限与签名状态；没有捕获屏幕或声音。"}catch{fail(error)}}
    func startLongCapture(){
        guard canBeginOperation(),!busy,!exchangeIsExecuting,!recording.isActive,externalAnnotation==nil,prepareToReplaceAnnotation() else{message="请先完成或取消当前任务。";return}
        let operation=ScreenshotLongCaptureOperation();longCaptureOperation=operation;busy=true;willBeginExclusiveInput?();hideMain()
        longPanel.onStatus={[weak self] text in guard let self,self.longCaptureOperation === operation,operation.isActive else{return};self.message=text}
        longPanel.onCancel={[weak self] in
            guard let self,self.finishLongCapture(operation) else{return}
            self.message="已取消长截图。";self.showMain()
        }
        let task=Task{[self] in
            defer{operation.preparationFinished()}
            do{
                try operation.checkActive()
                try await longPanel.start(service:capture,selection:selection,operation:operation,options:options){[weak self]image in
                    guard let self,self.finishLongCapture(operation) else{return}
                    self.annotation=ScreenshotAnnotationDocument(image:image);self.tab="标注";self.showMain()
                }
            }catch{
                guard finishLongCapture(operation,cleanup:{selection.cancel();longPanel.cancel()}) else{return}
                fail(error)
            }
        }
        operation.setPreparationTask(task)
    }
    @discardableResult
    func finishLongCapture(_ operation:ScreenshotLongCaptureOperation,cleanup:()->Void = {}) -> Bool {
        guard longCaptureOperation === operation else{return false}
        guard operation.finish(cleanup:cleanup) else{return false}
        longCaptureOperation=nil;busy=false;return true
    }
    func persistPin(){guard canBeginOperation()else{return};guard let image=try? annotation?.flatten()else{return};pins.persistenceDirectory=store.root;do{_ = try pins.persist(image:image,onEdit:{[weak self]image in self?.editPinnedImage(image)});message="已主动保存持久贴图。"}catch{fail(error)}}
    func restorePins(){guard canBeginOperation()else{return};pins.persistenceDirectory=store.root;pins.onNotice={[weak self]text in self?.message=text};pins.restorePersistentPins(onEdit:{[weak self]image in self?.editPinnedImage(image)})}
    func backupData() {
        guard canBeginOperation() else{return}
        guard !busy,!canCancelCaptureWork,!chooser,!ocr.isRunning,!translationIsRunning,!exchangeIsExecuting,!recording.isActive,activeAuxiliaryWork.isEmpty,externalAnnotation==nil,externalTranslation==nil else{message="请等待当前任务停止后备份。";return}
        let root=store.root,destination=store.backupRoot.appendingPathComponent("Backup-"+UUID().uuidString)
        moduleBackupActive=true
        let work=beginAuxiliaryWork("完整备份与恢复核验（不可取消）")
        message="正在后台复制并核验完整截图资料及迁移归档；归档可能较大。此步骤不可取消，请保持应用运行。"
        Task{@MainActor in
            defer{moduleBackupActive=false;endAuxiliaryWork(work)}
            do {
                let result=try await Task.detached(priority:.utility){try ScreenshotDataBackup.create(root:root,destination:destination)}.value
                message="完整备份与恢复复制核验已通过。原资料与凭据保持原位；恢复到其他路径仍须受控改绑。"
                NSWorkspace.shared.activateFileViewerSelecting([result])
            }catch{
                message="完整备份未完成："+error.localizedDescription+" 来源及未完成备份均保留。"
                showMain()
            }
        }
    }
}

extension ScreenshotAppModel {
    /// Explicitly saves every unsaved in-memory result as a new private work folder.
    /// No previous draft, user original or export is overwritten.
    func saveSessionWork() {
        guard ocrCorrectionDrafts.isEmpty else{message="请先在“逐行校正”中应用或明确放弃尚未应用的 OCR 草稿。";return}
        guard !busy, !recording.isActive, !ocr.isRunning, !translationIsRunning, activeAuxiliaryWork.isEmpty else { message="请先等待或取消正在处理的任务，再保留当前工作。";return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.message="选择保留当前标注、OCR 与翻译内容的位置。将新建独立工作目录，不覆盖已有文件。"
        guard panel.runModal() == .OK,let parent=panel.url else{return}
        let directory=parent.appendingPathComponent("截图工作-"+UUID().uuidString,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            if let annotation {try annotation.saveEditable(to:directory.appendingPathComponent("标注.gaoannotation"))}
            if let document=ocr.document {try ScreenshotOCRExporter.export(document:document,format:.json,to:directory.appendingPathComponent("OCR.json"))}
            if !translationText.isEmpty || translationResult != nil {
                struct Draft:Codable {var schemaVersion=1;var text:String;var sourceLanguage:String;var targetLanguage:String;var result:ScreenshotLocalTranslationResult?}
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                let bytes=try encoder.encode(Draft(text:translationText,sourceLanguage:translationSource,targetLanguage:translationTarget,result:translationResult))
                let output=directory.appendingPathComponent("翻译.json");try bytes.write(to:output,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
                _ = try JSONDecoder().decode(Draft.self,from:Data(contentsOf:output))
            }
            markAnnotationSaved();markOCRSaved();markTranslationSaved();message="当前工作已另存；原件与已有输出保留。"
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }catch{fail(error)}
    }
    func endCurrentWork() {
        guard !busy, !recording.isActive, !ocr.isRunning, !translationIsRunning, activeAuxiliaryWork.isEmpty, !exchangeIsExecuting, externalAnnotation==nil, externalTranslation==nil else{message="请先完成或取消当前任务及交接。";return}
        let alert=NSAlert();alert.messageText="结束当前截图工作？";alert.informativeText="尚未保存的标注、OCR 校正与翻译将不再阻止退出。需要保留时先使用“保留当前工作”。用户原件与已导出的文件不受影响。";alert.addButton(withTitle:"结束当前工作");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        annotation=nil;ocrCorrectionDrafts=[:];markOCRSaved();translationText="";translationResult=nil;translationOperationID=UUID();markTranslationSaved();message="已明确结束当前工作；已有 OCR 结果在本次会话中仍可查看。"
    }
    func closePins() {
        guard pins.count>0 else{return};let alert=NSAlert();alert.messageText="关闭所有截图贴图？";alert.informativeText="临时贴图关闭后不能恢复；需要保留的贴图请先保存为持久贴图。已保存的文件保留。";alert.addButton(withTitle:"关闭贴图");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn{pins.closeAll();objectWillChange.send()}
    }
}
