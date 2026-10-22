import AppKit
import Combine
import Foundation
import Darwin

struct OperationFeedback: Identifiable {
    enum Kind { case idle, running, success, failure }
    var id=UUID()
    var kind:Kind = .idle
    var title=""
    var outputs:[URL] = []
}
struct QueuedQuickOperation {
    let title:String
    let run: @MainActor () async throws -> [URL]
}

@MainActor extension OperationStore {
    func notify(_ title:String,failed:Bool=false,outputs:[URL]=[]) {
        message=L10n.text(title)
        if !outputs.isEmpty {lastOutputs=outputs}
        feedback=OperationFeedback(kind:failed ? .failure : .success,title:L10n.text(title),outputs:outputs)
        showFeedback?()
    }
    func enqueueQuick(_ title:String,run:@escaping @MainActor () async throws -> [URL]) {
        guard dataHealthy else {notify(data.failure ?? "资料暂时不可写入",failed:true);return}
        guard quickJobs.count < 32 else {notify("等待任务已满，请稍后再试",failed:true);return}
        quickJobs.append(.init(title:title,run:run));queuedCount=quickJobs.count
        if busy || archive.isRunning {message=L10n.format("任务已加入队列，等待 %@ 项", String(describing: (queuedCount)));showFeedback?()}
        drainQuickJobs()
    }
    func drainQuickJobs() {
        guard !quickJobActive,!busy,!archive.isRunning,!workflowRunning,!quickJobs.isEmpty else{return}
        guard dataHealthy else {quickJobs.removeAll();queuedCount=0;notify("资料不可写入，等待任务已停止",failed:true);return}
        let job=quickJobs.removeFirst();queuedCount=quickJobs.count;quickJobActive=true;busy=true;quickCancellationRequested=false
        message=job.title;feedback=OperationFeedback(kind:.running,title:job.title);showFeedback?()
        Task {
            do {let outputs=try await job.run();notify(quickCancellationRequested ? "已停止；已完成的结果保留" : job.title+"完成",outputs:outputs)}
            catch {
                if let partial=error as? FileToolsPartialFailure,!partial.receipts.isEmpty {
                    do {let next=partial.receipts+receipts;try data.save(ReceiptDocument(records:next),name:"receipts.json");receipts=next}
                    catch {notify("部分文件需要核验，恢复记录无法保存："+error.localizedDescription+"\n"+partial.receipts.map{$0.destination.path}.joined(separator:"\n"),failed:true);busy=false;quickJobActive=false;drainQuickJobs();return}
                }
                notify(error.localizedDescription,failed:true)
            }
            busy=false;quickJobActive=false;drainQuickJobs()
        }
    }
    func cancelWaitingJobs() {quickJobs.removeAll();queuedCount=0;message="已清除等待任务"}
    func cancelQuickArchive() {quickCancellationRequested=true;archive.cancel();cancelWaitingJobs();cancelPasswordRequest?()}
    func completeNewFile(_ url:URL) {if fileEnhancements.settings.autoOpenNew {NSWorkspace.shared.open(url)};if settings.playNewFileSound {NSSound(named:"Pop")?.play()}}
    func transfer(_ files:[URL],to directory:URL,move:Bool) {
        guard !files.isEmpty else {notify("请先选择文件",failed:true);return}
        enqueueQuick(move ? "移动文件" : "复制文件") {
            let records=try await Task.detached(priority:.userInitiated){try QuickFileActions.copy(items:files,to:directory,move:move)}.value
            try self.record(records);return records.map(\.destination)
        }
    }
    func recordCreated(_ urls:[URL]) async throws {
        let records=try await Task.detached(priority:.userInitiated){try urls.map{FileOperationReceipt(kind:.create,destination:$0,fingerprint:try FileTools.fingerprint($0))}}.value
        try record(records)
    }
    @discardableResult func runQuickAction(_ id:String,files:[URL]) -> Bool {
        let directory=directory(for:files)
        if let kind=QuickNewItemKind(rawValue:String(id.dropFirst(4))),id.hasPrefix("new.") {
            enqueueQuick(kind == .folder ? "新建文件夹" : "新建文件") {
                let receipt=try await Task.detached{try QuickFileActions.create(in:directory,kind:kind)}.value
                try self.record([receipt]);self.completeNewFile(receipt.destination);return [receipt.destination]
            };return true
        }
        if id.hasPrefix("template."),let uuid=UUID(uuidString:String(id.dropFirst(9))),let template=settings.templates.first(where:{$0.id == uuid}) {
            enqueueQuick(L10n.format("从%@新建", String(describing: (template.name)))) {
                let receipt=try await Task.detached{try QuickFileActions.createTemplate(in:directory,filename:template.filename,content:template.content)}.value
                try self.record([receipt]);self.completeNewFile(receipt.destination);return [receipt.destination]
            };return true
        }
        if id == "archive.create" || id == "archive.7z" {
            let format:ArchiveFormat = id == "archive.7z" ? .sevenZip : .zip
            enqueueQuick("压缩为 "+format.title) {
                let destination=try await self.archive.performFileIO { cancellation in
                    guard let first=files.first else {throw FileToolsError.invalid("请先选择需要压缩的文件。")}
                    var info=stat()
                    guard lstat(first.path,&info)==0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
                    var stem=files.count == 1 ? (info.st_mode & S_IFMT == S_IFDIR ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent) : "归档"
                    while stem.utf8.count>250 {stem.removeLast()}
                    let destination=try QuickFileActions.uniqueURL(in:first.deletingLastPathComponent(),preferredName:(stem.isEmpty ? "归档":stem)+"."+format.rawValue)
                    try cancellation.check();return destination
                }
                if self.quickCancellationRequested || Task.isCancelled {throw ArchiveError.cancelled}
                let result=try await self.archive.create(items:files,destination:destination,format:format,password:nil,splitMB:nil,solid:false)
                try self.record(self.archive.lastResultReceipts);return [result]
            };return true
        }
        if id == "archive.extract" {
            enqueueQuick("解压") {try await self.extractQuickly(files)};return true
        }
        if id == "files.copy" || id == "files.move" {
            activateForDialog?()
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true
            panel.directoryURL=directory;panel.prompt=id == "files.move" ? "移动到这里" : "复制到这里"
            panel.message=L10n.text("选择目标目录，选定后立即执行")
            if panel.runModal() == .OK,let url=panel.url {transfer(files,to:url,move:id == "files.move")}
            return true
        }
        if id.hasPrefix("files.copy.") || id.hasPrefix("files.move.") {
            let key=id.split(separator:".").last.map(String.init) ?? ""
            let mapping:[String:FileManager.SearchPathDirectory]=["desktop":.desktopDirectory,"downloads":.downloadsDirectory,"documents":.documentDirectory]
            if let type=mapping[key],let target=FileManager.default.urls(for:type,in:.userDomainMask).first {transfer(files,to:target,move:id.hasPrefix("files.move."))}
            else {notify("目标目录不可用",failed:true)}
            return true
        }
        if ["images.png","images.jpeg","images.heic","images.tiff"].contains(id) {
            let format=String(id.dropFirst(7))
            enqueueQuick("转换为 "+format.uppercased()) {
                let records=try await Task.detached(priority:.userInitiated){try QuickFileActions.convertImages(items:files,format:format,maxDimension:nil)}.value
                try self.record(records);return records.map(\.destination)
            };return true
        }
        if id == "hash.sha256" {
            enqueueQuick("计算并复制 SHA-256") {
                let text=try await Task.detached(priority:.userInitiated){try files.map{try FileTools.sha256($0)+"  "+$0.lastPathComponent}.joined(separator:"\n")}.value
                self.clipboard.copyText(text);return []
            };return true
        }
        if id == "text.qrcode.clipboard" {
            guard let text=NSPasteboard.general.string(forType:.string),!text.isEmpty else {notify("剪贴板没有文字或网址",failed:true);return true}
            enqueueQuick("生成并复制二维码") {
                let (output,bytes)=try await Task.detached {
                    let bytes=try FileTools.qrCode(text:text)
                    let output=try QuickFileActions.uniqueURL(in:directory,preferredName:"二维码.png")
                    try bytes.write(to:output,options:.withoutOverwriting);return(output,bytes)
                }.value
                try await self.recordCreated([output])
                let board=NSPasteboard.general;board.clearContents()
                guard board.setData(bytes,forType:.png) else{throw DataFailure.message("二维码已保存，但未能复制到剪贴板。")}
                return [output]
            };return true
        }
        return false
    }
    private func extractQuickly(_ files:[URL]) async throws -> [URL] {
        var batch=try QuickFileActions.makeExtractionBatch(archives:files)
        var recorded=Set<URL>(), password:String?
        while !batch.isComplete {
            guard !quickCancellationRequested else{throw DataFailure.message(L10n.format("已取消解压；已完成的 %@ 项保留。", String(describing: (recorded.count)))) }
            batch=await QuickFileActions.continueExtraction(batch,service:archive,password:password,stopAfterFirstSuccess:true);password=nil
            let newRecords=batch.items.compactMap(\.receipt).filter{!recorded.contains($0.destination)}
            if !newRecords.isEmpty {try record(newRecords);recorded.formUnion(newRecords.map(\.destination));lastOutputs=Array(recorded)}
            if batch.isComplete {return batch.outputs}
            guard let item=batch.currentItem else{throw DataFailure.message("解压任务状态异常。")}
            switch item.status {
            case .needsPassword(let incorrect):
                if !incorrect,let saved=try PasswordVault.read(account:item.archive.path),!saved.isEmpty {password=saved;continue}
                awaitingArchivePassword=true
                let answer=await requestArchivePassword?(item.archive,incorrect)
                awaitingArchivePassword=false
                guard !quickCancellationRequested,let provided=answer,!provided.isEmpty else {
                    throw DataFailure.message(L10n.format("已取消解压；已完成的 %@ 项保留。", String(describing: (recorded.count))))
                }
                password=provided
            case .failed(let reason):throw DataFailure.message(reason + (recorded.isEmpty ? "" : L10n.format("\n已完成的 %@ 项保留。", String(describing: (recorded.count)))))
            case .cancelled:throw DataFailure.message(L10n.format("已取消解压；已完成的 %@ 项保留。", String(describing: (recorded.count))))
            case .pending:continue
            case .completed:throw DataFailure.message("解压任务状态异常。")
            }
        }
        return batch.outputs
    }
}
