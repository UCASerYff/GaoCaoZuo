import Foundation
import AppKit

@MainActor func runPasteStackMergeTests() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-stack-merge-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let stack=PasteStack();try stack.configurePersistence(dataDirectory:root)
    func rejects(_ body:() throws -> Void) throws {do {try body()}catch{return};throw DataFailure.message("堆栈合并未拒绝无效输入")}
    try rejects {_ = try stack.mergedText()}
    try stack.pushContent(text:" 甲\n");try stack.pushContent(text:"乙 ")
    let before=stack.entries,ticket=stack.peek()!
    guard try stack.mergedText(separator:"::") == " 甲\n::乙 ",stack.entries == before else {throw DataFailure.message("文字合并次序或堆栈保留失败")}
    try stack.validateTicket(ticket)
    try rejects {_ = try stack.mergedText(separator:String(repeating:"-",count:4097))}
    try stack.pushContent(text:"rich",rtf:Data("{\\rtf1\\ansi rich}".utf8))
    let rich=stack.entries
    try rejects {_ = try stack.mergedText()}
    guard stack.entries == rich else {throw DataFailure.message("拒绝富合并改变堆栈")}
    let url=root.appendingPathComponent("PasteStack/Snippets/library.json")
    var external=try Data(contentsOf:url);external.append(Data("\n".utf8));try external.write(to:url)
    try rejects {_ = try stack.mergedText()}
    guard try Data(contentsOf:url) == external else {throw DataFailure.message("合并覆盖外部库改动")}
    let richRoot=root.appendingPathComponent("rich",isDirectory:true),richStack=PasteStack()
    try richStack.configurePersistence(dataDirectory:richRoot)
    let styled=NSAttributedString(string:"Styled",attributes:[.font:NSFont.boldSystemFont(ofSize:19),.foregroundColor:NSColor.red])
    let rtf=try styled.data(from:NSRange(location:0,length:styled.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for y in 0..<2 {for x in 0..<2 {bitmap.setColor(.blue,atX:x,y:y)}}
    let png=bitmap.representation(using:.png,properties:[:])!
    let file=richRoot.appendingPathComponent("附件 [a] $ ;.txt"),fileBytes=Data("exact attachment bytes\n".utf8)
    try fileBytes.write(to:file)
    try richStack.pushContent(text:"Styled",rtf:rtf)
    try richStack.pushContent(text:"Image",png:png)
    // A CLI unit host cannot issue security-scoped bookmarks. Exercise the
    // production path/FD verification with an ordinary local reference here.
    try richStack.pushSnippet(AdvancedSnippet(name:"File",text:"File",format:.fileReference,fileReferences:[SnippetFileReference(path:file.path,bookmark:nil)]))
    let folder=richRoot.appendingPathComponent("附件文件夹",isDirectory:true),nested=folder.appendingPathComponent("nested",isDirectory:true)
    try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:folder.appendingPathComponent("empty",isDirectory:true),withIntermediateDirectories:true)
    let nestedBytes=Data([0,1,2,255,128,10])
    try nestedBytes.write(to:nested.appendingPathComponent("原样 binary.dat"))
    try Data("hidden public data".utf8).write(to:folder.appendingPathComponent(".hidden"))
    try richStack.pushSnippet(AdvancedSnippet(name:"Folder",text:"Folder",format:.fileReference,fileReferences:[SnippetFileReference(path:folder.path,bookmark:nil)]))
    let richBefore=richStack.entries,richTicket=richStack.peek()!
    let prepared=try richStack.preparedMerge(separator:"|")
    guard let bytes=prepared.data(forType:.rtfd) else {throw DataFailure.message("富合并缺少 RTFD，不能用纯文本代替")}
    let decoded=try NSAttributedString(data:bytes,options:[.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes:nil)
    guard decoded.string=="Styled|Image\u{fffc}|File\u{fffc}|Folder\u{fffc}",
          let font=decoded.attribute(.font,at:0,effectiveRange:nil) as? NSFont,
          NSFontManager.shared.traits(of:font).contains(.boldFontMask),abs(font.pointSize-19)<0.1,
          richStack.entries==richBefore else {throw DataFailure.message("富合并次序、样式或原队列改变")}
    var attachments:[Data]=[]
    var folders:[FileWrapper]=[]
    decoded.enumerateAttribute(.attachment,in:NSRange(location:0,length:decoded.length)) { value,_,_ in
        if let value=value as? NSTextAttachment,let wrapper=value.fileWrapper,wrapper.isRegularFile,let bytes=wrapper.regularFileContents {attachments.append(bytes)}
        if let value=value as? NSTextAttachment,let wrapper=value.fileWrapper,wrapper.isDirectory {folders.append(wrapper)}
    }
    guard attachments.count==2,attachments.contains(png),attachments.contains(fileBytes) else {throw DataFailure.message("富合并图片或文件附件未逐字节保留")}
    guard folders.count==1,let children=folders[0].fileWrappers,
          children["nested"]?.fileWrappers?["原样 binary.dat"]?.regularFileContents==nestedBytes,
          children["empty"]?.isDirectory==true,children["empty"]?.fileWrappers?.isEmpty==true,
          children[".hidden"]?.regularFileContents==Data("hidden public data".utf8) else {throw DataFailure.message("富合并文件夹结构、空目录或字节未保留")}
    try rejects {_ = try SnippetDirectoryAttachment.capture(folder,maximumBytes:2)}
    try rejects {_ = try SnippetDirectoryAttachment.capture(folder,maximumBytes:1024,maximumEntries:1)}
    let unsafe=richRoot.appendingPathComponent("unsafe",isDirectory:true)
    try FileManager.default.createDirectory(at:unsafe,withIntermediateDirectories:true)
    try FileManager.default.createSymbolicLink(at:unsafe.appendingPathComponent("link"),withDestinationURL:file)
    try rejects {_ = try SnippetDirectoryAttachment.capture(unsafe,maximumBytes:1024)}
    try richStack.validateTicket(richTicket)
    try FileManager.default.removeItem(at:file)
    try rejects {_ = try richStack.preparedMerge()}
    guard richStack.entries==richBefore else {throw DataFailure.message("附件失效后合并消耗了队列")}
    print("堆栈合并定向检查通过：文字次序/空白、RTF粗体字号、RTFD图片/文件/文件夹逐字节保留、空目录与隐藏文件、链接拒绝、队列与票据保留、失效附件拒绝、预算与外部变化；未写系统剪贴板。")
}
