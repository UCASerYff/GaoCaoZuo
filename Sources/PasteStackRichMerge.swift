import AppKit
import UniformTypeIdentifiers
import Darwin

/// One RTFD document preserves ordered rich runs and embeds verified image/file
/// bytes. Plain text is an alternate representation, never the rich merge itself.
@MainActor enum PasteStackRichMerge {
    static let maximumBytes=64*1_024*1_024
    static func prepare(_ entries:[AdvancedSnippet],library:SnippetLibraryStore,separator:String) throws -> NSPasteboardItem {
        guard separator.utf8.count<=4096,entries.count<=PasteStack.maximumItems else {throw DataFailure.message("合并内容超过安全预算，堆栈已保留。")}
        let body=NSMutableAttributedString(string:"")
        var retained=0,hasAttachments=false,hasRichText=false
        func reserve(_ count:Int) throws {
            guard count>=0,count<=maximumBytes-retained else {throw DataFailure.message("合并附件超过64MB，堆栈已保留。")}
            retained += count
        }
        func appendFile(_ data:Data,name:String) throws {
            try reserve(data.count)
            let wrapper=FileWrapper(regularFileWithContents:data)
            let filename=URL(fileURLWithPath:name).lastPathComponent
            wrapper.preferredFilename=filename.isEmpty ? "attachment":filename
            let attachment=NSTextAttachment(fileWrapper:wrapper)
            body.append(NSAttributedString(attachment:attachment));hasAttachments=true
        }
        for (index,entry) in entries.enumerated() {
            guard entry.attachmentPaths?.isEmpty != false else {throw DataFailure.message("旧短语文件引用尚未重新授权，请选择原附件后再复制。")}
            if index>0 {body.append(NSAttributedString(string:separator))}
            let rich:Data?
            if let attachment=entry.rtfAttachment {
                guard attachment.type=="public.rtf" else {throw DataFailure.message("富文本附件类型不正确。")}
                rich=try library.verifiedAttachment(attachment)
            } else {rich=entry.richTextRTF.map{Data($0.utf8)}}
            if let rich {
                try reserve(rich.count)
                guard rich.starts(with:Data("{\\rtf".utf8)) else {throw DataFailure.message("富文本正文无效；原数据已保留，未静默降级。")}
                let parsed=try NSAttributedString(data:rich,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
                body.append(parsed);hasRichText=true
            } else {
                guard entry.format != .richText else {throw DataFailure.message("富文本正文无效；原数据已保留，未静默降级。")}
                try reserve(entry.text.utf8.count);body.append(NSAttributedString(string:entry.text))
            }
            for attachment in entry.attachments ?? [] {
                try appendFile(library.verifiedAttachment(attachment),name:attachment.originalName)
            }
            for reference in entry.fileReferences ?? [] {
                let url=try reference.verifiedURL(),scoped=url.startAccessingSecurityScopedResource()
                defer {if scoped {url.stopAccessingSecurityScopedResource()}}
                var info=stat()
                guard lstat(url.path,&info)==0 else {throw DataFailure.message("无法读取所选附件。")}
                if info.st_mode&S_IFMT==S_IFDIR {
                    let captured=try SnippetDirectoryAttachment.capture(url,maximumBytes:maximumBytes-retained)
                    try reserve(captured.byteCount)
                    body.append(NSAttributedString(attachment:NSTextAttachment(fileWrapper:captured.wrapper)));hasAttachments=true
                } else {
                    let bytes=try SnippetLibraryStore.readSelectedFile(url,maximum:SnippetLibraryStore.maximumAttachmentBytes)
                    try appendFile(bytes,name:url.lastPathComponent)
                }
            }
            guard body.length<=2_000_000 else {throw DataFailure.message("合并文字超过2MB，堆栈已保留。")}
        }
        let item=NSPasteboardItem()
        guard item.setString(body.string,forType:.string) else {throw DataFailure.message("无法准备合并剪贴板内容。")}
        let range=NSRange(location:0,length:body.length)
        if hasAttachments {
            let bytes=try body.data(from:range,documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
            guard bytes.count<=maximumBytes,item.setData(bytes,forType:.rtfd) else {throw DataFailure.message("无法准备合并剪贴板附件。")}
        } else if hasRichText {
            let bytes=try body.data(from:range,documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
            guard bytes.count<=maximumBytes,item.setData(bytes,forType:.rtf) else {throw DataFailure.message("无法准备合并富文本。")}
        }
        return item
    }
}
